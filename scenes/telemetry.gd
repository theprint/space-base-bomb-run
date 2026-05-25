extends Node
# Telemetry singleton — registered as autoload "Telemetry" in project.godot.
#
# Captures periodic game-state snapshots to CSV for GM-AI training.
# Each game session produces one CSV file and (optionally) a folder of
# screenshots, both stored under user://telemetry/.
#
# Call from level_controller:
#   Telemetry.start_session()   — on game start
#   Telemetry.end_session()     — on game over / return to menu
#   Telemetry.record_kill()     — each time an enemy is destroyed
#   Telemetry.record_hit()      — each time the player takes a hit

# ---- Configuration ----
const SNAPSHOT_INTERVAL: float  = 4.0    # seconds between snapshots
const ROLLING_WINDOW: float     = 10.0   # seconds for kill/hit/score rolling counts
const SAVE_DIR: String          = "res://data/"


# ---- Session state ----
var _active: bool               = false
var _file: FileAccess           = null
var _session_id: String         = ""
var _screenshot_dir: String     = ""
var _snapshot_index: int        = 0
var _snapshot_timer: float      = 0.0
var _play_time: float           = 0.0

# ---- Rolling-window event queues ----
# Each entry is a play_time (float) at which the event occurred.
# Entries older than ROLLING_WINDOW are pruned before each snapshot.
var _kill_times: Array          = []
var _hit_times: Array           = []

# Score history for computing score_gained_10s.
# Each entry: {"t": float, "s": int}
var _score_history: Array       = []

var _time_since_last_hit: float = 0.0

# ---- Public API ----

func start_session(record: bool = true) -> void:
	if not record:
		_active = false
		return

	DirAccess.make_dir_recursive_absolute(SAVE_DIR)

	_session_id     = Time.get_datetime_string_from_system(true).replace(":", "-")
	_screenshot_dir = SAVE_DIR + "screenshots/" + _session_id + "/"
	DirAccess.make_dir_recursive_absolute(_screenshot_dir)

	_file = FileAccess.open(SAVE_DIR + _session_id + ".csv", FileAccess.WRITE)
	_file.store_line(_csv_header())

	_active             = true
	_snapshot_index     = 0
	_snapshot_timer     = SNAPSHOT_INTERVAL
	_play_time          = 0.0
	_time_since_last_hit = 0.0
	_kill_times.clear()
	_hit_times.clear()
	_score_history.clear()

func end_session() -> void:
	if _file:
		_file.close()
		_file = null
	_active = false

func record_kill() -> void:
	if _active:
		_kill_times.append(_play_time)

func record_hit() -> void:
	if _active:
		_hit_times.append(_play_time)
		_time_since_last_hit = 0.0

# ---- Internal ----

func _process(delta: float) -> void:
	if not _active:
		return
	_play_time          += delta
	_time_since_last_hit += delta
	_snapshot_timer     -= delta
	if _snapshot_timer <= 0.0:
		_snapshot_timer = SNAPSHOT_INTERVAL
		_take_snapshot()

func _take_snapshot() -> void:
	var level = get_tree().get_first_node_in_group("level")
	if not level:
		return

	var player      = get_tree().get_first_node_in_group("player_body")
	var screen      = get_viewport().get_visible_rect().size
	var diag        = screen.length()

	# ---- Player ----
	var px_norm      = 0.5
	var py_norm      = 0.5
	var is_invinc    = 0
	if player:
		px_norm   = player.global_position.x / screen.x
		py_norm   = player.global_position.y / screen.y
		is_invinc = 1 if player.invincible else 0

	# ---- Enemies ----
	var enemies         = get_tree().get_nodes_in_group("enemies")
	var enemy_count     = enemies.size()
	var scout_count     = 0
	var hunter_count    = 0
	var bruiser_count   = 0
	var total_threat    = 0.0
	var sum_enemy_y     = 0.0
	var nearest_dist    = INF

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

	var avg_enemy_y_norm   = (sum_enemy_y / enemy_count / screen.y) if enemy_count > 0 else 0.0
	var nearest_dist_norm  = (nearest_dist / diag) if nearest_dist < INF else 1.0

	# ---- Bullets ----
	var player_bullets = get_tree().get_nodes_in_group("player_bullets").size()
	var enemy_bullets  = get_tree().get_nodes_in_group("enemy_bullets").size()

	# ---- Rolling windows ----
	_prune_times(_kill_times)
	_prune_times(_hit_times)
	var kills_10s = _kill_times.size()
	var hits_10s  = _hit_times.size()

	# Score gained in last ROLLING_WINDOW seconds
	var current_score = level.score
	_prune_score_history()
	var score_gained  = current_score - (_score_history[0]["s"] if _score_history.size() > 0 else current_score)
	_score_history.append({"t": _play_time, "s": current_score})

	# ---- Screenshot ----
	var screenshot_file = "snap_%05d.png" % _snapshot_index
	_save_screenshot(_screenshot_dir + screenshot_file)

	# ---- Write row ----
	var row: Array = [
		_snapshot_index,
		"%.3f" % Time.get_unix_time_from_system(),
		"%.2f" % _play_time,
		current_score,
		score_gained,
		level.lives,
		"%.4f" % px_norm,
		"%.4f" % py_norm,
		is_invinc,
		"%.2f" % minf(_time_since_last_hit, 999.0),
		enemy_count,
		scout_count,
		hunter_count,
		bruiser_count,
		"%.3f" % total_threat,
		"%.4f" % avg_enemy_y_norm,
		"%.4f" % nearest_dist_norm,
		player_bullets,
		enemy_bullets,
		"%.2f" % level.spawn_budget,
		kills_10s,
		hits_10s,
		screenshot_file,
	]
	var parts: PackedStringArray = []
	for v in row:
		parts.append(str(v))
	_file.store_line(",".join(parts))
	_file.flush()   # ensure data reaches disk even if the game crashes

	_snapshot_index += 1

func _prune_times(arr: Array) -> void:
	var cutoff = _play_time - ROLLING_WINDOW
	while arr.size() > 0 and arr[0] < cutoff:
		arr.pop_front()

func _prune_score_history() -> void:
	var cutoff = _play_time - ROLLING_WINDOW
	# Keep at least one entry so we always have a baseline
	while _score_history.size() > 1 and _score_history[0]["t"] < cutoff:
		_score_history.pop_front()

func _save_screenshot(path: String) -> void:
	# GPU readback must happen on the main thread — this is unavoidable but fast.
	# PNG compression + disk write are offloaded to a worker thread so the game
	# doesn't stall waiting for the encoder.
	var img = get_viewport().get_texture().get_image()
	WorkerThreadPool.add_task(func(): img.save_png(path))

func _csv_header() -> String:
	var cols: PackedStringArray = [
		"snapshot_index", "unix_timestamp", "play_time",
		"score", "score_gained_10s", "lives",
		"player_x_norm", "player_y_norm", "is_invincible", "time_since_last_hit",
		"enemy_count", "scout_count", "hunter_count", "bruiser_count",
		"total_threat_on_screen", "avg_enemy_y_norm", "nearest_enemy_dist_norm",
		"player_bullets", "enemy_bullets", "spawn_budget",
		"kills_10s", "hits_10s",
		"screenshot_file",
	]
	return ",".join(cols)
