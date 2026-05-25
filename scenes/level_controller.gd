extends Node2D

var enemy_scene = preload("res://scenes/enemy_ship.tscn")

@onready var spawn_timer = $SpawnTimer
@onready var player_root = $player
@onready var player_body = $player/CharacterBody2D

enum State { MENU, PLAYING }
var state = State.MENU

signal enemy_killed
signal player_damaged

var score: int = 0
var lives: int = 3
var high_score: int = 0
var last_score: int = 0
var respawn_pause: float = 0.0

# --------------- Enemy types ---------------

var _enemy_types: Array[EnemyData] = []
var _telemetry: Node

# --------------- Threat budget spawner ---------------
# Each timer tick, _build_wave() fills the current budget with enemy picks.
# Enemies are then released one at a time with a short stagger so formations
# feel like waves rather than a single simultaneous pop.
#
# To extend later:
#   - Increase BUDGET_CAP or BUDGET_GROWTH_RATE to ramp difficulty faster.
#   - Add wave-strategy weighting (e.g. prefer lines over mixed at low budget).
#   - Tie spawn_timer.wait_time to budget level for pacing control.

const BUDGET_START: float       = 5.0                    # threat points at game start
const BUDGET_FLOOR: float       = BUDGET_START * 2.0 / 3.0  # ≈ 3.33 — GM can go below start
const BUDGET_CAP: float         = 25.0                   # ceiling so late-game stays manageable
const BUDGET_GROWTH_RATE: float = 0.12                   # threat points gained per second
const MAX_WAVE_SIZE: int        = 5     # hard cap on enemies per wave
const SPAWN_STAGGER: float      = 0.20  # seconds between enemies in a wave

var spawn_budget: float = BUDGET_START
var _spawn_queue: Array = []            # Array of {type, pattern, pos}
var _stagger_timer: float = 0.0

# GM-AI hints — set by gm_controller.gd, consumed by _build_wave() then cleared.
var force_next_type: String    = ""   # if set, next wave uses only this enemy type
var force_next_pattern: String = ""   # if set, next wave uses only this pattern
var force_next_wave_size: int  = 0    # if > 0, overrides MAX_WAVE_SIZE for one wave
var gm_connected: bool         = false  # true while GM server is responding

# UI nodes built in _ready
var hud: CanvasLayer
var score_label: Label
var lives_label: Label
var menu_overlay: ColorRect
var title_label: Label
var final_score_label: Label
var best_score_label: Label
var telemetry_checkbox: CheckBox
var visualizer_hint_label: Label

# Audio
var _sfx_enemy_explosion: AudioStreamWAV
var _sfx_player_hit: AudioStreamWAV
var _sfx_bonus_life: AudioStreamWAV

const BONUS_LIFE_SCORE: int = 2500
var _next_life_score: int = BONUS_LIFE_SCORE

func _ready():
	add_to_group("level")
	_telemetry = preload("res://scenes/telemetry.gd").new()
	add_child(_telemetry)
	spawn_timer.timeout.connect(_on_spawn_timer)
	spawn_timer.wait_time = 2.75
	_setup_enemy_types()
	_sfx_enemy_explosion = _make_enemy_explosion_sound()
	_sfx_player_hit = _make_player_hit_sound()
	_sfx_bonus_life = _make_bonus_life_sound()
	_build_ui()
	_enter_menu()

# --------------- Enemy type definitions ---------------
# To add a new type: create an EnemyData, fill its fields, append to _enemy_types.
# Sprite: set .texture + .sprite_region (leave region size at 0 for a single-sprite file).
# Shooting: set .fire_rate > 0 (shots per second).
# The .threat_value property is computed automatically — no manual entry needed.

func _setup_enemy_types():
	var sheet = load("res://sprites/tiny-spaceships/tinyShip4.png")

	# Scout — fast, 1 HP, diagonals only.  threat ≈ 3.7
	var scout        = EnemyData.new()
	scout.type_name  = "scout"
	scout.texture    = sheet
	scout.sprite_region   = Rect2(86, 22, 30, 22)
	scout.sprite_modulate = Color.WHITE
	scout.max_health = 1
	scout.speed      = 175.0
	scout.available_patterns = ["diagonal_left", "diagonal_right"]
	scout.fire_rate  = 0.0   # score_value auto = 10
	_enemy_types.append(scout)

	# Hunter — medium speed, 2 HP, chase only.  threat ≈ 5.3
	var hunter        = EnemyData.new()
	hunter.type_name  = "hunter"
	hunter.texture    = sheet
	hunter.sprite_region   = Rect2(86, 22, 30, 22)
	hunter.sprite_modulate = Color(0.55, 0.8, 1.0)   # blue tint
	hunter.max_health = 2
	hunter.speed      = 100.0
	hunter.available_patterns = ["chase"]
	hunter.fire_rate  = 0.0   # score_value auto = 20
	_enemy_types.append(hunter)

	# Bruiser — slow, 3 HP, all patterns.  threat ≈ 6.4
	var bruiser        = EnemyData.new()
	bruiser.type_name  = "bruiser"
	bruiser.texture    = sheet
	bruiser.sprite_region   = Rect2(86, 22, 30, 22)
	bruiser.sprite_modulate = Color(1.0, 0.45, 0.45) # red tint
	bruiser.max_health = 3
	bruiser.speed      = 70.0
	bruiser.available_patterns = ["diagonal_left", "diagonal_right", "chase"]
	bruiser.fire_rate  = 0.5   # 1 shot every 2 seconds; score_value auto = 45
	_enemy_types.append(bruiser)

# --------------- Sound generation ---------------

func _make_noise_sound(duration: float, volume: float) -> AudioStreamWAV:
	var sample_rate = 22050
	var num_samples = int(duration * sample_rate)
	var data = PackedByteArray()
	data.resize(num_samples * 2)
	for i in num_samples:
		var t = float(i) / sample_rate
		var envelope = pow(1.0 - (t / duration), 2.0) * volume
		var sample = int((randf() * 2.0 - 1.0) * envelope * 32767)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var stream = AudioStreamWAV.new()
	stream.data = data
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	return stream

func _make_enemy_explosion_sound() -> AudioStreamWAV:
	var sample_rate = 22050
	var duration    = 0.45
	var num_samples = int(duration * sample_rate)
	var data        = PackedByteArray()
	data.resize(num_samples * 2)
	for i in num_samples:
		var t        = float(i) / sample_rate
		var progress = float(i) / num_samples
		# Low boom: frequency sweeps 80 → 25 Hz for a heavy thud
		var boom_freq = lerp(80.0, 25.0, pow(progress, 0.4))
		var boom      = sin(t * boom_freq * TAU) * pow(1.0 - progress, 0.7)
		# Noise crackle on top, fades faster than the boom
		var noise     = (randf() * 2.0 - 1.0) * pow(1.0 - progress, 2.0) * 0.5
		var envelope  = pow(1.0 - progress, 0.8) * 0.92
		var sample    = clamp(int((boom + noise) * envelope * 32767), -32768, 32767)
		data[i * 2]     = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var stream      = AudioStreamWAV.new()
	stream.data     = data
	stream.format   = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	return stream

func _make_bonus_life_sound() -> AudioStreamWAV:
	var sample_rate = 22050
	var duration    = 0.45
	var num_samples = int(duration * sample_rate)
	var data        = PackedByteArray()
	data.resize(num_samples * 2)
	# Two rising tones: a short low note then a higher note
	var notes = [440.0, 660.0, 880.0]
	var note_len = num_samples / notes.size()
	for i in num_samples:
		var note_idx = mini(i / note_len, notes.size() - 1)
		var t        = float(i % note_len) / sample_rate
		var t_norm   = float(i % note_len) / note_len
		var envelope = (1.0 - t_norm) * 0.7
		var sample   = clamp(int(sin(t * notes[note_idx] * TAU) * envelope * 32767), -32768, 32767)
		data[i * 2]     = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var stream      = AudioStreamWAV.new()
	stream.data     = data
	stream.format   = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	return stream

func _make_player_hit_sound() -> AudioStreamWAV:
	var sample_rate = 22050
	var duration = 0.4
	var num_samples = int(duration * sample_rate)
	var data = PackedByteArray()
	data.resize(num_samples * 2)
	for i in num_samples:
		var t = float(i) / sample_rate
		var envelope = pow(1.0 - (t / duration), 1.5) * 0.85
		var noise = (randf() * 2.0 - 1.0) * 0.55
		var tone = sin(t * 200.0 * TAU) * 0.45
		var sample = clamp(int((noise + tone) * envelope * 32767), -32768, 32767)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var stream = AudioStreamWAV.new()
	stream.data = data
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	return stream

func _play_sound(stream: AudioStreamWAV, volume_db: float = 0.0, pitch: float = 1.0):
	var player = AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch
	add_child(player)
	player.play()
	player.finished.connect(player.queue_free)

# --------------- Explosions ---------------

func _spawn_explosion(pos: Vector2, color: Color):
	var exp = CPUParticles2D.new()
	exp.position = pos
	exp.z_index = 10
	exp.one_shot = true
	exp.explosiveness = randf_range(0.88, 0.98)
	exp.amount = randi_range(16, 30)
	exp.lifetime = randf_range(0.38, 0.72)
	exp.direction = Vector2(0, -1)
	exp.spread = 180.0
	exp.initial_velocity_min = randf_range(40.0, 75.0)
	exp.initial_velocity_max = randf_range(130.0, 210.0)
	exp.gravity = Vector2.ZERO
	exp.scale_amount_min = randf_range(1.8, 3.2)
	exp.scale_amount_max = randf_range(4.5, 7.5)
	# Tint the colour slightly so no two explosions look identical
	var tint = Color(randf_range(0.85, 1.0), randf_range(0.85, 1.0), randf_range(0.85, 1.0))
	exp.color = Color(color.r * tint.r, color.g * tint.g, color.b * tint.b)
	add_child(exp)
	exp.emitting = true
	exp.finished.connect(exp.queue_free)

# --------------- UI ---------------

func _build_ui():
	var sw = get_viewport_rect().size.x
	var sh = get_viewport_rect().size.y
	var cx = sw / 2.0
	var cy = sh / 2.0

	hud = CanvasLayer.new()
	add_child(hud)

	score_label = _make_label(Vector2(16, 12), 22)
	hud.add_child(score_label)

	lives_label = _make_label(Vector2(16, 42), 22)
	hud.add_child(lives_label)

	menu_overlay = ColorRect.new()
	menu_overlay.position = Vector2.ZERO
	menu_overlay.size = Vector2(sw, sh)
	menu_overlay.color = Color(0, 0, 0, 0.7)
	hud.add_child(menu_overlay)

	title_label = _make_label(Vector2(cx - 210, cy - 110), 38)
	title_label.text = "SPACE BASE BOMB RUN"
	menu_overlay.add_child(title_label)

	final_score_label = _make_label(Vector2(cx - 100, cy - 40), 24)
	menu_overlay.add_child(final_score_label)

	best_score_label = _make_label(Vector2(cx - 100, cy), 24)
	menu_overlay.add_child(best_score_label)

	var prompt = _make_label(Vector2(cx - 160, cy + 60), 28)
	prompt.text = "PRESS ENTER TO BEGIN"
	menu_overlay.add_child(prompt)

	telemetry_checkbox = CheckBox.new()
	telemetry_checkbox.text = "Record telemetry & screenshots"
	telemetry_checkbox.button_pressed = true
	telemetry_checkbox.auto_translate = false
	telemetry_checkbox.position = Vector2(cx - 160, cy + 108)
	telemetry_checkbox.add_theme_font_size_override("font_size", 16)
	telemetry_checkbox.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	telemetry_checkbox.add_theme_color_override("font_focus_color", Color(0.7, 0.7, 0.7))
	telemetry_checkbox.add_theme_color_override("font_hover_color", Color(0.9, 0.9, 0.9))
	menu_overlay.add_child(telemetry_checkbox)

	visualizer_hint_label = _make_label(Vector2(cx - 160, cy + 140), 14)
	visualizer_hint_label.add_theme_color_override("font_color", Color(0.35, 1.0, 0.5))
	visualizer_hint_label.visible = false
	menu_overlay.add_child(visualizer_hint_label)

func _make_label(pos: Vector2, font_size: int) -> Label:
	var l = Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", font_size)
	l.auto_translate = false
	return l

# --------------- Game state ---------------

func _enter_menu():
	_telemetry.end_session()
	state = State.MENU
	spawn_timer.stop()
	_spawn_queue.clear()
	for e in get_tree().get_nodes_in_group("enemies"):
		e.queue_free()
	player_body.active = false
	player_root.visible = false
	menu_overlay.visible = true
	final_score_label.text = "Last Score: %d" % last_score if last_score > 0 else ""
	best_score_label.text = "Best Score: %d" % high_score if high_score > 0 else ""

func _start_game():
	var record = telemetry_checkbox.button_pressed
	_telemetry.start_session(record)
	state = State.PLAYING
	score = 0
	lives = 3
	respawn_pause = 0.0
	spawn_budget = BUDGET_START
	_next_life_score = BONUS_LIFE_SCORE
	_spawn_queue.clear()
	player_body.invincible = false
	player_body.invincible_timer = 0.0
	player_body.modulate.a = 1.0
	player_body.position = Vector2(583, 493)
	player_body.active = true
	player_root.visible = true
	menu_overlay.visible = false
	_update_hud()
	spawn_timer.start()

func is_playing() -> bool:
	return state == State.PLAYING

func _update_hud():
	score_label.text = "Score: %d" % score
	lives_label.text = "Lives: %d" % lives

func _process(delta):
	if state == State.MENU:
		if Input.is_action_just_pressed("start"):
			_start_game()
		# Show hint when the visualizer overlay is active
		var viz = get_tree().get_first_node_in_group("gm_visualizer")
		if viz:
			var active: bool = viz.is_active
			visualizer_hint_label.visible = active
			if active:
				visualizer_hint_label.text = "Visualizer active — press V to toggle"
		return

	if respawn_pause > 0:
		respawn_pause -= delta

	# Grow the threat budget over time
	spawn_budget = minf(spawn_budget + BUDGET_GROWTH_RATE * delta, BUDGET_CAP)

	# Drain the spawn queue with stagger
	if not _spawn_queue.is_empty():
		_stagger_timer -= delta
		if _stagger_timer <= 0.0:
			var entry = _spawn_queue.pop_front()
			_do_spawn(entry.type, entry.pattern, entry.pos)
			_stagger_timer = SPAWN_STAGGER

# --------------- Spawning ---------------

func trigger_wave() -> void:
	if not is_playing() or respawn_pause > 0:
		return
	var wave = _build_wave()
	_spawn_queue.append_array(wave)

func _on_spawn_timer():
	if not is_playing() or respawn_pause > 0:
		return
	if gm_connected:
		return   # GM drives spawning via trigger_wave()
	trigger_wave()

# Fills the current threat budget with enemy picks.
# The budget is NOT spent here — it represents accumulated difficulty pressure.
# Each call consumes a snapshot of the budget for this wave, but the budget
# itself keeps growing in _process so later waves are larger.
func _build_wave() -> Array:
	var wave: Array = []
	var remaining: float = spawn_budget

	# Filter candidate types by GM hint (cleared after use)
	var type_pool: Array = _affordable_types(remaining)
	if force_next_type != "":
		var filtered = type_pool.filter(func(t): return t.type_name == force_next_type)
		if not filtered.is_empty():
			type_pool = filtered
		force_next_type = ""

	var pat_hint: String = force_next_pattern
	force_next_pattern = ""

	# Restrict pool to types that actually support the forced pattern, so the
	# fallback random-pattern branch is never taken for forced waves.
	if pat_hint != "":
		var pat_filtered = type_pool.filter(func(t): return pat_hint in t.available_patterns)
		if not pat_filtered.is_empty():
			type_pool = pat_filtered

	var wave_cap: int = force_next_wave_size if force_next_wave_size > 0 else MAX_WAVE_SIZE
	force_next_wave_size = 0

	while type_pool.size() > 0 and wave.size() < wave_cap:
		var pick: EnemyData = type_pool[randi() % type_pool.size()]
		var pat: String = pat_hint if pat_hint != "" else \
				pick.available_patterns[randi() % pick.available_patterns.size()]
		wave.append({ type = pick, pattern = pat, pos = _spawn_pos_for(pat) })
		remaining -= pick.threat_value
		type_pool = _affordable_types(remaining)
		if pat_hint != "":
			var pat_filtered = type_pool.filter(func(t): return pat_hint in t.available_patterns)
			if not pat_filtered.is_empty():
				type_pool = pat_filtered

	_distribute_wave_positions(wave)
	return wave

# Space out ships within a wave so they don't spawn on top of each other.
# Groups entries by pattern and distributes them evenly along the relevant
# spawn edge. Single-entry groups keep their already-random position.
const WAVE_SPACING: float = 72.0   # px between ship centers along spawn edge

func _distribute_wave_positions(wave: Array) -> void:
	if wave.size() <= 1:
		return
	var s = get_viewport_rect().size
	var groups: Dictionary = {}
	for entry in wave:
		if not groups.has(entry.pattern):
			groups[entry.pattern] = []
		groups[entry.pattern].append(entry)
	for pat in groups:
		var grp: Array = groups[pat]
		var n: int = grp.size()
		if n <= 1:
			continue
		var span: float = (n - 1) * WAVE_SPACING
		match pat:
			"diagonal_right":
				var y0 := clampf(s.y * 0.15 - span * 0.5, 5.0, s.y * 0.35 - span)
				for i in n:
					grp[i].pos = Vector2(-20.0, y0 + i * WAVE_SPACING)
			"diagonal_left":
				var y0 := clampf(s.y * 0.15 - span * 0.5, 5.0, s.y * 0.35 - span)
				for i in n:
					grp[i].pos = Vector2(s.x + 20.0, y0 + i * WAVE_SPACING)
			"chase":
				var x0 := clampf(s.x * 0.5 - span * 0.5, s.x * 0.1, s.x * 0.9 - span)
				for i in n:
					grp[i].pos = Vector2(x0 + i * WAVE_SPACING, -20.0)

func _affordable_types(budget: float) -> Array:
	var out: Array = []
	for t in _enemy_types:
		if t.threat_value <= budget:
			out.append(t)
	return out

func _do_spawn(type_data: EnemyData, pat: String, pos: Vector2):
	var enemy = enemy_scene.instantiate()
	enemy.setup(type_data, pat)
	enemy.position = pos
	enemy.destroyed.connect(_on_enemy_destroyed)
	add_child(enemy)

func _spawn_pos_for(pattern: String) -> Vector2:
	var s = get_viewport_rect().size
	match pattern:
		"diagonal_right":
			return Vector2(-20, randf_range(0, s.y * 0.3))
		"diagonal_left":
			return Vector2(s.x + 20, randf_range(0, s.y * 0.3))
		"chase":
			return Vector2(randf_range(s.x * 0.25, s.x * 0.75), -20)
	return Vector2(s.x * 0.5, -20)

func _on_enemy_destroyed(pos: Vector2, points: int):
	if state != State.PLAYING:
		return
	_telemetry.record_kill()
	enemy_killed.emit()
	score += points
	if score > high_score:
		high_score = score
	while score >= _next_life_score:
		lives += 1
		_next_life_score += BONUS_LIFE_SCORE
		_play_sound(_sfx_bonus_life, 0.0)
		_show_bonus_life_text()
	_update_hud()
	_spawn_explosion(pos, Color(1.0, 0.55, 0.1))
	_play_sound(_sfx_enemy_explosion, 0.0, randf_range(0.78, 1.05))

func _show_bonus_life_text():
	var lbl = _make_label(Vector2(0, 0), 22)
	lbl.text = "+ BONUS LIFE"
	lbl.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5))
	lbl.position = Vector2(get_viewport_rect().size.x / 2.0 - 90, get_viewport_rect().size.y * 0.35)
	hud.add_child(lbl)
	var tween = create_tween()
	tween.tween_property(lbl, "position:y", lbl.position.y - 40, 1.0)
	tween.parallel().tween_property(lbl, "modulate:a", 0.0, 1.0)
	tween.tween_callback(lbl.queue_free)

func on_player_hit():
	_telemetry.record_hit()
	player_damaged.emit()
	_spawn_explosion(player_body.global_position, Color(0.3, 0.8, 1.0))
	_play_sound(_sfx_player_hit, 0.0)
	lives -= 1
	_update_hud()
	if lives <= 0:
		last_score = score
		if score > high_score:
			high_score = score
		_enter_menu()
	else:
		respawn_pause = 4.0
