extends CharacterBody2D

const SPEED = 240.0
const FIRE_RATE = 0.18
const INVINCIBLE_DURATION = 4.0

var bullet_scene = preload("res://scenes/bullet.tscn")
var fire_timer = 0.0
var active: bool = false
var invincible: bool = false
var invincible_timer: float = 0.0

var _shoot_player: AudioStreamPlayer

func _ready():
	add_to_group("player_body")
	_shoot_player = AudioStreamPlayer.new()
	_shoot_player.stream = _make_shoot_sound()
	_shoot_player.volume_db = -4.0
	add_child(_shoot_player)

func _make_shoot_sound() -> AudioStreamWAV:
	var sample_rate = 22050
	var num_samples = int(0.07 * sample_rate)
	var data = PackedByteArray()
	data.resize(num_samples * 2)
	for i in num_samples:
		var t = float(i) / sample_rate
		var progress = float(i) / num_samples
		var freq = lerp(1400.0, 500.0, progress)
		var envelope = pow(1.0 - progress, 1.5) * 0.6
		var sample = int(sin(t * freq * TAU) * envelope * 32767)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var stream = AudioStreamWAV.new()
	stream.data = data
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	return stream

func take_hit():
	if invincible or not active:
		return
	invincible = true
	invincible_timer = INVINCIBLE_DURATION
	get_tree().get_first_node_in_group("level").on_player_hit()

func get_input():
	var input_direction = Input.get_vector("left", "right", "up", "down")
	velocity = input_direction * SPEED

func _physics_process(delta):
	if not active:
		return

	if invincible:
		invincible_timer -= delta
		modulate.a = 0.3 if fmod(invincible_timer, 0.3) < 0.15 else 1.0
		if invincible_timer <= 0:
			invincible = false
			modulate.a = 1.0

	get_input()
	move_and_slide()

	var screen_size = get_viewport_rect().size
	var margin_x = screen_size.x * 0.075
	position.x = clampf(position.x, margin_x, screen_size.x - margin_x)
	position.y = clampf(position.y, screen_size.y * 0.6, screen_size.y * 0.95)

	fire_timer -= delta
	if Input.is_action_just_pressed("fire") and fire_timer <= 0:
		var bullet = bullet_scene.instantiate()
		bullet.position = position + Vector2(0, -20)
		get_parent().add_child(bullet)
		fire_timer = FIRE_RATE
		_shoot_player.play()
