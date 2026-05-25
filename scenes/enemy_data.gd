class_name EnemyData
extends Resource

# Sprite
@export var texture: Texture2D = null
@export var sprite_region: Rect2 = Rect2()        # leave size at (0,0) to use full texture
@export var sprite_modulate: Color = Color.WHITE

# Identity
@export var type_name: String = ""

# Stats
@export var max_health: int = 1
@export var speed: float = 120.0
# score_value: auto-calculated — 10 per HP + 15 if the enemy can shoot.
var score_value: int:
	get:
		return max_health * 10 + (15 if fire_rate > 0.0 else 0)

# Movement — enemy randomly picks one of these each spawn
@export var available_patterns: Array = []

# Shooting — shots per second; 0.0 = does not shoot
@export var fire_rate: float = 0.0

# Threat value: auto-calculated from stats.
# Used by the spawner's threat budget to decide wave composition.
#   health weight  : 1.5 per HP  (durability)
#   speed weight   : speed / 80  (danger from movement)
#   fire_rate weight: fire_rate * 4  (shooting is very punishing)
#   chase bonus    : +1.0        (hardest pattern to dodge)
var threat_value: float:
	get:
		var t = float(max_health) * 1.5 + speed / 80.0
		if fire_rate > 0.0:
			t += fire_rate * 4.0
		if "chase" in available_patterns:
			t += 1.0
		return t
