extends SceneTree
## Run: godot --headless --path . -s res://tests/css_patcher_test.gd
## Covers WebUICssPatcher: CSSOM-style rule addressing, in-place edits that leave everything else
## byte-identical, refusals, and atomic file patching. Exit code = number of failures.

var failures := 0
const TMP_DIR := "user://css_patcher_test"


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	_test_parse()
	_test_replace()
	_test_append()
	_test_tricky_syntax()
	_test_refusals()
	_test_real_files()
	_test_files()
	quit(failures)


## How many characters of `a` were replaced by how many of `b`: everything before the first and after
## the last difference is identical. (0, n) is a pure insertion.
func edit_span(a: String, b: String) -> Vector2i:
	var p := 0
	var limit := mini(a.length(), b.length())
	while p < limit and a[p] == b[p]:
		p += 1
	var s := 0
	while s < limit - p and a[a.length() - 1 - s] == b[b.length() - 1 - s]:
		s += 1
	return Vector2i(a.length() - p - s, b.length() - p - s)


func _test_parse() -> void:
	var css := "@charset \"utf-8\";\n@import url(x.css);\n/* c */ a, b { color: red }\n@media (max-width: 600px) {\n  .x { top: 1px }\n  .y { top: 2px }\n}\n@keyframes k { from { top: 0 } to { top: 1px } }\n.z { top: 3px }\n"
	var lines := WebUICssPatcher.dump(css)
	check(lines == PackedStringArray(["0|statement|@import url(x.css)", "1|style|a, b", "2|at|@media (max-width: 600px)", "2.0|style|.x", "2.1|style|.y", "3|opaque|@keyframes k", "4|style|.z"]), "paths follow CSSOM order (@charset not counted, keyframes opaque): %s" % [lines])
	check(WebUICssPatcher.rule_matches(css, [2, 1], ".y"), "nested rule found by path")
	check(WebUICssPatcher.get_declaration(css, [4], "top") == "3px", "get_declaration reads the value")


func _test_replace() -> void:
	var css := ".a {\n  color: red;\n  margin: 0 !important;\n  color: blue;\n}\n"
	var r := WebUICssPatcher.set_declaration(css, [0], ".a", "color", "#fff")
	check(r.ok and r.text == ".a {\n  color: red;\n  margin: 0 !important;\n  color: #fff;\n}\n", "replaces the LAST duplicate only")
	r = WebUICssPatcher.set_declaration(css, [0], ".a", "margin", "4px 8px")
	check(r.ok and r.text == ".a {\n  color: red;\n  margin: 4px 8px !important;\n  color: blue;\n}\n", "keeps !important")
	r = WebUICssPatcher.set_declaration(css, [0], ".a", "COLOR", "green")
	check(r.ok and WebUICssPatcher.get_declaration(r.text, [0], "color") == "green", "property names are case-insensitive")
	check(edit_span(css, r.text).x <= 4, "only the old value (at most 4 characters) was replaced: %s" % [edit_span(css, r.text)])
	var crlf := ".a {\r\n\tcolor: red;\r\n}\r\n"
	r = WebUICssPatcher.set_declaration(crlf, [0], ".a", "color", "blue")
	check(r.ok and r.text == ".a {\r\n\tcolor: blue;\r\n}\r\n", "CRLF and tabs untouched")
	r = WebUICssPatcher.set_declaration(".a{color:red}", [0], ".a", "color", "blue")
	check(r.ok and r.text == ".a{color:blue}", "minified rule")


func _test_append() -> void:
	var r := WebUICssPatcher.set_declaration(".a {\n  color: red;\n}\n", [0], ".a", "margin", "4px")
	check(r.ok and r.text == ".a {\n  color: red;\n  margin: 4px;\n}\n", "appends below the last declaration with its indent")
	r = WebUICssPatcher.set_declaration(".a {\n\tcolor: red;\n}\n", [0], ".a", "margin", "4px")
	check(r.ok and r.text == ".a {\n\tcolor: red;\n\tmargin: 4px;\n}\n", "tab indentation reused")
	r = WebUICssPatcher.set_declaration(".a {\r\n  color: red;\r\n}\r\n", [0], ".a", "margin", "4px")
	check(r.ok and r.text == ".a {\r\n  color: red;\r\n  margin: 4px;\r\n}\r\n", "CRLF reused")
	r = WebUICssPatcher.set_declaration(".a { color: red; }", [0], ".a", "margin", "4px")
	check(r.ok and r.text == ".a { color: red; margin: 4px; }", "single-line rule stays single-line")
	r = WebUICssPatcher.set_declaration(".a { color: red }", [0], ".a", "margin", "4px")
	check(r.ok and r.text == ".a { color: red; margin: 4px; }", "adds the missing semicolon first")
	r = WebUICssPatcher.set_declaration(".a {\n  color: red\n}\n", [0], ".a", "margin", "4px")
	check(r.ok and r.text == ".a {\n  color: red;\n  margin: 4px;\n}\n", "missing semicolon on the last line")
	r = WebUICssPatcher.set_declaration(".a {\n  color: red; /* keep */\n}\n", [0], ".a", "margin", "4px")
	check(r.ok and r.text == ".a {\n  color: red; /* keep */\n  margin: 4px;\n}\n", "a trailing comment stays on its line")
	r = WebUICssPatcher.set_declaration(".a {}\n", [0], ".a", "margin", "4px")
	check(r.ok and r.text == ".a { margin: 4px; }\n", "empty single-line block")
	r = WebUICssPatcher.set_declaration("  .a {\n  }\n", [0], ".a", "margin", "4px")
	check(r.ok and r.text == "  .a {\n    margin: 4px;\n  }\n", "empty multi-line block uses the rule's indent")
	r = WebUICssPatcher.set_declaration(".a{color:red}", [0], ".a", "margin", "4px")
	check(r.ok and r.text == ".a{color:red; margin:4px;}", "minified: keeps the no-space style")
	r = WebUICssPatcher.set_declaration("@media (x) {\n  .a {\n    top: 0;\n  }\n}\n", [0, 0], ".a", "left", "1px")
	check(r.ok and r.text == "@media (x) {\n  .a {\n    top: 0;\n    left: 1px;\n  }\n}\n", "append inside @media keeps nesting indent")


func _test_tricky_syntax() -> void:
	var css := ".a { content: \"x;}{\"; background: url(data:image/png;base64,AAA=); /* } ; { */ color: red; }\n.b { top: 1px }\n"
	var r := WebUICssPatcher.set_declaration(css, [1], ".b", "top", "2px")
	check(r.ok and r.text.ends_with(".b { top: 2px }\n") and r.text.begins_with(".a { content"), "strings, url(;) and comments do not confuse rule boundaries")
	r = WebUICssPatcher.set_declaration(css, [0], ".a", "color", "blue")
	check(r.ok and r.text.contains("/* } ; { */ color: blue;") and r.text.contains("url(data:image/png;base64,AAA=)"), "edit next to tricky tokens")
	check(WebUICssPatcher.get_declaration(css, [0], "background") == "url(data:image/png;base64,AAA=)", "url(;) value read intact")
	r = WebUICssPatcher.set_declaration(".a { --c: #123; color: var(--c); }", [0], ".a", "--c", "#456")
	check(r.ok and r.text == ".a { --c: #456; color: var(--c); }", "custom properties keep their case and are editable")
	r = WebUICssPatcher.set_declaration(".A > .b ,.c   .d { top: 0 }", [0], ".a>.b, .c .d", "top", "1px")
	check(r.ok, "selector comparison ignores whitespace and case")
	r = WebUICssPatcher.set_declaration("input[type=range]::-webkit-slider-thumb { top: 0 }", [0], "input[type=\"range\"]::-webkit-slider-thumb", "top", "1px")
	check(r.ok, "selector comparison ignores the quotes the browser adds to attribute values")


func _test_refusals() -> void:
	var css := ".a { color: red; }\n@keyframes k { from { top: 0 } }\n.n { color: red; &:hover { color: blue; } }\n"
	var r := WebUICssPatcher.set_declaration(css, [0], ".other", "color", "blue")
	check(not r.ok and r.code == "selector_mismatch" and r.text == css, "selector mismatch refused, text unchanged")
	r = WebUICssPatcher.set_declaration(css, [9], ".a", "color", "blue")
	check(not r.ok and r.code == "no_rule", "missing path refused")
	r = WebUICssPatcher.set_declaration(css, [1], "@keyframes k", "color", "blue")
	check(not r.ok and r.code == "not_style_rule", "at-rules other than containers are not edited")
	r = WebUICssPatcher.set_declaration(css, [2], ".n", "color", "blue")
	check(not r.ok and r.code == "nesting_unsupported", "nested rules are refused")
	for bad in ["", "red; top: 0", "red}", "red /* x */", "red\\"]:
		r = WebUICssPatcher.set_declaration(css, [0], ".a", "color", bad)
		check(not r.ok and r.code == "bad_value", "unsafe value refused: %s" % bad.c_escape())
	r = WebUICssPatcher.set_declaration(css, [0], ".a", "co lor", "red")
	check(not r.ok and r.code == "bad_property", "bad property name refused")
	check(WebUICssPatcher.set_declaration("", [], "", "color", "red").code == "no_rule", "empty path refused")


## Every declaration of every real stylesheet in the repo: writing its own value back must not change
## a single byte, and a new declaration must be a pure insertion (nothing removed or altered).
func _test_real_files() -> void:
	var files := ["res://examples/playable_character/ui/menu.css", "res://examples/playable_character/ui/style.css", "res://examples/minimal_hud/ui/hud.css"]
	var noops := 0
	var appended := 0
	var bad := 0
	for file in files:
		var text := FileAccess.get_file_as_string(file)
		check(not text.is_empty(), "%s readable" % file)
		var rules: Array = []
		_flatten_style(WebUICssPatcher.parse(text), rules)
		check(rules.size() > 5, "%s: %d style rules parsed" % [file, rules.size()])
		for rule: Dictionary in rules:
			for decl: Dictionary in rule.decls:
				var value := text.substr(decl.value_start, decl.value_end - decl.value_start)
				var r := WebUICssPatcher.set_declaration(text, rule.path, rule.prelude, decl.name, value)
				if r.ok and r.text == text:
					noops += 1
				else:
					bad += 1
			var a := WebUICssPatcher.set_declaration(text, rule.path, rule.prelude, "outline-offset", "3px")
			if a.ok and edit_span(text, a.text).x == 0 and WebUICssPatcher.get_declaration(a.text, rule.path, "outline-offset") == "3px" and WebUICssPatcher.parse(a.text).size() == WebUICssPatcher.parse(text).size():
				appended += 1
			else:
				bad += 1
	check(bad == 0, "real stylesheets: every no-op edit and every append is exact (%d no-ops, %d appends, %d bad)" % [noops, appended, bad])


func _flatten_style(rules: Array, out: Array) -> void:
	for rule: Dictionary in rules:
		if rule.kind == "style" and not rule.nested:
			out.append(rule)
		elif rule.kind == "at":
			_flatten_style(rule.children, out)


func _test_files() -> void:
	var path := TMP_DIR.path_join("t.css")
	var original := "﻿.a {\r\n  color: red;\r\n}\r\n"
	WebUICssPatcher.write_file_atomic(path, original)
	var state := WebUICssPatcher.read_file(path)
	check(state.ok and state.text == original, "BOM and CRLF survive a write/read")

	var r := WebUICssPatcher.patch_file(path, state.hash, [0], ".a", "color", "blue")
	check(r.ok and WebUICssPatcher._read_text(path) == "﻿.a {\r\n  color: blue;\r\n}\r\n", "patch_file writes the change, keeping BOM and CRLF")
	check(not FileAccess.file_exists(path + ".webui_tmp"), "no temporary file left behind")

	var before := WebUICssPatcher._read_text(path)
	r = WebUICssPatcher.patch_file(path, state.hash, [0], ".a", "color", "green")
	check(not r.ok and r.code == "file_changed" and WebUICssPatcher._read_text(path) == before, "a stale hash refuses to write")
	r = WebUICssPatcher.patch_file(path, r.hash, [0], ".wrong", "color", "green")
	check(not r.ok and r.code == "selector_mismatch" and WebUICssPatcher._read_text(path) == before, "selector mismatch leaves the file alone")
	r = WebUICssPatcher.patch_file(TMP_DIR.path_join("missing.css"), "", [0], ".a", "color", "x")
	check(not r.ok and r.code == "read_failed", "missing file reported")

	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(TMP_DIR)
