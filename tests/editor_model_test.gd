extends SceneTree
## Run: godot --headless --path . -s res://tests/editor_model_test.gd
## Covers WebUIEditorModel (the logic behind the visual editor dock) against a throwaway UI folder:
## rule choice, unsaved changes, undo, save, replay after a reload. No WebView, no editor.

var failures := 0
var sent: Array = []
const DIR := "user://editor_model_test/ui"
const CSS := ".a {\n  color: red;\n  margin: 0;\n}\n\n.b {\n  padding: 4px;\n}\n"


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _initialize() -> void:
	_test_choice_and_edit()
	_test_save_and_undo()
	_test_stale_file_and_replay()
	_test_failures()
	DirAccess.remove_absolute(DIR.path_join("s.css"))
	DirAccess.remove_absolute(DIR)
	quit(failures)


func fresh() -> WebUIEditorModel:
	DirAccess.make_dir_recursive_absolute(DIR)
	WebUICssPatcher.write_file_atomic(DIR.path_join("s.css"), CSS)
	sent.clear()
	var model := WebUIEditorModel.new()
	model.send = func(op: String, payload: Dictionary) -> void: sent.append([op, payload])
	model.open_page("user://editor_model_test/ui", "p.html")
	model.on_page_message({"op": "ready"})
	sent.clear()
	return model


## What edit_mode.js reports for an element matched by `.a` (rule 0, declares color) and `.b` (rule 1).
func selection_payload() -> Dictionary:
	return {
		"op": "selected", "selector": "#x", "computed": {"color": "rgb(255, 0, 0)", "font-size": "16px", "margin-top": "0px"},
		"rules": [
			{"file": "s.css", "inline": false, "path": [0.0], "selector": ".a", "conditions": [], "declared": {"color": {"value": "red", "important": false}, "margin-top": {"value": "0", "important": false}}},
			{"file": "s.css", "inline": false, "path": [1.0], "selector": ".b", "conditions": [], "declared": {}},
			{"file": "", "inline": true, "path": [0.0], "selector": "p", "conditions": [], "declared": {"font-size": {"value": "9px", "important": false}}},
		],
		"targets": {"color": 0, "margin-top": 0, "font-size": 2, "padding-top": -1}, "fallback": 1,
	}


func ops() -> Array:
	return sent.map(func(m: Array) -> String: return m[0])


func _test_choice_and_edit() -> void:
	var m := fresh()
	m.on_page_message(selection_payload())
	check(m.choose_rule("color") == 0, "the winning rule is chosen for a declared property")
	check(m.choose_rule("padding-top") == 1, "an undeclared property goes to the page's fallback rule")
	check(m.choose_rule("font-size") == 1, "a winner without a file (inline/<style>) falls back to an editable rule")
	m.target_rule = 1
	check(m.choose_rule("color") == 1, "an explicit target rule overrides the winner")
	m.target_rule = 2
	check(m.choose_rule("color") == -1, "an explicit rule without a file cannot be edited")
	m.target_rule = -1
	check(m.current_value("color") == {"text": "red", "declared": true}, "current value is the authored one")
	check(m.current_value("font-size") == {"text": "16px", "declared": false}, "undeclared values come from the computed style")

	check(m.set_property("color", "blue"), "a change is accepted")
	check(sent[-1][0] == "apply" and sent[-1][1] == {"file": "s.css", "path": [0], "selector": ".a", "prop": "color", "value": "blue"}, "and applied to the page with the rule's address")
	check(m.pending.size() == 1 and m.pending[0].old == "red", "the original value is remembered")
	m.set_property("color", "green")
	check(m.pending.size() == 1 and m.pending[0].new == "green" and m.pending[0].old == "red", "changing it again updates one entry and keeps the first old value")
	check(m.current_value("color").text == "green", "current value shows the unsaved change")
	m.set_property("color", "red")
	check(m.pending.is_empty() and sent[-1][1].value == "red", "setting it back removes the change")
	check(not m.set_property("color", "  "), "an empty value is ignored")

	m.set_property("padding-top", "10px")
	m.set_property("color", "blue")
	m.undo()
	check(m.pending.size() == 1 and sent[-1][1].prop == "color" and sent[-1][1].value == "red", "undo restores the previous value in the page")
	m.undo()
	check(m.pending.is_empty() and sent[-1][1].prop == "padding-top" and sent[-1][1].value == "", "undo of a newly added property removes it (empty value)")


func _test_save_and_undo() -> void:
	var m := fresh()
	m.on_page_message(selection_payload())
	m.set_property("color", "blue")
	m.set_property("padding-top", "10px")
	sent.clear()
	var r := m.save()
	check(r.ok and r.saved == 2 and m.pending.is_empty(), "save writes every change")
	var text := WebUICssPatcher._read_text(DIR.path_join("s.css"))
	check(text == ".a {\n  color: blue;\n  margin: 0;\n}\n\n.b {\n  padding: 4px;\n  padding-top: 10px;\n}\n", "only the two declarations changed in the file: %s" % text.c_escape())
	check(ops() == ["hold", "synced"], "hot reload is held while writing and released without a reload: %s" % [ops()])
	check(m.save().saved == 0, "saving again with nothing pending does nothing")
	m.set_property("margin-top", "5px")
	check(m.save().ok, "a later save works (the file hash was tracked)")
	m.undo()
	check(sent[-1][0] == "reload", "undoing a save reloads the preview")
	check(not WebUICssPatcher._read_text(DIR.path_join("s.css")).contains("margin-top"), "and restores the file as it was before that save")
	check(WebUICssPatcher._read_text(DIR.path_join("s.css")).contains("color: blue"), "earlier saves stay")

	m.set_property("margin-top", "7px")
	check(m.save().ok, "another save for the next check")
	WebUICssPatcher.write_file_atomic(DIR.path_join("s.css"), CSS + "/* edited elsewhere */\n")
	m.undo()
	check(m.status.contains("Cannot undo") and m.can_undo(), "undo of a save is refused when the file changed in the meantime (status: %s)" % m.status)


func _test_stale_file_and_replay() -> void:
	var m := fresh()
	m.on_page_message(selection_payload())
	m.set_property("color", "blue")
	WebUICssPatcher.write_file_atomic(DIR.path_join("s.css"), CSS + "\n.c { top: 0; }\n")  # an AI agent edited it
	sent.clear()
	var r := m.save()
	check(not r.ok and m.pending.size() == 1 and r.error.contains("changed on disk"), "a file changed since load is not overwritten; the change stays pending")
	check(ops() == ["hold", "synced"], "hot reload is released even when the save failed")
	check(WebUICssPatcher._read_text(DIR.path_join("s.css")).contains("color: red"), "the file kept its content")

	sent.clear()
	m.on_page_message({"op": "ready"})  # the page reloaded (hot reload picked up the external edit)
	check(ops() == ["apply", "select"] and sent[0][1].value == "blue" and sent[1][1].selector == "#x", "after a reload unsaved changes are re-applied and the element is selected again")
	check(m.save().ok, "after the reload the new file state is the baseline and saving works")


func _test_failures() -> void:
	var m := fresh()
	m.on_page_message(selection_payload())
	m.set_property("color", "not-a-colour")
	m.on_page_message({"op": "apply_result", "ok": false, "error": "invalid_value", "file": "s.css", "path": [0.0], "prop": "color"})
	check(m.pending.is_empty() and m.status.contains("refused"), "a value the page rejects is dropped from the unsaved changes")

	m.ui_dir = "user://editor_model_test/ui"
	m.page = "../../escape/p.html"
	m.set_property("color", "blue")
	var r := m.save()
	check(not r.ok and r.error.contains("outside"), "a stylesheet outside the UI folder is refused")

	var n := fresh()
	n.on_page_message({"op": "preview_error", "code": "desktop_preview_missing_dependency", "text": "install godot_wry"})
	check(n.status.contains("godot_wry"), "preview start-up problems reach the status line")
	check(not n.set_property("color", "red"), "no selection, no edit")

	n.on_page_message({"op": "ready"})
	n.on_page_message({"op": "preview_opened", "ui_dir": "user://editor_model_test/ui", "page": "p.html"})
	check(n.preview_ready, "a preview showing the expected page is fine")
	n.on_page_message({"op": "preview_opened", "ui_dir": "res://other", "page": "index.html"})
	check(not n.preview_ready and n.status.contains("index.html") and n.status.contains("p.html"), "a preview showing another page than the dock expects is reported")
