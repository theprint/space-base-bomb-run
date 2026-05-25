extends Area2D

const SPEED       = 280.0
const PULSE_FREQ  = 7.0   # oscillations per second
const RADIUS_BASE = 5.0
const RADIUS_AMP  = 2.5   # pulse swings ±this many pixels

# Set by the spawner before add_child(). Defaults to straight down.
var velocity: Vector2 = Vector2(0.0, SPEED)

var _pulse: float = 0.0

func _ready():
	add_to_group("enemy_bullets")
	body_entered.connect(_on_body_entered)

func _process(delta):
	_pulse += delta * PULSE_FREQ * TAU
	position += velocity * delta
	queue_redraw()
	var s = get_viewport_rect().size
	if position.y > s.y + 40 or position.y < -40 or position.x < -40 or position.x > s.x + 40:
		queue_free()

func _draw():
	var r = RADIUS_BASE + sin(_pulse) * RADIUS_AMP
	# Outer glow
	draw_circle(Vector2.ZERO, r + 4.0, Color(1.0, 0.25, 0.05, 0.25))
	# Mid glow
	draw_circle(Vector2.ZERO, r + 1.5, Color(1.0, 0.35, 0.1, 0.55))
	# Solid core
	draw_circle(Vector2.ZERO, r, Color(1.0, 0.6, 0.2))

func _on_body_entered(body):
	if body.has_method("take_hit"):
		body.take_hit()
		queue_free()
