@tool
class_name WebUICssCatalog
extends RefCounted
## What the visual editor knows about CSS: the properties it can edit, how each one is shown, which
## declarations in a stylesheet count as setting it (shorthands!), and which sections and properties
## suit the kind of element that is selected. Pure data and functions, no editor or page access.

## How a property is edited. Kinds: length, number, color, enum, text, font, sides (four values in one row).
## Fields: label, kind, and optionally
##   write   the CSS property that gets written (default: the key); e.g. border-color writes all four sides
##   read    the longhand whose computed value is shown (default: the key)
##   detect  longhands that count as "this property is declared" (default: the key)
##   options enum choices; hint: placeholder text for the field
const SPECS := {
	# typography
	"font-family": {"label": "Font", "kind": "font"},
	"font-size": {"label": "Size", "kind": "length", "hint": "16px"},
	"font-weight": {"label": "Weight", "kind": "enum", "options": ["normal", "bold", "100", "200", "300", "400", "500", "600", "700", "800", "900"]},
	"font-style": {"label": "Style", "kind": "enum", "options": ["normal", "italic", "oblique"]},
	"line-height": {"label": "Line height", "kind": "length", "hint": "1.4 or 22px"},
	"letter-spacing": {"label": "Letter spacing", "kind": "length", "hint": "0.04em"},
	"text-align": {"label": "Align", "kind": "enum", "options": ["left", "center", "right", "justify", "start", "end"]},
	"text-decoration-line": {"label": "Decoration", "kind": "enum", "options": ["none", "underline", "line-through", "overline"]},
	"text-transform": {"label": "Case", "kind": "enum", "options": ["none", "uppercase", "lowercase", "capitalize"]},
	"white-space": {"label": "Wrapping", "kind": "enum", "options": ["normal", "nowrap", "pre", "pre-wrap", "pre-line", "break-spaces"]},
	"overflow-wrap": {"label": "Break words", "kind": "enum", "options": ["normal", "break-word", "anywhere"]},
	"text-overflow": {"label": "Text overflow", "kind": "enum", "options": ["clip", "ellipsis"]},
	"color": {"label": "Text color", "kind": "color"},
	"text-shadow": {"label": "Text shadow", "kind": "text", "hint": "0 2px 8px #0008"},
	# size
	"width": {"label": "Width", "kind": "length", "hint": "auto, 200px, 50%"},
	"height": {"label": "Height", "kind": "length", "hint": "auto, 120px"},
	"min-width": {"label": "Min width", "kind": "length"},
	"min-height": {"label": "Min height", "kind": "length"},
	"max-width": {"label": "Max width", "kind": "length", "hint": "none"},
	"max-height": {"label": "Max height", "kind": "length", "hint": "none"},
	"aspect-ratio": {"label": "Aspect ratio", "kind": "text", "hint": "auto, 16 / 9"},
	"box-sizing": {"label": "Box sizing", "kind": "enum", "options": ["content-box", "border-box"]},
	# spacing
	"margin": {"label": "Margin", "kind": "sides", "sides": ["margin-top", "margin-right", "margin-bottom", "margin-left"]},
	"padding": {"label": "Padding", "kind": "sides", "sides": ["padding-top", "padding-right", "padding-bottom", "padding-left"]},
	"margin-top": {"label": "Margin top", "kind": "length"},
	"margin-right": {"label": "Margin right", "kind": "length"},
	"margin-bottom": {"label": "Margin bottom", "kind": "length"},
	"margin-left": {"label": "Margin left", "kind": "length"},
	"padding-top": {"label": "Padding top", "kind": "length"},
	"padding-right": {"label": "Padding right", "kind": "length"},
	"padding-bottom": {"label": "Padding bottom", "kind": "length"},
	"padding-left": {"label": "Padding left", "kind": "length"},
	# background
	"background-color": {"label": "Color", "kind": "color"},
	"background-image": {"label": "Image / gradient", "kind": "text", "hint": "linear-gradient(...) or url(...)"},
	"background-size": {"label": "Size", "kind": "text", "hint": "cover, contain, 50%"},
	"background-position": {"label": "Position", "kind": "text", "hint": "center"},
	"background-repeat": {"label": "Repeat", "kind": "enum", "options": ["repeat", "no-repeat", "repeat-x", "repeat-y", "space", "round"]},
	# border
	"border-width": {"label": "Width", "kind": "length", "read": "border-top-width", "detect": ["border-top-width", "border-right-width", "border-bottom-width", "border-left-width"]},
	"border-style": {"label": "Style", "kind": "enum", "read": "border-top-style", "detect": ["border-top-style", "border-right-style", "border-bottom-style", "border-left-style"], "options": ["none", "solid", "dashed", "dotted", "double", "groove", "ridge"]},
	"border-color": {"label": "Color", "kind": "color", "read": "border-top-color", "detect": ["border-top-color", "border-right-color", "border-bottom-color", "border-left-color"]},
	"border-radius": {"label": "Radius", "kind": "length", "read": "border-top-left-radius", "detect": ["border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius"], "hint": "12px, 50%"},
	"outline": {"label": "Outline", "kind": "text", "read": "outline-style", "detect": ["outline-width", "outline-style", "outline-color"], "hint": "2px solid #fff"},
	# effects
	"opacity": {"label": "Opacity", "kind": "number", "hint": "0 - 1"},
	"box-shadow": {"label": "Shadow", "kind": "text", "hint": "0 8px 24px #0006"},
	"filter": {"label": "Filter", "kind": "text", "hint": "blur(4px), brightness(1.2)"},
	"transform": {"label": "Transform", "kind": "text", "hint": "scale(1.05) rotate(3deg)"},
	"transition": {"label": "Transition", "kind": "text", "read": "transition-duration", "detect": ["transition-property", "transition-duration", "transition-timing-function", "transition-delay"], "hint": "all 0.2s ease"},
	"mix-blend-mode": {"label": "Blend", "kind": "enum", "options": ["normal", "multiply", "screen", "overlay", "lighten", "darken", "color-dodge", "soft-light", "difference"]},
	# layout
	"display": {"label": "Display", "kind": "enum", "options": ["block", "flex", "grid", "inline", "inline-block", "inline-flex", "inline-grid", "none", "contents"]},
	"position": {"label": "Position", "kind": "enum", "options": ["static", "relative", "absolute", "fixed", "sticky"]},
	"top": {"label": "Top", "kind": "length"},
	"right": {"label": "Right", "kind": "length"},
	"bottom": {"label": "Bottom", "kind": "length"},
	"left": {"label": "Left", "kind": "length"},
	"z-index": {"label": "Z index", "kind": "number"},
	"overflow": {"label": "Overflow", "kind": "enum", "read": "overflow-x", "detect": ["overflow-x", "overflow-y"], "options": ["visible", "hidden", "scroll", "auto", "clip"]},
	"visibility": {"label": "Visibility", "kind": "enum", "options": ["visible", "hidden", "collapse"]},
	"flex-direction": {"label": "Direction", "kind": "enum", "options": ["row", "row-reverse", "column", "column-reverse"]},
	"flex-wrap": {"label": "Wrap", "kind": "enum", "options": ["nowrap", "wrap", "wrap-reverse"]},
	"justify-content": {"label": "Justify", "kind": "enum", "options": ["normal", "flex-start", "center", "flex-end", "space-between", "space-around", "space-evenly", "start", "end"]},
	"align-items": {"label": "Align items", "kind": "enum", "options": ["normal", "stretch", "flex-start", "center", "flex-end", "baseline", "start", "end"]},
	"align-content": {"label": "Align content", "kind": "enum", "options": ["normal", "flex-start", "center", "flex-end", "space-between", "space-around", "stretch"]},
	"gap": {"label": "Gap", "kind": "length", "read": "column-gap", "detect": ["row-gap", "column-gap"], "hint": "12px"},
	"grid-template-columns": {"label": "Columns", "kind": "text", "hint": "repeat(3, 1fr)"},
	"grid-template-rows": {"label": "Rows", "kind": "text", "hint": "auto"},
	"grid-auto-flow": {"label": "Auto flow", "kind": "enum", "options": ["row", "column", "dense", "row dense", "column dense"]},
	"justify-items": {"label": "Justify items", "kind": "enum", "options": ["normal", "stretch", "start", "center", "end"]},
	"place-items": {"label": "Place items", "kind": "text", "read": "align-items", "detect": ["align-items", "justify-items"]},
	# flex / grid items
	"flex-grow": {"label": "Grow", "kind": "number"},
	"flex-shrink": {"label": "Shrink", "kind": "number"},
	"flex-basis": {"label": "Basis", "kind": "length", "hint": "auto, 120px"},
	"align-self": {"label": "Align self", "kind": "enum", "options": ["auto", "stretch", "flex-start", "center", "flex-end", "baseline", "start", "end"]},
	"justify-self": {"label": "Justify self", "kind": "enum", "options": ["auto", "stretch", "start", "center", "end"]},
	"order": {"label": "Order", "kind": "number"},
	"grid-column": {"label": "Column", "kind": "text", "read": "grid-column-start", "detect": ["grid-column-start", "grid-column-end"], "hint": "1 / 3"},
	"grid-row": {"label": "Row", "kind": "text", "read": "grid-row-start", "detect": ["grid-row-start", "grid-row-end"], "hint": "1 / 2"},
	# interaction
	"cursor": {"label": "Cursor", "kind": "enum", "options": ["auto", "default", "pointer", "text", "move", "not-allowed", "grab", "crosshair", "wait", "help"]},
	"pointer-events": {"label": "Pointer events", "kind": "enum", "options": ["auto", "none"]},
	"user-select": {"label": "Text selection", "kind": "enum", "options": ["auto", "none", "text", "all"]},
	# images and svg
	"object-fit": {"label": "Fit", "kind": "enum", "options": ["fill", "contain", "cover", "none", "scale-down"]},
	"object-position": {"label": "Position", "kind": "text", "hint": "center, 50% 20%"},
	"fill": {"label": "Fill", "kind": "color"},
	"stroke": {"label": "Stroke", "kind": "color"},
	"stroke-width": {"label": "Stroke width", "kind": "length"},
}

## Longhand -> the shorthands that also set it. A rule declaring `padding` sets padding-top.
const SHORTHANDS_OF := {
	"margin-top": ["margin"], "margin-right": ["margin"], "margin-bottom": ["margin"], "margin-left": ["margin"],
	"padding-top": ["padding"], "padding-right": ["padding"], "padding-bottom": ["padding"], "padding-left": ["padding"],
	"font-family": ["font"], "font-size": ["font"], "font-weight": ["font"], "font-style": ["font"], "line-height": ["font"],
	"background-color": ["background"], "background-image": ["background"], "background-size": ["background"],
	"background-position": ["background"], "background-repeat": ["background"],
	"border-top-width": ["border", "border-width", "border-top"], "border-right-width": ["border", "border-width", "border-right"],
	"border-bottom-width": ["border", "border-width", "border-bottom"], "border-left-width": ["border", "border-width", "border-left"],
	"border-top-style": ["border", "border-style", "border-top"], "border-right-style": ["border", "border-style", "border-right"],
	"border-bottom-style": ["border", "border-style", "border-bottom"], "border-left-style": ["border", "border-style", "border-left"],
	"border-top-color": ["border", "border-color", "border-top"], "border-right-color": ["border", "border-color", "border-right"],
	"border-bottom-color": ["border", "border-color", "border-bottom"], "border-left-color": ["border", "border-color", "border-left"],
	"border-top-left-radius": ["border-radius"], "border-top-right-radius": ["border-radius"],
	"border-bottom-right-radius": ["border-radius"], "border-bottom-left-radius": ["border-radius"],
	"outline-width": ["outline"], "outline-style": ["outline"], "outline-color": ["outline"],
	"overflow-x": ["overflow"], "overflow-y": ["overflow"],
	"row-gap": ["gap", "grid-gap"], "column-gap": ["gap", "grid-gap"],
	"align-items": ["place-items"], "justify-items": ["place-items"],
	"flex-grow": ["flex"], "flex-shrink": ["flex"], "flex-basis": ["flex"],
	"flex-direction": ["flex-flow"], "flex-wrap": ["flex-flow"],
	"top": ["inset"], "right": ["inset"], "bottom": ["inset"], "left": ["inset"],
	"text-decoration-line": ["text-decoration"],
	"grid-column-start": ["grid-column", "grid-area"], "grid-column-end": ["grid-column", "grid-area"],
	"grid-row-start": ["grid-row", "grid-area"], "grid-row-end": ["grid-row", "grid-area"],
	"transition-property": ["transition"], "transition-duration": ["transition"],
	"transition-timing-function": ["transition"], "transition-delay": ["transition"],
}

## Properties a child inherits from its parent (so an element can show a value that is set on an ancestor).
const INHERITED := [
	"color", "font-family", "font-size", "font-weight", "font-style", "line-height", "letter-spacing", "text-align",
	"text-transform", "white-space", "overflow-wrap", "text-shadow", "cursor", "visibility", "fill", "stroke", "stroke-width",
]

const TYPOGRAPHY := ["font-family", "font-size", "font-weight", "font-style", "line-height", "letter-spacing", "text-align", "text-decoration-line", "text-transform", "white-space", "overflow-wrap", "text-overflow"]
const SIZE := ["width", "height", "min-width", "min-height", "max-width", "max-height", "aspect-ratio", "box-sizing"]
const BACKGROUND := ["background-color", "background-image", "background-size", "background-position", "background-repeat"]
const BORDER := ["border-width", "border-style", "border-color", "border-radius", "outline"]
const INTERACTION := ["cursor", "pointer-events", "user-select"]

## Text content may be edited for these (checked per element: see content_state in the model).
const EDITABLE_ATTRIBUTES := ["alt", "title", "placeholder", "value", "aria-label"]
## Attributes shown read-only when present.
const SHOWN_ATTRIBUTES := ["src", "href", "alt", "title", "placeholder", "value", "type", "name", "for", "role", "aria-label", "target"]


## Every property key the page should report values for (including the longhands behind each key).
static func property_config() -> Dictionary:
	var out := {}
	for key: String in SPECS:
		var spec: Dictionary = SPECS[key]
		if spec.kind == "sides":
			continue
		out[key] = {"read": spec.get("read", key), "detect": spec.get("detect", [key]), "write": spec.get("write", key), "inherited": key in INHERITED}
	return out


static func spec(prop: String) -> Dictionary:
	return SPECS.get(prop, {})


static func write_name(prop: String) -> String:
	return SPECS.get(prop, {}).get("write", prop)


static func read_name(prop: String) -> String:
	return SPECS.get(prop, {}).get("read", prop)


## Names that, when declared in a rule, set `prop`: its own longhands and every shorthand covering them.
static func covers(prop: String) -> PackedStringArray:
	var names := PackedStringArray()
	var spec_data: Dictionary = SPECS.get(prop, {})
	var longhands: Array = spec_data.get("detect", [prop])
	for longhand: String in longhands:
		if not names.has(longhand):
			names.append(longhand)
		for shorthand: String in SHORTHANDS_OF.get(longhand, []):
			if not names.has(shorthand):
				names.append(shorthand)
	var write: String = spec_data.get("write", prop)
	if not names.has(write):
		names.append(write)
	for shorthand: String in SHORTHANDS_OF.get(write, []):
		if not names.has(shorthand):
			names.append(shorthand)
	if not names.has("all"):
		names.append("all")
	return names


## True when a declaration named `name` in a rule sets `prop`.
static func declaration_sets(name: String, prop: String) -> bool:
	return covers(prop).has(name)


## True when `name` is a shorthand (so writing a longhand next to it overrides part of it).
static func is_shorthand_for(name: String, prop: String) -> bool:
	var spec_data: Dictionary = SPECS.get(prop, {})
	var own: Array = spec_data.get("detect", [prop])
	own = own + [spec_data.get("write", prop)]
	return name != prop and name not in own


## The expanded properties of a "sides" key, or [prop] for an ordinary one.
static func expand(prop: String) -> Array:
	var spec_data: Dictionary = SPECS.get(prop, {})
	return spec_data.get("sides", [prop])


# ---------------------------------------------------------------- what to show for which element

## The sections for a selected element: [{"id", "title", "props": Array, "collapsed": bool, "note": String}].
## `selection` is what edit_mode.js reports (kind, display, position, parent_display, attrs, ...).
static func sections_for(selection: Dictionary) -> Array:
	var kind: String = selection.get("kind", "other")
	var display: String = str(selection.get("display", ""))
	var position: String = str(selection.get("position", "static"))
	var parent_display: String = str(selection.get("parent_display", ""))
	var is_flex := display.ends_with("flex")
	var is_grid := display.ends_with("grid")
	var sections: Array = []

	var layout: Array = ["display"]
	if is_flex:
		layout.append_array(["flex-direction", "flex-wrap", "justify-content", "align-items", "align-content", "gap"])
	elif is_grid:
		layout.append_array(["grid-template-columns", "grid-template-rows", "grid-auto-flow", "justify-items", "align-items", "justify-content", "gap"])
	layout.append("position")
	if position != "static":
		layout.append_array(["top", "right", "bottom", "left"])
	layout.append_array(["z-index", "overflow", "visibility"])

	var item: Array = []
	if parent_display.ends_with("flex"):
		item = ["flex-grow", "flex-shrink", "flex-basis", "align-self", "order"]
	elif parent_display.ends_with("grid"):
		item = ["grid-column", "grid-row", "justify-self", "align-self"]

	match kind:
		"text":
			sections.append(_section("content", "Content", [], false))
			sections.append(_section("typography", "Typography", ["color"] + TYPOGRAPHY, false))
			sections.append(_section("spacing", "Spacing", ["margin", "padding"], false))
			sections.append(_section("size", "Size", SIZE, true))
			sections.append(_section("background", "Background", BACKGROUND, true))
			sections.append(_section("border", "Border", BORDER, true))
			sections.append(_section("effects", "Effects", ["opacity", "text-shadow", "box-shadow", "filter", "transform", "transition"], true))
			sections.append(_section("layout", "Layout", layout, true))
		"container":
			sections.append(_section("layout", "Layout", layout, false))
			sections.append(_section("size", "Size", SIZE, false))
			sections.append(_section("spacing", "Spacing", ["margin", "padding"], false))
			sections.append(_section("background", "Background", BACKGROUND, false))
			sections.append(_section("border", "Border", BORDER, false))
			sections.append(_section("effects", "Effects", ["opacity", "box-shadow", "filter", "transform", "transition", "mix-blend-mode"], true))
			sections.append(_section("typography", "Typography", ["color"] + TYPOGRAPHY, true, "Inherited by the elements inside."))
		"button", "link", "input":
			sections.append(_section("content", "Content", [], false))
			sections.append(_section("colors", "Colors", ["color", "background-color"], false))
			sections.append(_section("typography", "Typography", TYPOGRAPHY, false))
			sections.append(_section("size", "Size", SIZE, false))
			sections.append(_section("spacing", "Spacing", ["margin", "padding"], false))
			sections.append(_section("border", "Border", BORDER, false))
			sections.append(_section("interaction", "Interaction", INTERACTION, false))
			sections.append(_section("background", "Background", ["background-image", "background-size", "background-position", "background-repeat"], true))
			sections.append(_section("effects", "Effects", ["opacity", "box-shadow", "filter", "transform", "transition"], true))
			sections.append(_section("layout", "Layout", layout, true))
		"image", "media":
			sections.append(_section("content", "Content", [], false))
			sections.append(_section("size", "Size", SIZE, false))
			sections.append(_section("image", "Image", ["object-fit", "object-position"], false))
			sections.append(_section("spacing", "Spacing", ["margin", "padding"], false))
			sections.append(_section("border", "Border", BORDER, false))
			sections.append(_section("effects", "Effects", ["opacity", "box-shadow", "filter", "transform", "mix-blend-mode"], false))
			sections.append(_section("layout", "Layout", layout, true))
		"svg":
			sections.append(_section("appearance", "Appearance", ["fill", "stroke", "stroke-width", "color", "opacity"], false))
			sections.append(_section("size", "Size", SIZE, false))
			sections.append(_section("spacing", "Spacing", ["margin", "padding"], true))
			sections.append(_section("effects", "Effects", ["filter", "transform", "transition", "mix-blend-mode"], true))
			sections.append(_section("layout", "Layout", layout, true))
		_:
			sections.append(_section("layout", "Layout", layout, false))
			sections.append(_section("size", "Size", SIZE, false))
			sections.append(_section("spacing", "Spacing", ["margin", "padding"], false))
			sections.append(_section("typography", "Typography", ["color"] + TYPOGRAPHY, true))
			sections.append(_section("background", "Background", BACKGROUND, true))
			sections.append(_section("border", "Border", BORDER, true))
			sections.append(_section("effects", "Effects", ["opacity", "box-shadow", "filter", "transform", "transition"], true))
	if not item.is_empty():
		sections.insert(mini(1, sections.size()), _section("item", "Flex item" if parent_display.ends_with("flex") else "Grid item", item, kind in ["text", "button", "link", "image", "svg"], "Controls how this element sits inside its parent."))
	return sections


## Every property key that sections_for() can show, for asking the page about all of them.
static func all_keys() -> PackedStringArray:
	var keys := PackedStringArray()
	for key: String in SPECS:
		if SPECS[key].kind != "sides":
			keys.append(key)
	return keys


static func _section(id: String, title: String, props: Array, collapsed: bool, note := "") -> Dictionary:
	return {"id": id, "title": title, "props": props, "collapsed": collapsed, "note": note}
