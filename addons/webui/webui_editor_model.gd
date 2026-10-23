@tool
class_name WebUIEditorModel
extends RefCounted
## The logic behind the visual editor dock, with no UI and no editor classes so it can be tested.
##
## It follows one page in the edit preview: the page reports the selected element and the style rules
## that apply to it; the model decides which rule a property change goes to, applies it to the page
## live, keeps the unsaved changes (so they can be undone, and replayed if the page reloads), and on
## save patches the source stylesheets in place with WebUICssPatcher.
##
## `send` is called as send(op: String, payload: Dictionary) for every command to the preview
## (apply / select / enable go to the page; hold / synced / reload to the preview's backend).

signal changed

## The editable properties, in display order: {name, kind, options?}. Kinds: length, color, enum, text.
const PROPERTIES := [
	{"name": "font-size", "kind": "length", "group": "Text"},
	{"name": "font-weight", "kind": "enum", "group": "Text", "options": ["normal", "bold", "300", "400", "500", "600", "700", "800", "900"]},
	{"name": "color", "kind": "color", "group": "Text"},
	{"name": "text-align", "kind": "enum", "group": "Text", "options": ["left", "center", "right", "justify", "start", "end"]},
	{"name": "background-color", "kind": "color", "group": "Box"},
	{"name": "width", "kind": "length", "group": "Box"},
	{"name": "height", "kind": "length", "group": "Box"},
	{"name": "margin-top", "kind": "length", "group": "Spacing"},
	{"name": "margin-right", "kind": "length", "group": "Spacing"},
	{"name": "margin-bottom", "kind": "length", "group": "Spacing"},
	{"name": "margin-left", "kind": "length", "group": "Spacing"},
	{"name": "padding-top", "kind": "length", "group": "Spacing"},
	{"name": "padding-right", "kind": "length", "group": "Spacing"},
	{"name": "padding-bottom", "kind": "length", "group": "Spacing"},
	{"name": "padding-left", "kind": "length", "group": "Spacing"},
	{"name": "border-top-width", "kind": "length", "group": "Border"},
	{"name": "border-style", "kind": "enum", "group": "Border", "options": ["none", "solid", "dashed", "dotted", "double"]},
	{"name": "border-color", "kind": "color", "group": "Border"},
	{"name": "border-radius", "kind": "length", "group": "Border"},
	{"name": "display", "kind": "enum", "group": "Layout", "options": ["block", "flex", "grid", "inline", "inline-block", "inline-flex", "none"]},
	{"name": "flex-direction", "kind": "enum", "group": "Layout", "options": ["row", "row-reverse", "column", "column-reverse"]},
	{"name": "justify-content", "kind": "enum", "group": "Layout", "options": ["flex-start", "center", "flex-end", "space-between", "space-around", "space-evenly"]},
	{"name": "align-items", "kind": "enum", "group": "Layout", "options": ["stretch", "flex-start", "center", "flex-end", "baseline"]},
	{"name": "gap", "kind": "length", "group": "Layout"},
]

var send := Callable()
var ui_dir := ""
var page := ""
var status := ""
var preview_ready := false
var selection: Dictionary = {}
## -1 = automatic (the rule that wins the property, else the page's best guess); otherwise an index into selection.rules.
var target_rule := -1
## Unsaved changes, oldest first: {file, path, selector, prop, old, new}. `old` is "" when the rule did not declare it.
var pending: Array = []

var _hashes := {}          # css file (relative to the page's folder) -> hash when the page loaded
var _last_save := {}       # {"files": {file: {"text": before, "hash": after}}, "count": n}


func open_page(new_ui_dir: String, new_page: String) -> void:
	ui_dir = new_ui_dir
	page = new_page
	selection = {}
	pending.clear()
	_hashes.clear()
	_last_save = {}
	preview_ready = false
	target_rule = -1
	_say("Opening %s ..." % new_page)


func has_pending() -> bool:
	return not pending.is_empty()


func can_undo() -> bool:
	return has_pending() or not _last_save.is_empty()


# ---------------------------------------------------------------- from the preview

func on_page_message(payload: Dictionary) -> void:
	match payload.get("op"):
		"ready":
			_on_ready()
		"selected":
			selection = payload
			if target_rule >= selection.rules.size():
				target_rule = -1
			changed.emit()
		"cleared":
			selection = {}
			changed.emit()
		"apply_result":
			if not payload.get("ok", false):
				_drop_failed(payload)
		"preview_opened":
			if payload.get("ui_dir") != ui_dir or payload.get("page") != page:
				preview_ready = false
				_say("The preview is showing %s, not %s. Close the preview window and press Open preview again." % [payload.get("page", "?"), page])
		"preview_error":
			preview_ready = false
			_say("Preview problem (%s): %s" % [payload.get("code", "?"), payload.get("text", "")])


func _on_ready() -> void:
	preview_ready = true
	_snapshot()
	var replay := pending.duplicate()
	for entry: Dictionary in replay:  # the page reloaded: show the unsaved changes again
		send.call("apply", _apply_payload(entry, entry.new))
	var remembered: String = selection.get("selector", "")
	selection = {}
	if not remembered.is_empty():
		send.call("select", {"selector": remembered})
	_say("Ready. Click an element in the preview." if remembered.is_empty() else "Reloaded.")


func _drop_failed(result: Dictionary) -> void:
	for i in range(pending.size() - 1, -1, -1):
		var entry: Dictionary = pending[i]
		if entry.prop == result.get("prop") and entry.file == result.get("file") and str(entry.path) == str(_ints(result.get("path", []))):
			pending.remove_at(i)
			break
	_say("The page refused %s: %s." % [result.get("prop", "?"), result.get("error", "error")])


# ---------------------------------------------------------------- reading the selection

## Index into selection.rules that a change to `prop` goes to, or -1 when no editable rule exists.
func choose_rule(prop: String) -> int:
	if selection.is_empty():
		return -1
	var rules: Array = selection.rules
	if target_rule >= 0 and target_rule < rules.size():
		return target_rule if str(rules[target_rule].get("file", "")) != "" else -1
	var winner: int = int(selection.targets.get(prop, -1))
	if winner >= 0 and str(rules[winner].get("file", "")) != "":
		return winner
	var fallback: int = int(selection.get("fallback", -1))
	return fallback if fallback >= 0 and str(rules[fallback].get("file", "")) != "" else -1


## {"text": String, "declared": bool}: what the property is in the rule it would edit (or the computed value).
func current_value(prop: String) -> Dictionary:
	for entry: Dictionary in pending:
		var rule_index := choose_rule(prop)
		if rule_index >= 0 and entry.prop == prop and _same_rule(entry, selection.rules[rule_index]):
			return {"text": entry.new, "declared": true}
	var index := choose_rule(prop)
	if index >= 0 and selection.rules[index].declared.has(prop):
		return {"text": str(selection.rules[index].declared[prop].value), "declared": true}
	return {"text": str(selection.get("computed", {}).get(prop, "")), "declared": false}


## One line describing where a change to `prop` would be written.
func target_description(prop: String) -> String:
	var index := choose_rule(prop)
	if index < 0:
		return "No stylesheet rule to edit (styles of this element are inline or in a <style> block)."
	var rule: Dictionary = selection.rules[index]
	var conditions: Array = rule.get("conditions", [])
	return "%s  in %s%s" % [rule.selector, rule.file, ("  (" + ", ".join(conditions) + ")") if not conditions.is_empty() else ""]


# ---------------------------------------------------------------- editing

## Applies a change to the page now and remembers it as unsaved. Returns false (with `status` set) if it cannot be made.
func set_property(prop: String, value: String) -> bool:
	var new_value := value.strip_edges()
	var index := choose_rule(prop)
	if index < 0:
		_say(target_description(prop))
		return false
	var rule: Dictionary = selection.rules[index]
	var path := _ints(rule.path)
	var old_value := ""
	if rule.declared.has(prop):
		old_value = str(rule.declared[prop].value)
	var entry := {"file": rule.file, "path": path, "selector": rule.selector, "prop": prop, "old": old_value, "new": new_value}
	var existing := _find_entry(entry)
	if existing >= 0:
		entry.old = pending[existing].old  # the value from before the first change is what Undo restores
		pending.remove_at(existing)
	if new_value == "":
		if existing >= 0:
			pending.insert(existing, {"file": entry.file, "path": entry.path, "selector": entry.selector, "prop": prop, "old": entry.old, "new": entry["new"]})
		_say("Empty value ignored. Use Undo to remove a change.")
		return false
	if new_value == entry.old:  # back to the original: nothing left to save for this property
		send.call("apply", _apply_payload(entry, entry.old))
		_say("Reverted %s." % prop)
		changed.emit()
		return true
	pending.append(entry)
	send.call("apply", _apply_payload(entry, new_value))
	_say("%d unsaved change%s." % [pending.size(), "" if pending.size() == 1 else "s"])
	changed.emit()
	return true


func undo() -> void:
	if not pending.is_empty():
		var entry: Dictionary = pending.pop_back()
		send.call("apply", _apply_payload(entry, entry.old))  # "" removes a declaration the change had added
		_say("Undid %s." % entry.prop)
		changed.emit()
		return
	if _last_save.is_empty():
		return
	var problems := PackedStringArray()
	for file: String in _last_save.files:
		var record: Dictionary = _last_save.files[file]
		var full := _full_path(file)
		var now := WebUICssPatcher.read_file(full)
		if not now.ok or now.hash != record.hash:
			problems.append("%s changed since it was saved" % file)
	if not problems.is_empty():
		_say("Cannot undo the save: %s." % ", ".join(problems))
		return
	for file: String in _last_save.files:
		var record: Dictionary = _last_save.files[file]
		WebUICssPatcher.write_file_atomic(_full_path(file), record.text)
		_hashes[file] = String(record.text).sha256_text()
	var count: int = _last_save.count
	_last_save = {}
	send.call("reload", {})
	_say("Undid the last save (%d change%s)." % [count, "" if count == 1 else "s"])
	changed.emit()


## Writes every unsaved change into its stylesheet. Returns {"ok": bool, "saved": int, "error": String}.
func save() -> Dictionary:
	if pending.is_empty():
		return {"ok": true, "saved": 0, "error": ""}
	send.call("hold", {})
	var record := {}
	var saved := 0
	var error := ""
	while not pending.is_empty():
		var entry: Dictionary = pending[0]
		var full := _full_path(entry.file)
		if full.is_empty():
			error = "%s is outside the UI folder." % entry.file
			break
		if not record.has(entry.file):
			var before := WebUICssPatcher.read_file(full)
			if before.ok:
				record[entry.file] = {"text": before.text, "hash": before.hash}
		var value: String = entry.new
		var result := WebUICssPatcher.patch_file(full, _hashes.get(entry.file, ""), entry.path, entry.selector, entry.prop, value)
		if not result.ok:
			error = "%s: %s" % [entry.prop, result.error]
			break
		_hashes[entry.file] = result.hash
		record[entry.file].hash = result.hash
		pending.pop_front()
		saved += 1
	if saved > 0:
		_last_save = {"files": record, "count": saved}
	send.call("synced", {})  # the page already shows what was written
	if error.is_empty():
		_say("Saved %d change%s." % [saved, "" if saved == 1 else "s"])
	else:
		_say("Saved %d, then stopped: %s" % [saved, error])
	changed.emit()
	return {"ok": error.is_empty(), "saved": saved, "error": error}


func set_selecting(on: bool) -> void:
	send.call("enable", {"on": on})


func select_selector(selector: String) -> void:
	send.call("select", {"selector": selector})


func reload() -> void:
	send.call("reload", {})


# ---------------------------------------------------------------- helpers

func _apply_payload(entry: Dictionary, value: String) -> Dictionary:
	return {"file": entry.file, "path": entry.path, "selector": entry.selector, "prop": entry.prop, "value": value}


func _find_entry(probe: Dictionary) -> int:
	for i in range(pending.size()):
		var entry: Dictionary = pending[i]
		if entry.prop == probe.prop and entry.file == probe.file and str(entry.path) == str(probe.path):
			return i
	return -1


func _same_rule(entry: Dictionary, rule: Dictionary) -> bool:
	return entry.file == rule.file and str(entry.path) == str(_ints(rule.path))


static func _ints(values: Array) -> Array:
	var out: Array = []
	for v: Variant in values:
		out.append(int(v))
	return out


## res:// path of a stylesheet the page reported (relative to the page's folder), or "" if it escapes the UI folder.
func _full_path(file: String) -> String:
	var full := ui_dir.path_join(page.get_base_dir()).path_join(file).simplify_path()
	return full if full.begins_with(ui_dir.simplify_path()) else ""


## Remember the stylesheets as the page loaded them, so a save can tell if they changed since.
func _snapshot() -> void:
	_hashes.clear()
	var base := ui_dir.path_join(page.get_base_dir()).simplify_path()
	_scan_css(base, "")


func _scan_css(base: String, relative: String) -> void:
	var dir := base.path_join(relative) if not relative.is_empty() else base
	for file_name in DirAccess.get_files_at(dir):
		if file_name.get_extension().to_lower() == "css":
			var key := relative.path_join(file_name) if not relative.is_empty() else file_name
			var state := WebUICssPatcher.read_file(base.path_join(key))
			if state.ok:
				_hashes[key] = state.hash
	for sub in DirAccess.get_directories_at(dir):
		if not sub.begins_with("."):
			_scan_css(base, relative.path_join(sub) if not relative.is_empty() else sub)


func _say(text: String) -> void:
	status = text
	changed.emit()
