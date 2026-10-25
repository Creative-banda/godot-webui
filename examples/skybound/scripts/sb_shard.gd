@tool
class_name SBShard
extends Area3D
## A light shard to collect. Spins and bobs; bursts when taken.

signal collected(shard: SBShard)

var _gem: MeshInstance3D
var _clock := randf() * TAU
var _taken := false


func _ready() -> void:
	add_to_group("sb_shard")
	if get_node_or_null("Gem") == null:
		var sphere := SphereMesh.new()  # four segments and two rings make a diamond
		sphere.radial_segments = 4
		sphere.rings = 2
		sphere.radius = 0.38
		sphere.height = 0.95
		_gem = SBPieces.add_mesh(self, sphere, SBBuild.glow_material(Color("#7be0ff"), 3.0))
		_gem.name = "Gem"
	else:
		_gem = get_node("Gem")
	if Engine.is_editor_hint():
		return
	var zone := SBPieces.add_box_area(self, Vector3(1.6, 1.8, 1.6), Vector3.ZERO)
	zone.body_entered.connect(_on_body_entered)


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _gem == null or _taken:
		return
	_clock += delta
	_gem.rotation.y += delta * 2.4
	_gem.position.y = sin(_clock * 2.2) * 0.14


func _on_body_entered(body: Node3D) -> void:
	if _taken or not body is SBPlayer:
		return
	_taken = true
	collected.emit(self)
	var burst := create_tween().set_parallel(true)
	burst.tween_property(_gem, "scale", Vector3(2.6, 2.6, 2.6), 0.25).set_ease(Tween.EASE_OUT)
	burst.tween_property(_gem, "transparency", 1.0, 0.25)
	burst.chain().tween_callback(func() -> void: _gem.visible = false)


## Brings the shard back for a new run.
func reset() -> void:
	_taken = false
	if _gem:
		_gem.visible = true
		_gem.scale = Vector3.ONE
		_gem.transparency = 0.0
