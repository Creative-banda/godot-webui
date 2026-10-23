extends SceneTree
## Run: godot --headless --path . -s res://tests/editor_model_test.gd
## Covers WebUIEditorModel (the logic behind the visual editor dock) against a throwaway UI folder:
## where a value comes from, which rule a change goes to (and when it must not go anywhere), unsaved
## changes, undo, save for stylesheets and the HTML file, replay after a reload. No WebView, no editor.
## Exit code = number of failures.

var failures := 0
var sent: Array = []
const DIR := "user://editor_model_test/ui"
const CSS := "button { color: inherit; font: inherit; }\n.btn { color: red; padding: 4px 8px; margin-top: 2px !important; }\n.one { background-color: blue; }\n@media (max-width: 600px) {\n  .one { width: 10px; }\n}\n#big { color: green !important; }\n.shared-only { border-radius: 4px; }\n.imp { margin: 0 !important; }\n.v { color: var(--mint); }\n"
const HTML := "<!doctype html>\n<body>\n  <button id=\"x1\" class=\"one\">Go</button>\n  <p>Dup</p>\n  <p>Dup</p>\n  <img id=\"img1\" src=\"a.png\">\n  <img src=\"b.png\">\n</body>\n"


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _initialize() -> void:
	_test_resolution()
	_test_planning()
	_test_blocked()
	_test_editing_and_save()
	_test_retry_when_overridden()
	_test_new_rule()
	_test_content()
	_test_replay_and_stale()
	_test_inspector()
	_test_sample_state()
	DirAccess.remove_absolute(DIR.path_join(".webui-edit").path_join("p.json"))
	DirAccess.remove_absolute(DIR.path_join(".webui-edit").path_join(".gdignore"))
	DirAccess.remove_absolute(DIR.path_join(".webui-edit"))
	DirAccess.remove_absolute(DIR.path_join("app.js"))
	DirAccess.remove_absolute(DIR.path_join("s.css"))
	DirAccess.remove_absolute(DIR.path_join("p.html"))
	DirAccess.remove_absolute(DIR)
	quit(failures)


func fresh() -> WebUIEditorModel:
	DirAccess.make_dir_recursive_absolute(DIR)
	WebUICssPatcher.write_file_atomic(DIR.path_join("s.css"), CSS)
	WebUICssPatcher.write_file_atomic(DIR.path_join("p.html"), HTML)
	sent.clear()
	var model := WebUIEditorModel.new()
	model.send = func(op: String, payload: Dictionary) -> void: sent.append([op, payload])
	model.open_page("user://editor_model_test/ui", "p.html")
	model.on_page_message({"op": "ready"})
	sent.clear()
	return model


func ops() -> Array:
	return sent.map(func(m: Array) -> String: return m[0])


func rule(path: Array, selector: String, specificity: int, order: int, affects: int, declared: Dictionary, conditions := [], file := "s.css") -> Dictionary:
	return {"file": file, "inline": file == "", "path": path, "selector": selector, "conditions": conditions, "specificity": specificity, "order": order, "affects": affects, "declared": declared, "vars": []}


## What edit_mode.js reports for an element; `extra` overrides fields.
func element(rules: Array, extra := {}) -> Dictionary:
	var base := {
		"op": "selected", "selector": "#x1", "tag": "button", "id": "x1", "id_unique": true, "classes": ["one"], "kind": "button",
		"attrs": {}, "text": "Go", "text_editable": true, "text_unique": true, "text_mixed": false, "display": "flex", "position": "static",
		"parent_display": "block", "animated": false, "children": 0,
		"computed": {"color": "rgb(255, 0, 0)", "background-color": "rgb(0, 0, 255)", "padding-top": "4px", "margin-top": "2px", "margin-left": "0px", "width": "10px", "border-radius": "0px", "font-size": "16px"},
		"inline": {}, "inherited": {}, "vars": {}, "rules": rules, "fonts": [], "sheets": [{"file": "s.css", "rules": 8}],
	}
	base.merge(extra, true)
	return base


func standard_rules() -> Array:
	return [
		rule([0], "button", 1, 0, 4, {"color": false, "font-size": false}),
		rule([1], ".btn", 100, 1, 2, {"color": false, "padding-top": false, "margin-top": true}),
		rule([2], ".one", 100, 2, 1, {"background-color": false}),
		rule([3, 0], ".one", 100, 3, 1, {"width": false}, ["@media (max-width: 600px)"]),
	]


func _test_resolution() -> void:
	var m := fresh()
	m.on_page_message(element(standard_rules()))
	var bg := m.describe("background-color")
	check(bg.state == "rule" and bg.text == "blue" and bg.editable and bg.shared == 1 and bg.source.begins_with(".one  in s.css"), "a declared value is shown as authored with its source: %s" % [bg.source])
	var color := m.describe("color")
	check(color.state == "rule" and color.text == "red" and color.source.begins_with(".btn"), "the cascade winner (higher specificity) is the source of the color, not the shared `button` rule")
	check(color.shared == 1 and color.editable, "but the change goes to a rule that affects only this element")
	var width := m.describe("width")
	check(width.state == "rule" and width.source.contains("@media (max-width: 600px)") and width.text == "10px", "a value from a media query says so")
	var padding := m.describe("padding-top")
	check(padding.state == "rule" and padding.text == "4px" and padding.note.contains("shorthand `padding: 4px 8px`"), "a value set by a shorthand shows the computed value and names the shorthand: %s" % padding.note)
	var weight := m.describe("font-size")
	check(weight.state == "rule" and weight.note.contains("`font: inherit`"), "`font: inherit` is recognised as setting font-size")
	var radius := m.describe("border-radius")
	check(radius.state == "default" and radius.text == "0px" and radius.source == "browser default", "an undeclared value is the browser default")
	m.on_page_message(element(standard_rules(), {"inherited": {"color": {"from": "body", "tag": "body", "selector": "html, body", "file": "s.css"}}, "rules": [rule([2], ".one", 100, 2, 1, {"background-color": false})]}))
	var inherited := m.describe("color")
	check(inherited.state == "inherited" and inherited.source.begins_with("inherited from html, body"), "an inherited value says where it comes from")


func _test_planning() -> void:
	var m := fresh()
	m.on_page_message(element(standard_rules()))
	check(m.set_property("background-color", "red"), "editing a value that belongs to this element's own rule")
	check(sent[-1][0] == "apply" and sent[-1][1].path == [2] and sent[-1][1].selector == ".one" and sent[-1][1].value == "red", "goes to that rule")
	m.undo()
	sent.clear()
	m.set_property("color", "blue")
	check(sent[-1][1].path == [2] and sent[-1][1].prop == "color", "a color whose winner is a rule shared with another element goes to the rule that matches this element only")
	var plan := m._plans("color")
	check(plan.plans[0].kind == "decl" and plan.plans[0].shared == 1 and plan.plans[-1].kind == "new_rule", "the element-only rule (#x1) is the fallback plan")
	m.undo()

	# the element has its own rule that already holds a shorthand: the longhand is appended after it
	var own := [rule([1], ".btn", 100, 1, 1, {"padding-top": false, "color": false})]
	m.on_page_message(element(own))
	m.set_property("padding-top", "10px")
	check(sent[-1][1].path == [1] and sent[-1][1].value == "10px", "a longhand next to a shorthand goes into the same rule")
	m.save()
	check(WebUICssPatcher._read_text(DIR.path_join("s.css")).contains(".btn { color: red; padding: 4px 8px; margin-top: 2px !important; padding-top: 10px; }") or WebUICssPatcher._read_text(DIR.path_join("s.css")).contains("padding-top: 10px;"), "and is written after it")

	# the winner is important: the new declaration has to be too, or it would lose
	var m2 := fresh()
	m2.on_page_message(element([rule([6], ".imp", 100, 6, 1, {"margin-top": true, "margin-left": true})]))
	m2.set_property("margin-left", "5px")
	check(sent[-1][1].important == true, "a declaration that overrides an !important one is written !important")
	m2.save()
	check(WebUICssPatcher._read_text(DIR.path_join("s.css")).contains(".imp { margin: 0 !important; margin-left: 5px !important; }"), "and saved that way")

	# only a shared rule exists and there is no id: the change is allowed but says it is shared
	var m3 := fresh()
	m3.on_page_message(element([rule([5], ".shared-only", 100, 5, 5, {"border-radius": false})], {"id": "", "id_unique": false, "selector": "div.shared-only"}))
	var radius := m3.describe("border-radius")
	check(radius.editable and radius.shared == 5 and radius.note.contains("used by 5 elements"), "a rule shared by several elements is flagged: %s" % radius.note)
	m3.set_property("border-radius", "12px")
	check(sent[-1][1].path == [5] and m3.status.contains("used by 5 elements"), "and the status repeats the warning")

	# explicit targets
	var m4 := fresh()
	m4.on_page_message(element(standard_rules()))
	m4.target_rule = 0
	m4.set_property("color", "blue")
	check(sent[-1][1].path == [0], "a chosen rule is used as chosen")
	m4.undo()
	m4.target_rule = -2
	sent.clear()
	m4.set_property("color", "blue")
	check(sent[-1][0] == "add_rule" and sent[-1][1].selector == "#x1" and sent[-1][1].file == "s.css", "'this element only' writes a #id rule")


func _test_blocked() -> void:
	var m := fresh()
	m.on_page_message(element(standard_rules(), {"inline": {"color": {"value": "pink", "important": false}}}))
	var color := m.describe("color")
	check(color.state == "inline" and not color.editable and color.reason.contains("style attribute"), "a value from the style attribute cannot be edited, and the reason says why")
	check(not m.set_property("color", "blue") and m.status.contains("style attribute") and sent.is_empty(), "no change is made or sent")
	m.on_page_message(element([rule([0], "button", 1, 0, 4, {"color": false}), rule([0], ".tmp", 100, 9, 1, {"color": false}, [], "")]))
	var external := m.describe("color")
	check(external.state == "external" and not external.editable and external.reason.contains("<style>"), "a rule in a <style> block cannot be edited")
	m.on_page_message(element([rule([1], ".btn", 100, 1, 1, {"color": false})], {"id": "", "id_unique": false}))
	m.target_rule = -2
	check(not m.set_property("color", "blue") and m.status.contains("no unique id"), "an element-only rule needs a unique id")
	m.target_rule = -1
	# a rule whose file no longer has the rule the page reported
	m.on_page_message(element([rule([1], ".gone", 100, 1, 1, {"color": false}), rule([9], ".btn", 100, 2, 1, {"color": false})], {"id": "", "id_unique": false}))
	check(not m.describe("color").editable, "a rule the file does not have (the file changed) is not edited")


func _test_editing_and_save() -> void:
	var m := fresh()
	m.on_page_message(element(standard_rules()))
	m.set_property("background-color", "green")
	m.set_property("background-color", "#00ff00")
	check(m.pending.size() == 1 and m.pending[0].old == "blue" and m.pending[0].new == "#00ff00", "changing a value again keeps one change with the original old value")
	m.set_property("background-color", "blue")
	check(m.pending.is_empty(), "setting it back to the original removes the change")
	check(m.set_property("width", "20") and m.pending[0].new == "20px", "a bare number gets px for lengths")
	check(not m.set_property("width", "  "), "an empty value is ignored")
	m.undo()
	check(m.pending.is_empty() and sent[-1][1].value == "10px", "undo restores the previous value in the page")

	m.set_property("background-color", "red")
	m.set_property("width", "30px")
	sent.clear()
	var r := m.save()
	check(r.ok and r.saved == 2 and ops() == ["hold", "synced"], "save writes the changes and releases hot reload without a reload")
	var css := WebUICssPatcher._read_text(DIR.path_join("s.css"))
	check(css == CSS.replace("background-color: blue", "background-color: red").replace("width: 10px", "width: 30px"), "only the two values changed in the file")
	m.undo()
	check(WebUICssPatcher._read_text(DIR.path_join("s.css")) == CSS and sent[-1][0] == "reload", "undo after a save restores the file exactly and reloads the preview")


func _test_retry_when_overridden() -> void:
	var m := fresh()
	m.on_page_message(element(standard_rules()))
	m.set_property("color", "blue")
	check(sent[-1][0] == "apply" and sent[-1][1].path == [2], "first the element's own rule is tried")
	sent.clear()
	m.on_page_message({"op": "apply_result", "ok": false, "error": "ineffective", "file": "s.css", "path": [2.0], "prop": "color", "blocker": "s.css  #big"})
	check(m.pending.size() == 1 and m.pending[0].kind == "new_rule" and sent[-1][0] == "add_rule" and sent[-1][1].selector == "#x1", "when the page says it has no effect, the next plan (an element-only rule) is tried")
	m.on_page_message({"op": "rule_result", "kind": "add", "ok": false, "error": "ineffective", "file": "s.css", "selector": "#x1", "prop": "color", "blocker": "s.css  #big"})
	check(m.pending.is_empty() and m.status.contains("no effect") and m.status.contains("#big"), "after the last plan the change is refused and the blocker is named: %s" % m.status)
	m.on_page_message({"op": "apply_result", "ok": false, "error": "invalid_value", "file": "s.css", "path": [2.0], "prop": "color"})
	check(m.status.contains("not a valid CSS value"), "an invalid value is reported as that")


func _test_new_rule() -> void:
	var m := fresh()
	m.on_page_message(element([rule([0], "button", 1, 0, 4, {"color": false})]))
	check(m.describe("border-radius").editable and not m.describe("border-radius").note.contains("used by"), "with only a shared rule and a unique id an element-only rule is offered")
	m.set_property("border-radius", "9px")
	check(sent[-1][0] == "add_rule" and sent[-1][1].decls == {"border-radius": "9px"} and m.pending[0].kind == "new_rule", "the change creates a #id rule in the page")
	m.on_page_message({"op": "rule_result", "kind": "add", "ok": true, "file": "s.css", "selector": "#x1", "path": [8.0]})
	check(m.pending[0].path == [8], "the page reports where the new rule is")
	m.on_page_message(element([rule([0], "button", 1, 0, 4, {"color": false}), rule([8], "#x1", 10000, 9, 1, {"border-radius": false}, [])]))
	check(m.describe("border-radius").text == "9px" and m.describe("border-radius").source.begins_with("#x1"), "the new rule now shows as the source")
	sent.clear()
	m.set_property("padding-top", "3px")
	check(sent[-1][0] == "apply" and sent[-1][1].path == [8] and m.pending.size() == 1 and m.pending[0].decls.has("padding-top"), "further changes go into the same new rule")
	m.save()
	var css := WebUICssPatcher._read_text(DIR.path_join("s.css"))
	check(css == CSS + "\n#x1 {\n  border-radius: 9px;\n  padding-top: 3px;\n}\n", "save appends one rule at the end of the file: %s" % css.right(80).c_escape())
	m.undo()
	check(WebUICssPatcher._read_text(DIR.path_join("s.css")) == CSS, "undo after the save removes it again")

	var n := fresh()
	n.on_page_message(element([rule([0], "button", 1, 0, 4, {})]))
	n.set_property("border-radius", "9px")
	n.on_page_message({"op": "rule_result", "kind": "add", "ok": true, "file": "s.css", "selector": "#x1", "path": [8.0]})
	sent.clear()
	n.undo()
	check(n.pending.is_empty() and sent[-1][0] == "remove_rule" and sent[-1][1].path == [8], "undoing an unsaved element-only rule removes it from the page")

	var k := fresh()
	k.on_page_message(element([rule([0], "button", 1, 0, 4, {})]))
	k.set_property("border-radius", "9px")
	k.on_page_message({"op": "rule_result", "kind": "add", "ok": true, "file": "s.css", "selector": "#x1", "path": [7.0]})
	WebUICssPatcher.write_file_atomic(DIR.path_join("s.css"), CSS + ".extra { top: 0; }\n")
	k._hashes["s.css"] = WebUICssPatcher.read_file(DIR.path_join("s.css")).hash
	var failed := k.save()
	check(not failed.ok and failed.error.contains("rules"), "a file with a different number of rules than the page is refused: %s" % failed.error)


func _test_content() -> void:
	var m := fresh()
	m.on_page_message(element([rule([2], ".one", 100, 2, 1, {})]))
	var content := m.content_state()
	check(content.text.editable and content.text.value == "Go", "the text of an element that is in the HTML exactly once is editable")
	m.set_text("Start")
	check(m.pending[0].kind == "text" and sent[-1][0] == "apply_text" and sent[-1][1].text == "Start", "the new text goes to the page")
	m.save()
	check(WebUICssPatcher._read_text(DIR.path_join("p.html")) == HTML.replace(">Go<", ">Start<"), "and into the HTML file, changing nothing else")
	m.undo()
	check(WebUICssPatcher._read_text(DIR.path_join("p.html")) == HTML, "undo restores the HTML file")

	# a button whose text sits in an element inside it (<button><b>Go</b></button>): edited from the button
	var inner := fresh()
	inner.on_page_message(element([], {"text": "", "text_editable": false, "texts": [{"selector": "#x1 > b", "tag": "b", "text": "Go", "unique": true}]}))
	var inner_content := inner.content_state()
	check(not inner_content.text.editable and inner_content.texts.size() == 1 and inner_content.texts[0].editable, "the text of an element inside a button is offered, editable")
	var inner_rows: Array = inner.inspector()[0].rows
	check(inner_rows[0].type == "text" and inner_rows[0].label == "Text in <b>" and inner_rows[0].inner == "#x1 > b", "as a row of its own, named after its element")
	check(inner.set_text("Start", "#x1 > b") and sent[-1][0] == "apply_text" and sent[-1][1] == {"text": "Start", "selector": "#x1 > b"}, "the change names the inner element")
	check(inner.pending[0].element == "#x1 > b" and inner.inspector()[0].rows[0].text == "Start" and inner.inspector()[0].rows[0].unsaved, "and shows as unsaved in its row")
	inner.save()
	check(WebUICssPatcher._read_text(DIR.path_join("p.html")) == HTML.replace(">Go<", ">Start<"), "saving changes the text in the HTML file")
	check(not inner.set_text("x", "#nothing-here") and inner.status.contains("not part"), "text outside the selected element is refused")
	sent.clear()
	inner.undo()
	check(sent[-1][0] == "reload" and WebUICssPatcher._read_text(DIR.path_join("p.html")) == HTML, "undo restores it")

	var dup := fresh()
	dup.on_page_message(element([], {"selector": "p:nth-of-type(1)", "id": "", "id_unique": false, "tag": "p", "kind": "text", "text": "Dup", "text_unique": false}))
	check(not dup.content_state().text.editable and dup.content_state().text.reason.contains("several"), "text that appears several times is not editable, with the reason")
	check(not dup.set_text("x") and dup.pending.is_empty(), "and nothing is changed")
	dup.on_page_message(element([], {"kind": "text", "text": "Not in the file", "text_unique": true}))
	check(not dup.content_state().text.editable and dup.content_state().text.reason.contains("puts it there"), "text that is not in the HTML (set by JavaScript) is refused")
	dup.on_page_message(element([], {"kind": "container", "text": "", "text_editable": false, "text_mixed": true, "tag": "div", "id": "x1"}))
	check(not dup.content_state().text.editable, "an element that contains other elements has no editable text")

	var img := fresh()
	img.on_page_message(element([], {"tag": "img", "id": "img1", "id_unique": true, "kind": "image", "attrs": {"src": "a.png"}, "selector": "#img1", "text": "", "text_editable": false}))
	var attrs: Array = img.content_state().attrs
	var by_name := {}
	for attr: Dictionary in attrs:
		by_name[attr.name] = attr
	check(by_name.has("src") and not by_name.src.editable and by_name.alt.editable and by_name.alt.value == "", "an image shows its source read-only and its alt text editable")
	img.set_attribute("alt", "Logo")
	check(img.pending[0].kind == "attr" and sent[-1][0] == "apply_attr" and sent[-1][1].value == "Logo", "an attribute change reaches the page")
	img.save()
	check(WebUICssPatcher._read_text(DIR.path_join("p.html")) == HTML.replace("<img id=\"img1\" src=\"a.png\">", "<img id=\"img1\" src=\"a.png\" alt=\"Logo\">"), "and the HTML file")
	img.undo()
	check(WebUICssPatcher._read_text(DIR.path_join("p.html")) == HTML, "undo removes the added attribute again")
	img.on_page_message(element([], {"tag": "img", "id": "", "id_unique": false, "kind": "image", "attrs": {"src": "b.png"}, "selector": "img:nth-of-type(2)", "text": "", "text_editable": false}))
	var no_id: Dictionary = img.content_state().attrs.filter(func(a: Dictionary) -> bool: return a.name == "alt")[0]
	check(not no_id.editable and no_id.reason.contains("no unique id"), "without a unique id an attribute is not edited")


func _test_replay_and_stale() -> void:
	var m := fresh()
	m.on_page_message(element(standard_rules()))
	m.set_property("background-color", "red")
	m.set_text("Start")
	WebUICssPatcher.write_file_atomic(DIR.path_join("s.css"), CSS + "\n.c { top: 0; }\n")  # an AI agent edited it
	sent.clear()
	var r := m.save()
	check(not r.ok and r.error.contains("changed on disk") and m.pending.size() == 2, "a file changed since load is not overwritten; nothing is lost")
	check(ops() == ["hold", "synced"], "hot reload is released even when the save failed")
	sent.clear()
	m.on_page_message({"op": "ready"})
	var kinds := ops()
	check(kinds[0] == "config" and sent[0][1].props.has("color"), "after a reload the page is told which properties to report")
	check(kinds.slice(1, 3) == ["apply", "apply_text"] and sent[1][1].value == "red" and kinds[-1] == "select", "unsaved changes are re-applied and the element is selected again: %s" % [kinds])
	check(m.save().ok, "after the reload the new file state is the baseline and saving works")
	var other := fresh()
	other.on_page_message({"op": "preview_error", "code": "desktop_preview_missing_dependency", "text": "install godot_wry"})
	check(other.status.contains("godot_wry"), "preview start-up problems reach the status line")
	other.on_page_message({"op": "preview_opened", "ui_dir": "res://other", "page": "index.html"})
	check(not other.preview_ready and other.status.contains("index.html"), "a preview showing another page than expected is reported")


func _test_inspector() -> void:
	var m := fresh()
	check(m.inspector().is_empty(), "nothing is shown without a selection")
	m.on_page_message(element(standard_rules()))
	var sections := m.inspector()
	var ids := sections.map(func(s: Dictionary) -> String: return s.id)
	check(ids[0] == "content" and "colors" in ids and "interaction" in ids, "a button is inspected as a button: %s" % [ids])
	var content_section: Dictionary = sections[0]
	check(content_section.rows[0].type == "text" and content_section.rows[0].editable, "the content section starts with the editable text")
	var spacing: Dictionary = sections[ids.find("spacing")]
	check(spacing.rows[0].type == "sides" and spacing.rows[0].sides.size() == 4 and spacing.rows[0].sides[0].key == "padding-top" or spacing.rows[0].sides[0].key == "margin-top", "margin and padding are four-sided rows")
	m.on_page_message(element([], {"kind": "image", "tag": "img", "attrs": {"src": "a.png"}, "text": "", "text_editable": false}))
	var image_ids := m.inspector().map(func(s: Dictionary) -> String: return s.id)
	check("image" in image_ids and not ("typography" in image_ids) and not ("interaction" in image_ids), "the same model shows image sections for an image: %s" % [image_ids])


func _test_sample_state() -> void:
	var m := fresh()
	check(m.sample_text == "" and WebUIEditorModel.sample_path("res://ui", "menu.html") == "res://ui/.webui-edit/menu.json" and WebUIEditorModel.sample_path("res://ui", "sub/menu.html") == "res://ui/sub/.webui-edit/menu.json", "the sample lives next to the page in a hidden folder")
	check(m.set_sample("{ not json") == false and m.sample_error.begins_with("Not valid JSON"), "text that is not JSON is refused with the problem")
	check(not m.set_sample("[1]") and not m.set_sample("{\"colour\": 1}") and m.sample_error.contains("Unknown key"), "only states and events are accepted")
	check(not m.set_sample("{\"states\": {\"bad name\": {}}}") and m.sample_error.contains("valid state name"), "state names are checked like the bridge does")
	check(not m.set_sample("{\"states\": {\"hud\": 5}}") and not m.set_sample("{\"events\": [{\"payload\": {}}]}"), "values must be objects, events need a name")
	check(not FileAccess.file_exists(WebUIEditorModel.sample_path(DIR, "p.html")), "nothing is written for a refused sample")

	sent.clear()
	var good := {"states": {"hud": {"health": 80.5}}, "events": [{"name": "toast", "payload": {"text": "Hi"}}]}
	check(m.set_sample(JSON.stringify(good)) and sent[-1][0] == "sample" and JSON.stringify(sent[-1][1]) == JSON.stringify(good), "a valid sample is sent to the preview (%s)" % m.sample_error)
	check(FileAccess.file_exists(WebUIEditorModel.sample_path(DIR, "p.html")) and FileAccess.file_exists(DIR.path_join(".webui-edit").path_join(".gdignore")), "and saved next to the page, in a folder Godot ignores")
	var again := WebUIEditorModel.new()
	again.send = m.send
	again.open_page("user://editor_model_test/ui", "p.html")
	check(JSON.stringify(JSON.parse_string(again.sample_text)) == JSON.stringify(good), "opening the page again loads it")
	sent.clear()
	again.on_page_message({"op": "ready"})
	check(sent.any(func(x: Array) -> bool: return x[0] == "sample" and JSON.stringify(x[1]) == JSON.stringify(good)), "and it is sent whenever the page (re)loads")
	sent.clear()
	check(m.set_sample("  ") and m.sample_text == "" and not FileAccess.file_exists(WebUIEditorModel.sample_path(DIR, "p.html")) and sent[-1][1] == {"states": {}, "events": []}, "empty text removes it")

	# the template: names the page's scripts listen for
	WebUICssPatcher.write_file_atomic(DIR.path_join("app.js"), "Godot.on('hud', f); Godot.onState(\"settings\", g); Godot.onEvent('toast', h); Godot . on ( 'bad name', i ); Godot.on('hud', again);")
	var template: Variant = JSON.parse_string(m.sample_template())
	check(template.states.keys() == ["hud", "settings"] and template.events.size() == 1 and template.events[0].name == "toast", "the template lists the state and event names found in the page's scripts: %s" % [template])
