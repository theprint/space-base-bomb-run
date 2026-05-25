extends Node
# GM-AI controller — takes over spawning when the inference server is reachable.
#
# Setup: add as a child of the level_controller node.
# The inference server must be running:
#   python gm_ai/serve.py
#
# How it works:
#   - Connects to level.spawn_timer.timeout so it fires at the exact same
#     cadence as the normal spawner.
#   - On each tick: collects a game-state snapshot, sends it to the server.
#   - On response: applies the chosen action and calls level.trigger_wave()
#     (or skips the spawn, depending on the action).
#   - Sets level.gm_connected = true on first successful response so the
#     normal spawner knows to stand down.
#   - Falls back to a normal spawn if the request is still in-flight when
#     the next tick fires, so nothing is ever skipped due to server latency.

const SERVER_URL     = "http://127.0.0.1:5001/predict"
const SEQ_LEN        = 8     # must match gm_ai/dataset.py SEQ_LEN
const ROLLING_WINDOW = 10.0  # must match telemetry.gd ROLLING_WINDOW

# How aggressively the GM nudges parameters
const BUDGET_NUDGE = 0.25
const SURGE_NUDGE  = 0.50
const RATE_NUDGE   = 0.20
const RATE_MIN     = 1.0   # fastest spawn interval the GM may set (seconds)
const RATE_MAX     = 6.0   # slowest spawn interval the GM may set (seconds)

var _level:      Node          = null
var _http:       HTTPRequest   = null
var _inference:  Node          = null  # GmInference node, set if weights.json found
var _buffer:     Array         = []    # rolling snapshots, oldest first
var _waiting:    bool          = false # true while an HTTP request is in-flight
var _rest_ticks: int           = 0    # ticks remaining in a forced rest
var _was_playing: bool         = false # for detecting game-start transitions
var _visualizer: Node          = null  # GmVisualizer CanvasLayer (optional)

# Rolling-window stats — mirrors telemetry.gd so inference features match training.
var _gm_play_time:           float = 0.0
var _gm_time_since_last_hit: float = 0.0
var _gm_score_history:       Array = []   # [{t: float, s: int}]
var _gm_kill_times:          Array = []   # play_time of each kill in last ROLLING_WINDOW s
var _gm_hit_times:           Array = []   # play_time of each hit in last ROLLING_WINDOW s

func _ready():
	call_deferred("_setup")

func _setup():
	_level = get_tree().get_first_node_in_group("level")
	if not _level:
		push_warning("GMController: no node in group 'level' found.")
		return
	# Try embedded inference first (weights.json produced by export_weights.py).
	# Falls back to HTTP server if weights aren't present — useful during development.
	_inference = Node.new()
	_inference.set_script(load("res://scenes/gm_inference.gd"))
	add_child(_inference)
	if not _inference.weights_loaded:
		_http = HTTPRequest.new()
		add_child(_http)
		_http.request_completed.connect(_on_response)

	# Visualizer overlay (press V to toggle).
	_visualizer = load("res://scenes/gm_visualizer.gd").new()
	add_child(_visualizer)

	# Piggyback on the level's spawn timer — same signal, same cadence, no drift.
	_level.spawn_timer.timeout.connect(_on_spawn_tick)

	# Hook into kill/hit events so rolling-window features stay accurate.
	_level.enemy_killed.connect(_on_kill)
	_level.player_damaged.connect(_on_hit)

# ── State transition tracking ─────────────────────────────────────────────────

func _process(delta):
	if not _level:
		return
	var playing = _level.is_playing()
	if playing and not _was_playing:
		_buffer.clear()
		_gm_play_time           = 0.0
		_gm_time_since_last_hit = 0.0
		_gm_score_history.clear()
		_gm_kill_times.clear()
		_gm_hit_times.clear()
	if playing:
		_gm_play_time           += delta
		_gm_time_since_last_hit  = minf(_gm_time_since_last_hit + delta, 999.0)
	_was_playing = playing

# ── Spawn tick (fired by level's spawn_timer) ─────────────────────────────────

func _on_spawn_tick():
	if not _level or not _level.is_playing():
		return

	_collect_snapshot()

	if _rest_ticks > 0:
		_rest_ticks -= 1
		return   # intentional pause — don't spawn and don't request

	if _inference and _inference.weights_loaded:
		# Embedded path: synchronous, no latency.
		var result = _inference.predict(_buffer)
		_level.gm_connected = true
		_apply_top_action(result)
		return

	# HTTP fallback (development / serve.py running).
	if _waiting:
		# Previous request hasn't returned yet; fall back so the tick isn't lost.
		_level.trigger_wave()
		return
	_send_request()

# ── Snapshot collection ───────────────────────────────────────────────────────
# Feature order must exactly match FEATURES in gm_ai/dataset.py.

func _collect_snapshot():
	var player = get_tree().get_first_node_in_group("player_body")
	var screen = get_viewport().get_visible_rect().size
	var diag   = screen.length()

	var px_norm   = 0.5
	var py_norm   = 0.5
	var is_invinc = 0
	if player:
		px_norm   = player.global_position.x / screen.x
		py_norm   = player.global_position.y / screen.y
		is_invinc = 1 if player.invincible else 0

	var enemies       = get_tree().get_nodes_in_group("enemies")
	var enemy_count   = enemies.size()
	var scout_count   = 0
	var hunter_count  = 0
	var bruiser_count = 0
	var total_threat  = 0.0
	var sum_enemy_y   = 0.0
	var nearest_dist  = INF

	for e in enemies:
		if e.data:
			match e.data.type_name:
				"scout":   scout_count  += 1
				"hunter":  hunter_count += 1
				"bruiser": bruiser_count += 1
			total_threat += e.data.threat_value
		sum_enemy_y += e.global_position.y
		if player:
			var d = e.global_position.distance_to(player.global_position)
			if d < nearest_dist:
				nearest_dist = d

	# Rolling windows — prune stale entries before reading counts.
	_prune_times(_gm_kill_times)
	_prune_times(_gm_hit_times)

	# score_gained_10s: difference between current score and oldest entry in window.
	var current_score = _level.score
	var win_cutoff    = _gm_play_time - ROLLING_WINDOW
	while _gm_score_history.size() > 1 and _gm_score_history[0]["t"] < win_cutoff:
		_gm_score_history.pop_front()
	var score_gained = current_score - \
		(_gm_score_history[0]["s"] if _gm_score_history.size() > 0 else current_score)
	_gm_score_history.append({"t": _gm_play_time, "s": current_score})

	var snap: Array = [
		_gm_play_time,
		current_score,
		score_gained,
		_level.lives,
		px_norm, py_norm,
		is_invinc,
		_gm_time_since_last_hit,
		enemy_count, scout_count, hunter_count, bruiser_count,
		total_threat,
		(sum_enemy_y / enemy_count / screen.y) if enemy_count > 0 else 0.0,
		(nearest_dist / diag) if nearest_dist < INF else 1.0,
		get_tree().get_nodes_in_group("player_bullets").size(),
		get_tree().get_nodes_in_group("enemy_bullets").size(),
		_level.spawn_budget,
		_gm_kill_times.size(),
		_gm_hit_times.size(),
	]

	_buffer.append(snap)
	if _buffer.size() > SEQ_LEN:
		_buffer.pop_front()

# ── Rolling-window helpers ────────────────────────────────────────────────────

func _on_kill():
	_gm_kill_times.append(_gm_play_time)

func _on_hit():
	_gm_hit_times.append(_gm_play_time)
	_gm_time_since_last_hit = 0.0

func _prune_times(arr: Array) -> void:
	var cutoff = _gm_play_time - ROLLING_WINDOW
	while arr.size() > 0 and arr[0] < cutoff:
		arr.pop_front()

# ── HTTP ──────────────────────────────────────────────────────────────────────

func _send_request():
	if _buffer.is_empty():
		return
	var err = _http.request(
		SERVER_URL,
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		JSON.stringify({"snapshots": _buffer})
	)
	if err == OK:
		_waiting = true

func _on_response(_result, response_code, _headers, body):
	_waiting = false

	if response_code != 200:
		# Server unreachable or errored — relinquish control this tick.
		_level.gm_connected = false
		_level.trigger_wave()
		return

	_level.gm_connected = true

	var data = JSON.parse_string(body.get_string_from_utf8())
	if data == null or not data.has("actions"):
		_level.trigger_wave()
		return

	_apply_top_action(data["actions"])

# ── Action dispatch ───────────────────────────────────────────────────────────

func _apply_top_action(weights: Dictionary):
	var best_action = "hold"
	var best_weight = 0.0
	for action in weights:
		if weights[action] > best_weight:
			best_weight = weights[action]
			best_action = action

	print("GM-AI → %s (%.2f)" % [best_action, best_weight])

	if _visualizer:
		_visualizer.update(weights, best_action, _buffer)

	if _execute(best_action):
		_level.trigger_wave()

# Returns true if a wave should be spawned after this action.
func _execute(action: String) -> bool:
	match action:
		"hold":
			return false

		"budget_increase":
			_level.spawn_budget = minf(
				_level.spawn_budget * (1.0 + BUDGET_NUDGE), _level.BUDGET_CAP)
			return true

		"budget_decrease":
			_level.spawn_budget = maxf(
				_level.spawn_budget * (1.0 - BUDGET_NUDGE), _level.BUDGET_FLOOR)
			return true

		"rate_increase":
			_level.spawn_timer.wait_time = maxf(
				_level.spawn_timer.wait_time * (1.0 - RATE_NUDGE), RATE_MIN)
			return true

		"rate_decrease":
			_level.spawn_timer.wait_time = minf(
				_level.spawn_timer.wait_time * (1.0 + RATE_NUDGE), RATE_MAX)
			return true

		"force_swarm":
			_level.force_next_wave_size = 4   # pack the next wave with enemies
			return true

		"force_elite":
			_level.force_next_type = "bruiser"
			return true

		"force_chase":
			_level.force_next_pattern = "chase"
			return true

		"force_diagonal":
			# Random direction — the label means "diagonal", not a specific side.
			_level.force_next_pattern = ["diagonal_left", "diagonal_right"].pick_random()
			return true

		"force_rest":
			_rest_ticks = 2   # skip the next 2 spawn ticks
			return false

		"clear_screen":
			for e in get_tree().get_nodes_in_group("enemies"):
				e.queue_free()
			return false

		"surge":
			_level.spawn_budget = minf(
				_level.spawn_budget * (1.0 + SURGE_NUDGE), _level.BUDGET_CAP)
			_level.spawn_timer.wait_time = maxf(
				_level.spawn_timer.wait_time * (1.0 - RATE_NUDGE), RATE_MIN)
			return true

		"ease":
			_level.spawn_budget = maxf(
				_level.spawn_budget * (1.0 - SURGE_NUDGE), _level.BUDGET_FLOOR)
			_level.spawn_timer.wait_time = minf(
				_level.spawn_timer.wait_time * (1.0 + RATE_NUDGE), RATE_MAX)
			return false   # skip spawn — backing off entirely

	return false
