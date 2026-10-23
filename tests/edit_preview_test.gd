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

	preview.send_edit({"op": "select", "selector": "#btn-play"})
	var selected := await _wait_for("selected")
	check(not selected.is_empty() and selected.selector == "#btn-play", "select by selector reports the element")
	if selected.is_empty():
		quit(failures)
		return
	check(selected.rules.size() >= 2 and selected.targets.has("font-size"), "matching rules and per-property targets reported")
	var target_index: int = selected.targets["border-radius"] if selected.targets["border-radius"] >= 0 else selected.fallback
	check(target_index >= 0, "a rule is offered for border-radius")
	var rule: Dictionary = selected.rules[target_index]
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
