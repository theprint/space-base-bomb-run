extends CanvasLayer
# GM-AI Visualizer — press V to toggle.
#
# Draws a semi-transparent overlay in the top-left corner showing:
#   • A schematic of the transformer network with nodes coloured by output weight
#   • A probability bar chart for all 13 actions
#   • The last chosen action
#
# Performance: _draw() on the inner Control is called ONLY when new prediction
# data arrives (every spawn tick, ~2–4 s), not every frame.  The CanvasLayer
# itself has no per-frame logic.

signal toggled(active: bool)

const PANEL_X: float  = 8.0
const PANEL_Y: float  = 8.0
const PANEL_W: float  = 252.0
const PANEL_H: float  = 394.0

# Ordered list kept in sync with gm_ai/dataset.py ACTIONS.
const ACTIONS: Array = [
	"hold", "budget_increase", "budget_decrease",
	"rate_increase", "rate_decrease",
	"force_swarm", "force_elite", "force_chase", "force_diagonal",
	"force_rest", "clear_screen", "surge", "ease",
]

const ACTION_SHORT: Dictionary = {
	"hold":            "hold",
	"budget_increase": "budget+",
	"budget_decrease": "budget-",
	"rate_increase":   "rate+",
	"rate_decrease":   "rate-",
	"force_swarm":     "swarm",
	"force_elite":     "elite",
	"force_chase":     "chase",
	"force_diagonal":  "diagonal",
	"force_rest":      "rest",
	"clear_screen":    "clear",
	"surge":           "surge",
	"ease":            "ease",
}

var is_active:    bool       = false
var _weights:     Dictionary = {}
var _best_action: String     = ""
var _buffer:      Array      = []

var _panel: _VizControl = null

func _ready() -> void:
	layer = 2           # above HUD (layer 1)
	add_to_group("gm_visualizer")

	_panel = _VizControl.new()
	_panel.viz      = self
	_panel.position = Vector2(PANEL_X, PANEL_Y)
	_panel.size     = Vector2(PANEL_W, PANEL_H)
	_panel.visible  = false
	# Mouse filter: ignore so the panel doesn't eat clicks
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_V:
			is_active = not is_active
			_panel.visible = is_active
			if is_active:
				_panel.queue_redraw()
			toggled.emit(is_active)

# Called by gm_controller after each prediction.
func update(weights: Dictionary, best_action: String, buffer: Array) -> void:
	_weights     = weights
	_best_action = best_action
	_buffer      = buffer
	if is_active and _panel:
		_panel.queue_redraw()

# ── Inner drawing Control ─────────────────────────────────────────────────────

class _VizControl extends Control:
	var viz: Node   # reference back to the outer CanvasLayer

	func _draw() -> void:
		if not viz:
			return

		var pw      = viz.PANEL_W
		var ph      = viz.PANEL_H
		var weights = viz._weights
		var best    = viz._best_action
		var buffer  = viz._buffer
		var font    = ThemeDB.fallback_font

		# ── Background + border ───────────────────────────────────────────────
		draw_rect(Rect2(0, 0, pw, ph), Color(0.04, 0.04, 0.09, 0.84))
		draw_rect(Rect2(0, 0, pw, ph), Color(0.28, 0.55, 1.0, 0.45), false, 1.0)

		var y: float = 10.0

		# ── Title row ─────────────────────────────────────────────────────────
		draw_string(font, Vector2(10, y + 13), "GM-AI VISUALIZER",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.75, 0.88, 1.0))
		# Status dot
		var dot_col: Color
		if not weights.is_empty():
			dot_col = Color(0.3, 1.0, 0.45)    # green — live data
		else:
			dot_col = Color(0.5, 0.5, 0.55)    # grey — no data yet
		draw_circle(Vector2(pw - 14, y + 9), 5.0, dot_col)
		y += 26.0

		_separator(y, pw)
		y += 8.0

		# ── Network diagram ───────────────────────────────────────────────────
		_draw_network(y, pw, weights, best, buffer, font)
		y += 90.0

		_separator(y, pw)
		y += 8.0

		# ── Action probability bars ───────────────────────────────────────────
		_draw_bars(y, pw, weights, best, font)
		y += viz.ACTIONS.size() * 16.0 + 4.0

		_separator(y, pw)
		y += 8.0

		# ── Footer: last chosen action ────────────────────────────────────────
		var footer: String
		if best == "":
			footer = "no prediction yet"
		else:
			footer = "→  %s  (%.2f)" % [best, weights.get(best, 0.0)]
		draw_string(font, Vector2(10, y + 13), footer,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
				Color(0.35, 1.0, 0.5) if best != "" else Color(0.5, 0.5, 0.5))

	# ── Network section ───────────────────────────────────────────────────────

	func _draw_network(y0: float, pw: float, weights: Dictionary,
			best: String, buffer: Array, font: Font) -> void:

		var n_steps:   int   = 8
		var n_actions: int   = viz.ACTIONS.size()  # 13

		# Column x positions
		var inp_x:  float = 22.0
		var tf_cx:  float = pw * 0.44          # transformer box centre x
		var out_x:  float = pw - 18.0

		var net_h:  float = 80.0               # usable vertical space

		# ── Input: 8 time-step dots ───────────────────────────────────────────
		for t in n_steps:
			var filled: bool  = buffer.size() > t
			var alpha:  float = 0.18 + 0.82 * (float(t) / float(n_steps - 1))
			var col: Color
			if filled:
				col = Color(0.3, 0.75, 1.0, alpha)
			else:
				col = Color(0.25, 0.25, 0.35, alpha * 0.5)
			var dot_y: float = y0 + 5.0 + t * (net_h / (n_steps - 1))
			draw_circle(Vector2(inp_x, dot_y), 4.0, col)

		# Arrow line: input cluster → transformer
		var mid_inp_y: float = y0 + 5.0 + (n_steps - 1) * 0.5 * (net_h / (n_steps - 1))
		var tf_left: float   = tf_cx - 28.0
		var tf_top:  float   = y0 + net_h * 0.15
		var tf_bot:  float   = y0 + net_h * 0.85
		var tf_mid_y: float  = (tf_top + tf_bot) * 0.5
		draw_line(Vector2(inp_x + 5, mid_inp_y),
				Vector2(tf_left, tf_mid_y),
				Color(0.28, 0.55, 1.0, 0.35), 1.0)

		# ── Transformer box ───────────────────────────────────────────────────
		var tf_w: float  = 56.0
		var tf_h: float  = tf_bot - tf_top
		draw_rect(Rect2(tf_left, tf_top, tf_w, tf_h), Color(0.14, 0.22, 0.42, 0.65))
		draw_rect(Rect2(tf_left, tf_top, tf_w, tf_h), Color(0.28, 0.55, 1.0, 0.5), false, 1.0)
		draw_string(font, Vector2(tf_left + 4, tf_top + 16),
				"Transformer", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0.65, 0.82, 1.0))
		draw_string(font, Vector2(tf_left + 10, tf_top + 30),
				"2 layers", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0.45, 0.65, 0.9))
		draw_string(font, Vector2(tf_left + 10, tf_top + 44),
				"4 heads", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0.45, 0.65, 0.9))

		var tf_right: float = tf_left + tf_w

		# ── Output nodes + connection lines ───────────────────────────────────
		for i in n_actions:
			var action: String = viz.ACTIONS[i]
			var w: float       = weights.get(action, 0.0)
			var node_y: float  = y0 + 5.0 + i * (net_h / float(n_actions - 1))

			# Connection from transformer box right edge
			var line_alpha: float = clampf(0.08 + w * 0.75, 0.08, 0.83)
			var line_col: Color
			if action == best:
				line_col = Color(0.3, 1.0, 0.45, line_alpha + 0.15)
			else:
				line_col = Color(0.28, 0.55, 1.0, line_alpha)
			draw_line(Vector2(tf_right, tf_mid_y),
					Vector2(out_x - 4, node_y),
					line_col, 1.0)

			# Output node circle
			var radius: float = 3.0 + w * 7.0
			var node_col: Color
			if action == best:
				node_col = Color(0.3, 1.0, 0.45, 0.92)
			else:
				node_col = Color(0.3 + w * 0.55, 0.45 + w * 0.45, 0.9, 0.3 + w * 0.65)
			draw_circle(Vector2(out_x, node_y), radius, node_col)

	# ── Bar chart section ─────────────────────────────────────────────────────

	func _draw_bars(y0: float, pw: float, weights: Dictionary,
			best: String, font: Font) -> void:

		var label_w:  float = 68.0
		var pct_w:    float = 28.0
		var bar_x:    float = label_w + 4.0
		var bar_max:  float = pw - bar_x - pct_w - 6.0
		var row_h:    float = 16.0

		for i in viz.ACTIONS.size():
			var action: String = viz.ACTIONS[i]
			var w: float       = weights.get(action, 0.0)
			var ry: float      = y0 + i * row_h
			var is_best: bool  = action == best

			var text_col: Color = Color(0.35, 1.0, 0.5) if is_best else Color(0.68, 0.68, 0.72)
			var short: String   = viz.ACTION_SHORT.get(action, action)
			draw_string(font, Vector2(6, ry + 11), short,
					HORIZONTAL_ALIGNMENT_LEFT, label_w - 2, 10, text_col)

			# Bar background
			draw_rect(Rect2(bar_x, ry + 3, bar_max, 10),
					Color(0.12, 0.14, 0.22, 0.6))
			# Bar fill
			if w > 0.001:
				var bar_col: Color
				if is_best:
					bar_col = Color(0.28, 0.92, 0.48, 0.88)
				else:
					bar_col = Color(0.25, 0.48, 0.88, 0.68)
				draw_rect(Rect2(bar_x, ry + 3, bar_max * w, 10), bar_col)

			# Percentage text
			var pct_str: String = "%d%%" % int(w * 100.0 + 0.5)
			draw_string(font, Vector2(bar_x + bar_max + 4, ry + 11), pct_str,
					HORIZONTAL_ALIGNMENT_LEFT, pct_w, 10, text_col)

	# ── Helper ────────────────────────────────────────────────────────────────

	func _separator(y: float, pw: float) -> void:
		draw_line(Vector2(6, y), Vector2(pw - 6, y), Color(0.28, 0.55, 1.0, 0.28), 1.0)
