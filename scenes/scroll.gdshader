shader_type canvas_item;

uniform float scroll_speed = 0.075;

void vertex() {
	// Called for every vertex the material is visible on.
	UV.y -= TIME * scroll_speed;
}
