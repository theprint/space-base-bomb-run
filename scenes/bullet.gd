extends Area2D

const SPEED = 540.0

func _ready():
	add_to_group("player_bullets")
	area_entered.connect(_on_area_entered)

func _process(delta):
	position.y -= SPEED * delta
	if position.y < -20:
		queue_free()

func _on_area_entered(area):
	if area.is_in_group("enemies"):
		area.take_damage(1)
		queue_free()
