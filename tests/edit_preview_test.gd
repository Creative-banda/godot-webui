extends SceneTree
## Run (needs a window and the optional godot_wry preview dependency, so NOT --headless):
##   godot --path . -s res://tests/edit_preview_test.gd
## Opens a real demo page in the desktop preview with edit mode, selects an element with a synthetic
## click, applies a style change live and checks the page's reply. Skips (exit 0) when godot_wry is
## not installed. Exit code = number of failures.

var failures := 0
var _messages: Array = []


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		print("SKIP  edit_preview_test needs a window (run it without --headless)")
		quit(0)
		return
	var failure := WebUIBackendDesktop._load_dependency()
	if not failure.is_empty():
		print("SKIP  godot_wry is not installed: ", failure.code)
		quit(0)
		return
	_run()


func _run() -> void:
	await process_frame  # the root window is not in the tree yet during _initialize
	var preview := WebUIEditPreview.new()
	preview.auto_open = false
	root.add_child(preview)
	preview.edit_message.connect(func(payload: Dictionary) -> void: _messages.append(payload))
	check(preview.get_window().always_on_top, "the preview window stays above the editor")
	check(preview.open("res://examples/playable_character/ui", "menu.html"), "preview opens the demo menu with edit mode")

	var ready := await _wait_for("ready")
	check(not ready.is_empty(), "edit mode announces itself")
	if ready.is_empty():
		quit(failures)
		return

	preview.send_edit({"op": "config", "props": WebUICssCatalog.property_config()})
	preview.send_edit({"op": "select", "selector": "#btn-play"})
	var selected := await _wait_for("selected")
	check(not selected.is_empty() and selected.selector == "#btn-play", "select by selector reports the element")
	if selected.is_empty():
		quit(failures)
		return
	check(selected.kind == "button" and selected.tag == "button" and selected.id_unique and selected.display == "flex", "the page identifies the element: %s, %s" % [selected.kind, selected.display])
	check(selected.computed.has("letter-spacing") and selected.computed.has("border-radius") and selected.computed["border-radius"] != "", "computed values are reported for the configured properties")
	var inner_play: Array = selected.texts.filter(func(t: Dictionary) -> bool: return t.text == "Play Game")
	check(inner_play.size() == 1 and inner_play[0].tag == "b" and inner_play[0].unique, "the text inside the button (<b>Play Game</b>) is reported as its own editable piece")
	var menu_html := FileAccess.get_file_as_string("res://examples/playable_character/ui/menu.html")
	check(WebUIHtmlPatcher.replace_text(menu_html, "Play Game", "Play Game").ok, "and it can be found exactly once in the real HTML file")
	_messages.clear()
	preview.send_edit({"op": "apply_text", "text": "Start", "selector": inner_play[0].selector})
	var inner_done := await _wait_for("content_result")
	var inner_sel := await _wait_for("selected")
	check(inner_done.ok and inner_sel.selector == "#btn-play" and inner_sel.texts.any(func(t: Dictionary) -> bool: return t.text == "Start"), "changing it in the page keeps the button selected")
	var by_selector := {}
	for r: Dictionary in selected.rules:
		by_selector[r.selector] = r
	check(by_selector.has(".hero") and by_selector.has("button") and by_selector[".hero"].affects == 1 and by_selector["button"].affects > 1, "matching rules are reported with how many elements each affects")
	var rule: Dictionary = by_selector[".hero"]
	check(rule.file == "menu.css", "the rule is traced to its file: %s" % rule.file)

	# The reported rule is exactly what the patcher can edit in the real source file.
	var source := FileAccess.get_file_as_string("res://examples/playable_character/ui/" + rule.file)
	check(WebUICssPatcher.rule_matches(source, rule.path, rule.selector), "the patcher finds the same rule in the file (%s at %s)" % [rule.selector, rule.path])

	_messages.clear()
	preview.send_edit({"op": "apply", "file": rule.file, "path": rule.path, "selector": rule.selector, "prop": "border-radius", "value": "3px"})
	var result := await _wait_for("apply_result")
	check(not result.is_empty() and result.ok, "a valid change applies live")
	var after := await _wait_for("selected")
	check(not after.is_empty() and after.computed["border-radius"] == "3px", "the element's computed style changed")

	_messages.clear()
	preview.send_edit({"op": "apply", "file": rule.file, "path": rule.path, "selector": rule.selector, "prop": "border-radius", "value": "banana"})
	result = await _wait_for("apply_result")
	check(not result.is_empty() and not result.ok and result.error == "invalid_value", "an invalid value is rejected by the page")

	_messages.clear()
	preview.send_edit({"op": "apply", "file": rule.file, "path": rule.path, "selector": ".not-this", "prop": "color", "value": "red"})
	result = await _wait_for("apply_result")
	check(not result.is_empty() and not result.ok and result.error == "selector_mismatch", "a stale selector is rejected by the page")

	# A change that something with higher priority overrides is detected and undone.
	var low: Dictionary = by_selector["button"]
	_messages.clear()
	preview.send_edit({"op": "apply", "file": low.file, "path": low.path, "selector": low.selector, "prop": "color", "value": "rgb(1, 2, 3)"})
	result = await _wait_for("apply_result")
	check(not result.is_empty() and not result.ok and result.error == "ineffective" and result.blocker.contains(".hero"), "a change overridden by a more specific rule is refused and the blocker named: %s" % result.get("blocker", ""))

	# An element-only rule, then removing it again.
	_messages.clear()
	preview.send_edit({"op": "add_rule", "file": "menu.css", "selector": "#btn-play", "decls": {"letter-spacing": "3px"}})
	var added := await _wait_for("rule_result")
	check(not added.is_empty() and added.ok and added.path.size() == 1, "a #id rule can be added to the page")
	var with_rule := await _wait_for("selected")
	check(not with_rule.is_empty() and with_rule.computed["letter-spacing"] == "3px", "and it takes effect")
	_messages.clear()
	preview.send_edit({"op": "remove_rule", "file": "menu.css", "path": added.path, "selector": "#btn-play"})
	var removed := await _wait_for("rule_result")
	check(not removed.is_empty() and removed.ok, "and removed again")

	# Sample game state: the page shows it as if Godot had sent it.
	_messages.clear()
	preview.send_edit({"op": "select", "selector": "#ab-engine"})
	var before_state := await _wait_for("selected")
	check(not before_state.is_empty() and before_state.text == "...", "without sample state the page shows its placeholder")
	preview._on_editor_message("sample", {"states": {"info": {"engine": "9.9.9 sample", "os": "TestOS", "renderer": "mobile", "level": 1}}, "events": []})
	await create_timer(0.6).timeout
	_messages.clear()
	preview.send_edit({"op": "select", "selector": "#ab-engine"})
	var with_state := await _wait_for("selected")
	check(not with_state.is_empty() and with_state.text == "Godot 9.9.9 sample", "with sample state the page renders it: %s" % with_state.get("text", ""))

	# Text and attributes of a plain element.
	_messages.clear()
	preview.send_edit({"op": "select", "selector": ".hint"})
	var hint := await _wait_for("selected")
	check(not hint.is_empty() and hint.kind == "text" and hint.text_editable and hint.text_unique, "a plain paragraph is reported as editable text")
	_messages.clear()
	preview.send_edit({"op": "apply_text", "text": "Edited text"})
	var content := await _wait_for("content_result")
	check(not content.is_empty() and content.ok, "its text changes live")
	var edited := await _wait_for("selected")
	check(not edited.is_empty() and edited.text == "Edited text", "and is reported back")
	_messages.clear()
	preview.send_edit({"op": "apply_attr", "name": "title", "value": "T"})
	content = await _wait_for("content_result")
	var titled := await _wait_for("selected")
	check(content.ok and titled.attrs.get("title") == "T", "an attribute changes live")

	# Elements with pointer-events: none (the HUD readouts) can still be picked with a click at their position.
	_messages.clear()
	preview._on_editor_message("page", {"page": "hud.html"})
	var hud_ready := await _wait_for("ready")
	check(not hud_ready.is_empty(), "another page of the folder opens")
	for id in ["#r-pos", "#level-text", "#hp-text"]:
		_messages.clear()
		preview.send_edit({"op": "select", "selector": id})
		var readout := await _wait_for("selected")
		var rect: Dictionary = readout.rect
		_messages.clear()
		preview.send_edit({"op": "select", "x": rect.x + rect.w / 2.0, "y": rect.y + rect.h / 2.0})
		var picked := await _wait_for("selected")
		check(not picked.is_empty() and picked.selector == id, "a click on %s (pointer-events: none) selects it, not what is underneath: %s" % [id, picked.get("selector", "")])
	_messages.clear()
	preview.send_edit({"op": "select", "selector": "#btn-jump"})
	var jump := await _wait_for("selected")
	_messages.clear()
	preview.send_edit({"op": "select", "x": jump.rect.x + jump.rect.w / 2.0, "y": jump.rect.y + jump.rect.h / 2.0})
	var jump_pick := await _wait_for("selected")
	check(not jump_pick.is_empty() and jump_pick.selector.begins_with("#btn-jump"), "an ordinary button is still picked as before: %s" % jump_pick.get("selector", ""))

	preview.ui.shutdown()
	quit(failures)


## First message with this op, waiting up to 15 s. {} on timeout.
func _wait_for(op: String) -> Dictionary:
	var waited := 0.0
	while waited < 15.0:
		for message: Dictionary in _messages:
			if message.op == op:
				_messages.erase(message)
				return message
		await create_timer(0.1).timeout
		waited += 0.1
	return {}
