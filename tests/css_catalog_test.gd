extends SceneTree
## Run: godot --headless --path . -s res://tests/css_catalog_test.gd
## Covers WebUICssCatalog: which declarations count as setting a property (shorthands), and that the
## sections offered depend on the kind of the selected element. Exit code = number of failures.

var failures := 0


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _initialize() -> void:
	_test_covers()
	_test_config()
	_test_sections()
	quit(failures)


func props_of(sections: Array) -> Array:
	var out: Array = []
	for section: Dictionary in sections:
		out.append_array(section.props)
	return out


func ids_of(sections: Array) -> Array:
	return sections.map(func(s: Dictionary) -> String: return s.id)


func section(sections: Array, id: String) -> Dictionary:
	for s: Dictionary in sections:
		if s.id == id:
			return s
	return {}


func _test_covers() -> void:
	check(WebUICssCatalog.declaration_sets("padding", "padding-top"), "`padding` sets padding-top")
	check(WebUICssCatalog.declaration_sets("margin-top", "margin-top") and not WebUICssCatalog.declaration_sets("margin-left", "margin-top"), "a longhand sets only itself")
	check(WebUICssCatalog.declaration_sets("font", "font-size") and WebUICssCatalog.declaration_sets("font", "line-height"), "`font` sets size and line height")
	check(WebUICssCatalog.declaration_sets("background", "background-color"), "`background` sets background-color")
	check(WebUICssCatalog.declaration_sets("border", "border-color") and WebUICssCatalog.declaration_sets("border-top", "border-color") and WebUICssCatalog.declaration_sets("border-left-color", "border-color"), "border shorthands and any side count for border-color")
	check(WebUICssCatalog.declaration_sets("border-radius", "border-radius") and WebUICssCatalog.declaration_sets("border-top-left-radius", "border-radius"), "border-radius and its corners")
	check(WebUICssCatalog.declaration_sets("overflow", "overflow") and WebUICssCatalog.declaration_sets("overflow-y", "overflow"), "overflow and its axes")
	check(WebUICssCatalog.declaration_sets("gap", "gap") and WebUICssCatalog.declaration_sets("column-gap", "gap"), "gap and its axes")
	check(WebUICssCatalog.declaration_sets("all", "color"), "`all` sets everything")
	check(not WebUICssCatalog.declaration_sets("padding", "margin-top"), "unrelated shorthands do not count")
	check(WebUICssCatalog.is_shorthand_for("padding", "padding-top") and not WebUICssCatalog.is_shorthand_for("padding-top", "padding-top"), "shorthand vs exact name")
	check(not WebUICssCatalog.is_shorthand_for("border-color", "border-color"), "the written name of a property is not a shorthand of it")
	check(WebUICssCatalog.write_name("border-color") == "border-color" and WebUICssCatalog.read_name("border-color") == "border-top-color", "border-color is written as a whole and read from one side")


func _test_config() -> void:
	var config := WebUICssCatalog.property_config()
	check(config.has("color") and config["color"].inherited and not config["width"].inherited, "inheritable properties are flagged")
	check(config["gap"].write == "gap" and config["gap"].read == "column-gap", "read/write names reach the page config")
	check(not config.has("margin") and config.has("margin-top"), "sides rows are reported through their four longhands")
	var missing := PackedStringArray()
	for kind in ["text", "container", "button", "link", "input", "image", "media", "svg", "other"]:
		for display in ["block", "flex", "grid"]:
			for key in props_of(WebUICssCatalog.sections_for({"kind": kind, "display": display, "position": "absolute", "parent_display": "flex"})):
				if WebUICssCatalog.spec(key).is_empty():
					missing.append(key)
	check(missing.is_empty(), "every property in every section has a spec: %s" % [missing])
	for key: String in WebUICssCatalog.SPECS:
		var spec: Dictionary = WebUICssCatalog.SPECS[key]
		if spec.kind == "enum" and (not spec.has("options") or spec.options.is_empty()):
			check(false, "enum %s has options" % key)


func _test_sections() -> void:
	var text := WebUICssCatalog.sections_for({"kind": "text", "display": "block", "position": "static", "parent_display": "block"})
	check(ids_of(text).slice(0, 3) == ["content", "typography", "spacing"], "a text element leads with content and typography: %s" % [ids_of(text)])
	check("font-size" in props_of(text) and "letter-spacing" in props_of(text) and "white-space" in props_of(text), "text elements get typography and wrapping")
	check(not ("object-fit" in props_of(text)) and not ("flex-direction" in props_of(text)), "but no image or flex properties")
	check(section(text, "layout").collapsed and not section(text, "typography").collapsed, "layout is secondary for text, typography is open")

	var box := WebUICssCatalog.sections_for({"kind": "container", "display": "flex", "position": "static", "parent_display": "block"})
	check(ids_of(box)[0] == "layout" and "flex-direction" in section(box, "layout").props and "justify-content" in section(box, "layout").props, "a flex container leads with flex layout")
	check(not ("grid-template-columns" in props_of(box)), "a flex container has no grid controls")
	check(section(box, "typography").collapsed and section(box, "typography").note != "", "typography is secondary for a container, with a note")
	var grid := WebUICssCatalog.sections_for({"kind": "container", "display": "grid", "position": "static", "parent_display": "block"})
	check("grid-template-columns" in section(grid, "layout").props and not ("flex-direction" in section(grid, "layout").props), "a grid container gets grid controls instead")
	var inline_flex := WebUICssCatalog.sections_for({"kind": "container", "display": "inline-flex", "position": "static", "parent_display": "block"})
	check("flex-direction" in section(inline_flex, "layout").props, "inline-flex counts as flex")
	var plain := WebUICssCatalog.sections_for({"kind": "container", "display": "block", "position": "static", "parent_display": "block"})
	check(not ("flex-direction" in props_of(plain)) and not ("top" in props_of(plain)), "a plain block shows neither flex nor offsets")
	var positioned := WebUICssCatalog.sections_for({"kind": "container", "display": "block", "position": "absolute", "parent_display": "block"})
	check("top" in props_of(positioned) and "left" in props_of(positioned), "a positioned element shows offsets")

	var image := WebUICssCatalog.sections_for({"kind": "image", "display": "inline", "position": "static", "parent_display": "block"})
	check(ids_of(image).slice(0, 3) == ["content", "size", "image"] and "object-fit" in props_of(image) and "aspect-ratio" in props_of(image), "an image leads with content, size and fit")
	check(not ("font-size" in props_of(image)), "an image has no typography")

	var button := WebUICssCatalog.sections_for({"kind": "button", "display": "flex", "position": "static", "parent_display": "block"})
	check("cursor" in props_of(button) and "pointer-events" in props_of(button) and "color" in section(button, "colors").props and "background-color" in section(button, "colors").props, "a button gets colors and interaction")
	var svg := WebUICssCatalog.sections_for({"kind": "svg", "display": "inline", "position": "static", "parent_display": "block"})
	check("fill" in props_of(svg) and "stroke" in props_of(svg) and not ("font-size" in props_of(svg)), "an SVG gets fill and stroke, no typography")

	var in_flex := WebUICssCatalog.sections_for({"kind": "container", "display": "block", "position": "static", "parent_display": "flex"})
	check(not section(in_flex, "item").is_empty() and "flex-grow" in section(in_flex, "item").props and section(in_flex, "item").title == "Flex item", "a child of a flex container gets flex item controls")
	var in_grid := WebUICssCatalog.sections_for({"kind": "text", "display": "block", "position": "static", "parent_display": "grid"})
	check("grid-column" in section(in_grid, "item").props and section(in_grid, "item").title == "Grid item", "a child of a grid container gets grid item controls")
	check(section(plain, "item").is_empty(), "no item section in a plain block")
