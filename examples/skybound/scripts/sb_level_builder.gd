@tool
class_name SBLevelBuilder
extends Node3D
## Lays out the Skybound course from the table below. Tick `rebuild` in the Inspector (or call build())
## in the editor and the sections S1..S5 are regenerated as real, saved nodes: after that every platform,
## shard and checkpoint can be moved or resized by hand like any other node.
##
## Each row is [kind, width, depth, gap, dy, dx, options]:
##   kind    "plat" | "move" | "crumble"
##   gap     metres from the previous platform's front edge to this one's near edge, along the heading
##   dy      this top surface relative to the previous one;  dx  sideways offset of the centre (right > 0)
##   options shards [Vector3(right, up, forward)], cp (section index), wings, bounce (strength, bounce_at offset),
##           goal, travel Vector3(right, up, forward), period, turn (degrees after this platform,
##           left > 0, platform should be square), h (thickness)

const PLATFORM := preload("res://examples/skybound/scenes/platform.tscn")
const MOVING := preload("res://examples/skybound/scenes/moving_platform.tscn")
const CRUMBLE := preload("res://examples/skybound/scenes/crumble_platform.tscn")
const CHECKPOINT := preload("res://examples/skybound/scenes/checkpoint.tscn")
const SHARD := preload("res://examples/skybound/scenes/shard.tscn")
const WINGS := preload("res://examples/skybound/scenes/wings.tscn")
const GOAL := preload("res://examples/skybound/scenes/goal.tscn")
const BOUNCE := preload("res://examples/skybound/scenes/bounce_pad.tscn")

const UP := Vector3.UP
const SHARD_HOVER := Vector3(0.0, 1.35, 0.0)

const SECTIONS := [
	# ---- 1 LAUNCH PAD: runs and long jumps, no tricks
	[
		["plat", 14, 14, 0.0, 0.0, 0.0, {"cp": 0, "shards": [Vector3(0, 1.35, -3)]}],
		["plat", 8, 6, 4.5, 0.0, 0.0, {"shards": [SHARD_HOVER]}],
		["plat", 6, 6, 4.5, 0.5, 2.5, {}],
		["plat", 6, 6, 4.5, 0.5, -2.5, {"shards": [SHARD_HOVER]}],
		["plat", 4, 4, 4.5, 0.8, 2.5, {}],
		["plat", 6, 6, 4.5, -0.5, -2.5, {"shards": [SHARD_HOVER]}],
		["plat", 3, 3, 4.5, 0.0, 2.0, {}],
		["plat", 10, 10, 4.5, 1.0, 0.0, {"turn": -90, "shards": [SHARD_HOVER]}],
	],
	# ---- 2 FLOATING ISLES: smaller islands and a spring pad
	[
		["plat", 14, 12, 4.5, 0.5, 0.0, {"cp": 1}],
		["plat", 5, 5, 4.5, 0.8, -3.0, {"shards": [SHARD_HOVER]}],
		["plat", 4, 4, 4.5, 0.8, 3.0, {}],
		["plat", 6, 6, 4.5, 0.0, -3.0, {"bounce": 21.0, "bounce_at": Vector3(0, 0, 1.4)}],
		["plat", 6, 6, 3.0, 7.0, 3.0, {"shards": [SHARD_HOVER]}],
		["plat", 3, 3, 4.5, 0.0, -2.5, {"shards": [SHARD_HOVER]}],
		["plat", 3, 3, 4.5, 0.0, 2.5, {}],
		["plat", 4, 4, 4.5, 0.5, 0.0, {"shards": [SHARD_HOVER]}],
		["plat", 14, 14, 4.5, 0.5, 0.0, {"cp": 2, "wings": true, "turn": 90, "shards": [Vector3(4, 1.35, 0)]}],
	],
	# ---- 3 CARGO RUN: the Wing Orb (double jump), moving and crumbling platforms
	[
		["plat", 5, 5, 4.5, 0.0, 0.0, {}],
		["move", 5, 5, 7.0, 0.0, 0.0, {"travel": Vector3(0, 0, 6), "period": 5.0}],
		["plat", 7, 7, 4.5, 0.0, 0.0, {"shards": [SHARD_HOVER]}],
		["crumble", 3.5, 3.5, 4.0, 0.0, 2.0, {"shards": [SHARD_HOVER]}],
		["crumble", 3.5, 3.5, 4.0, 0.0, -2.0, {}],
		["crumble", 3.5, 3.5, 4.0, 0.0, 2.0, {"shards": [SHARD_HOVER]}],
		["crumble", 3.5, 3.5, 4.0, 0.5, -2.0, {}],
		["plat", 8, 8, 4.0, 0.0, 0.0, {"shards": [SHARD_HOVER]}],
		["move", 5, 5, 5.5, 0.0, 0.0, {"travel": Vector3(0, 6, 0), "period": 6.0}],
		["plat", 7, 7, 4.5, 3.0, 0.0, {}],
	],
	# ---- 4 SKYLINE TOWERS: climbing
	[
		["plat", 14, 14, 4.5, 2.5, 0.0, {"cp": 3}],
		["plat", 4, 4, 4.5, 2.5, 0.0, {"shards": [SHARD_HOVER]}],
		["plat", 4, 4, 4.5, 2.5, 3.0, {}],
		["plat", 4, 4, 4.5, 2.5, -3.0, {"shards": [SHARD_HOVER]}],
		["plat", 3, 3, 4.5, 2.5, 3.0, {}],
		["plat", 3, 3, 4.5, 2.5, -3.0, {"shards": [SHARD_HOVER]}],
		["plat", 2, 10, 4.5, 0.0, 0.0, {"shards": [Vector3(0, 1.35, -2)]}],
		["move", 4, 4, 5.5, 0.0, 0.0, {"travel": Vector3(7, 0, 0), "period": 4.5}],
		["plat", 4, 4, 5.0, 2.5, 0.0, {}],
		["plat", 4, 4, 5.0, 2.5, 0.0, {"shards": [SHARD_HOVER]}],
	],
	# ---- 5 THE SPIRE: the gauntlet
	[
		["plat", 12, 12, 4.5, 1.5, 0.0, {"cp": 4, "turn": 90}],
		["plat", 3, 3, 5.0, 0.0, 2.0, {}],
		["crumble", 3, 3, 4.5, 0.5, -2.0, {"shards": [SHARD_HOVER]}],
		["move", 3, 3, 6.5, 0.0, 0.0, {"travel": Vector3(6, 0, 0), "period": 4.0}],
		["plat", 2.5, 2.5, 5.5, 0.0, 0.0, {"shards": [SHARD_HOVER]}],
		["crumble", 3, 3, 4.5, 0.5, 3.0, {}],
		["crumble", 3, 3, 4.5, 0.5, -3.0, {"shards": [SHARD_HOVER]}],
		["plat", 3, 3, 5.0, 1.5, 0.0, {}],
		["plat", 4, 4, 8.0, 1.0, 0.0, {"shards": [SHARD_HOVER]}],
		["plat", 3, 3, 5.5, 2.5, -2.0, {"shards": [SHARD_HOVER]}],
		["plat", 16, 16, 5.5, 2.0, 0.0, {"goal": true, "shards": [Vector3(0, 1.35, 3)]}],
	],
]

@export var rebuild := false:
	set(value):
		if value and Engine.is_editor_hint() and is_inside_tree():
			build()
		rebuild = false
@export_multiline var info := ""


func build() -> void:
	var scene_root := get_tree().edited_scene_root
	for child in get_children():
		child.free()
	var top := Vector3.ZERO  # top-surface centre of the previous platform
	var prev_half := 0.0     # half its extent along the current heading
	var yaw := 0.0
	var platforms := 0
	var shards := 0
	for section in SECTIONS.size():
		var holder := Node3D.new()
		holder.name = "S%d" % (section + 1)
		add_child(holder)
		holder.owner = scene_root
		for index in SECTIONS[section].size():
			var row: Array = SECTIONS[section][index]
			var kind: String = row[0]
			var width: float = row[1]
			var depth: float = row[2]
			var gap: float = row[3]
			var rise: float = row[4]
			var sway: float = row[5]
			var opts: Dictionary = row[6]
			var thick: float = opts.get("h", 1.0)
			var heading := Vector3(0, 0, -1).rotated(UP, yaw)
			var right := Vector3(1, 0, 0).rotated(UP, yaw)
			var centre := top + heading * (prev_half + gap + depth * 0.5) + right * sway + UP * rise
			if platforms == 0:
				centre = Vector3.ZERO
			var scene: PackedScene = PLATFORM
			if kind == "move":
				scene = MOVING
			elif kind == "crumble":
				scene = CRUMBLE
			var node := scene.instantiate() as Node3D
			node.name = "P%02d" % (index + 1)
			node.set("size", Vector3(width, thick, depth))
			node.set("theme", section)
			if kind == "move":
				var t: Vector3 = opts.get("travel", Vector3(0, 0, 6))
				node.set("travel", Vector3(t.x, t.y, -t.z))
				node.set("period", float(opts.get("period", 5.0)))
			holder.add_child(node)
			node.owner = scene_root
			node.position = centre - UP * thick * 0.5
			node.rotation.y = yaw
			platforms += 1
			var local := func(offset: Vector3) -> Vector3:
				return centre + right * offset.x + UP * offset.y + heading * offset.z
			if opts.has("cp"):
				var cp := CHECKPOINT.instantiate() as Node3D
				cp.name = "Checkpoint%d" % int(opts["cp"])
				cp.set("index", int(opts["cp"]))
				cp.set("section_name", SBBuild.SECTION_NAMES[int(opts["cp"])])
				cp.set("theme", int(opts["cp"]))
				holder.add_child(cp)
				cp.owner = scene_root
				cp.position = centre
				cp.rotation.y = yaw
			if opts.get("wings", false):
				var orb := WINGS.instantiate() as Node3D
				orb.name = "WingOrb"
				holder.add_child(orb)
				orb.owner = scene_root
				orb.position = local.call(Vector3(-3.5, 1.7, 0.0))
			if opts.has("bounce"):
				var pad := BOUNCE.instantiate() as Node3D
				pad.name = "Bounce%02d" % (index + 1)
				pad.set("strength", float(opts["bounce"]))
				holder.add_child(pad)
				pad.owner = scene_root
				pad.position = local.call(opts.get("bounce_at", Vector3.ZERO))
			if opts.get("goal", false):
				var goal := GOAL.instantiate() as Node3D
				goal.name = "Goal"
				holder.add_child(goal)
				goal.owner = scene_root
				goal.position = local.call(Vector3(0, 0, -2))
			for offset: Vector3 in opts.get("shards", []):
				var shard := SHARD.instantiate() as Node3D
				shard.name = "Shard%02d" % (shards + 1)
				holder.add_child(shard)
				shard.owner = scene_root
				shard.position = local.call(offset)
				shards += 1
			top = centre
			prev_half = depth * 0.5
			if opts.has("turn"):
				yaw += deg_to_rad(float(opts["turn"]))
				prev_half = width * 0.5  # turn platforms are square
	info = "%d platforms, %d shards, %d sections" % [platforms, shards, SECTIONS.size()]

