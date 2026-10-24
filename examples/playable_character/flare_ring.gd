class_name FlareRing
extends Node2D
## One-shot expanding light ring for the flare burst; frees itself when done.

var _t := 0.0
const DURATION := 0.45


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()
	if _t >= DURATION:
		queue_free()


func _draw() -> void:
	var k := clampf(_t / DURATION, 0.0, 1.0)
	var radius := 20.0 + 250.0 * (1.0 - pow(1.0 - k, 2.2))
	var alpha := (1.0 - k) * 0.55
	draw_arc(Vector2.ZERO, radius, 0, TAU, 48, Color(1.0, 0.84, 0.5, alpha), 5.0 + 5.0 * (1.0 - k), true)
	draw_circle(Vector2.ZERO, radius * (1.0 - k) * 0.25 + 12.0, Color(1.0, 0.9, 0.6, (1.0 - k) * 0.3))
