extends Area2D

signal destroyed(pos: Vector2, score: int)

# Assigned via setup() before add_child() so _ready() can read it.
var data: EnemyData = null

var health: int = 1
var direction: Vector2 = Vector2.ZERO
var screen_size: Vector2
var pattern: String = ""
var chase_phase: int = 0

var _shoot_timer: float = 0.0
var _bullet_scene = null
var _shoot_sfx: AudioStreamPlayer = null

# Minimum center-to-center distance before separation kicks in.
# Ship sprite is 30 * 2.25 = 67.5 px wide; add 3 px gap → 71, rounded to 72.
const SEPARATION_DIST: float = 72.0

# Call after instantiate() but before add_child().
# preset_pattern: pass the pattern chosen by the spawner so spawn position and
# movement stay consistent. Leave empty to let the enemy pick at random.
func setup(enemy_data: EnemyData, preset_pattern: String = "") -> void:
	data = enemy_data
	if preset_pattern != "":
		pattern = preset_pattern
	else:
		pattern = data.available_patterns[randi() % data.available_patterns.size()]

func _ready():
	screen_size = get_viewport_rect().size
	add_to_group("enemies")
	body_entered.connect(_on_body_entered)

	# Disable CharacterBody2D physics so it doesn't physically push the player.
	# Collision detection is handled by the parent Area2D instead.
	$CharacterBody2D.collision_layer = 0
	$CharacterBody2D.collision_mask = 0

	health = data.max_health

	var sprite = $CharacterBody2D/Sprite2D
	sprite.texture = data.texture
	if data.sprite_region.size.x > 0:
		sprite.region_enabled = true
		sprite.region_rect = data.sprite_region
	sprite.modulate = data.sprite_modulate

	if data.fire_rate > 0.0:
		_bullet_scene = load("res://scenes/enemy_bullet.tscn")
		_shoot_timer = 1.0 / data.fire_rate
		_shoot_sfx = AudioStreamPlayer.new()
		_shoot_sfx.stream = _make_shoot_sound()
		_shoot_sfx.volume_db = -6.0
		add_child(_shoot_sfx)

	match pattern:
		"diagonal_left":
			direction = Vector2(-1, 1).normalized()
		"diagonal_right":
			direction = Vector2(1, 1).normalized()
		"chase":
			direction = Vector2(0, 1)
			chase_phase = 0

func _process(delta):
	if pattern == "chase":
		if chase_phase == 0:
			if global_position.y >= screen_size.y * 0.5:
				chase_phase = 1
		else:
			var player = get_tree().get_first_node_in_group("player_body")
			if player:
				var x_diff = player.global_position.x - global_position.x
				direction.x = sign(x_diff) * min(abs(x_diff) / 100.0, 1.0)
				direction = direction.normalized()

	position += direction * data.speed * delta
	_apply_separation(delta)

	if data.fire_rate > 0.0:
		_shoot_timer -= delta
		if _shoot_timer <= 0.0:
			_shoot()
			_shoot_timer = 1.0 / data.fire_rate

	if global_position.y > screen_size.y + 40 or global_position.x < -40 or global_position.x > screen_size.x + 40:
		queue_free()

func _make_shoot_sound() -> AudioStreamWAV:
	var sample_rate = 22050
	var duration    = 0.12
	var num_samples = int(duration * sample_rate)
	var data = PackedByteArray()
	data.resize(num_samples * 2)
	for i in num_samples:
		var t        = float(i) / sample_rate
		var progress = float(i) / num_samples
		var freq     = lerp(420.0, 80.0, pow(progress, 0.6))
		var envelope = pow(1.0 - progress, 1.2) * 0.75
		var noise    = (randf() * 2.0 - 1.0) * 0.15
		var sample   = clamp(int((sin(t * freq * TAU) + noise) * envelope * 32767), -32768, 32767)
		data[i * 2]     = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var stream = AudioStreamWAV.new()
	stream.data      = data
	stream.format    = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate  = sample_rate
	return stream

func _shoot():
	# Only fire when above the player on the y-axis
	var player = get_tree().get_first_node_in_group("player_body")
	if not player or global_position.y >= player.global_position.y:
		return
	var spawn_pos = global_position + Vector2(0, -50)
	var aim_dir = (player.global_position - spawn_pos).normalized()
	var bullet = _bullet_scene.instantiate()
	bullet.velocity = aim_dir * 280.0
	get_parent().add_child(bullet)
	bullet.global_position = spawn_pos
	if _shoot_sfx:
		_shoot_sfx.play()

func _apply_separation(delta: float) -> void:
	for other in get_tree().get_nodes_in_group("enemies"):
		if other == self:
			continue
		var diff: Vector2 = global_position - other.global_position
		var dist_sq: float = diff.length_squared()
		if dist_sq < SEPARATION_DIST * SEPARATION_DIST and dist_sq > 0.01:
			var dist: float = sqrt(dist_sq)
			var overlap: float = SEPARATION_DIST - dist
			# Push proportionally to overlap, capped at 1.5× own speed-per-frame
			# so fast enemies aren't shoved off their path.
			var push: float = minf(overlap * 0.5, data.speed * delta * 1.5)
			position += (diff / dist) * push

func _on_body_entered(body):
	if body.has_method("take_hit"):
		body.take_hit()
		take_damage(1)

func take_damage(amount: int):
	health -= amount
	if health <= 0:
		destroyed.emit(global_position + Vector2(0, -59), data.score_value)
		queue_free()
