class_name GroveGate
extends Area2D
## The level exit: a stone arch placed in the level scene. Dormant until every seed is returned;
## then its light wakes and it lets the player finish the run.

signal entered

var open := false:
	set(value):
		open = value
		if is_inside_tree():
			_glow.visible = value
			set_process(value)

var _pulse := 0.0

@onready var _glow: Sprite2D = $Glow


func _ready() -> void:
	_glow.visible = open
	set_process(open)
	body_entered.connect(func(body: Node2D) -> void:
		if open and body is DemoPlayer and not body.dead:
			entered.emit())


func _process(delta: float) -> void:
	_pulse += delta
	_glow.modulate.a = 0.72 + 0.28 * sin(_pulse * 2.6)
