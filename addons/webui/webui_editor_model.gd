@tool
class_name WebUIEditorModel
extends RefCounted
## The logic behind the visual editor dock, with no UI and no editor classes so it can be tested.
##
## It follows one page in the edit preview. The page reports the selected element: what it is, its
## attributes and text, computed style, the stylesheet rules that apply to it, what is inherited. From
## that the model works out, for every property, where its value comes from and whether and how it can
## be changed: which rule a change goes to (never a rule that would silently lose to another one),
## whether that rule is shared with other elements, and what an element-only change would look like.
## Changes are applied to the page at once (the page verifies that they take effect), kept as unsaved
## changes (so they can be undone and replayed after a reload), and saved by patching the source files
## in place: stylesheets with WebUICssPatcher, the HTML file with WebUIHtmlPatcher.
##
## `send` is called as send(op: String, payload: Dictionary) for every command to the preview
## (config / apply / add_rule / remove_rule / apply_text / apply_attr / select / enable go to the page;
## hold / synced / reload / page to the preview itself).

signal changed

const KIND_RANK_IMPORTANT := 1000000000.0

var send := Callable()
var ui_dir := ""
var page := ""
var status := ""
var preview_ready := false
var selection: Dictionary = {}
## -1 = automatic; >= 0 an index into selection.rules; -2 = this element only (a new #id rule).
var target_rule := -1
## Unsaved changes, oldest first. Every entry has a "kind":
##   decl      {file, path, selector, prop, write, old, new, important}   `old` is "" when the rule did not declare it
##   new_rule  {file, selector, decls: {key: value}, path}                a rule that does not exist in the file yet
##   text      {file, element, old, new}                                  the element's own text, in the HTML file
##   attr      {file, element, id, name, old, new}                        an attribute (old null = absent)
var pending: Array = []

var _hashes := {}          # file (relative to the page's folder) -> hash when the page loaded
var _last_save := {}       # {"files": {file: {"text": before, "hash": after}}, "count": n}
var _sources := {}         # file -> {"text", "rules"} for the current selection
var _attempt := {}         # the change being tried: {prop, value, plans, index}
var _config_sent := false

## Sample game state for the page, as JSON text: {"states": {name: {...}}, "events": [{"name", "payload"}]}.
## The preview has no game behind it, so pages show their placeholders; this is what they are shown with
## instead. It is kept next to the page in a hidden folder (.webui-edit), which is never exported.
var sample_text := ""
var sample_error := ""


func open_page(new_ui_dir: String, new_page: String) -> void:
	ui_dir = new_ui_dir
	page = new_page
	selection = {}
	pending.clear()
	_hashes.clear()
	_sources.clear()
	_last_save = {}
	_attempt = {}
	preview_ready = false
	target_rule = -1
	_load_sample()
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
			_sources.clear()
			if target_rule >= selection.rules.size():
				target_rule = -1
			changed.emit()
		"cleared":
			selection = {}
			changed.emit()
		"apply_result":
			_on_apply_result(payload)
		"rule_result":
			_on_rule_result(payload)
		"content_result":
			if not payload.get("ok", false):
				_say("The page could not apply that change (%s)." % payload.get("error", "error"))
		"preview_opened":
			if payload.get("ui_dir") != ui_dir or payload.get("page") != page:
				preview_ready = false
				_say("The preview is showing %s, not %s. Close the preview window and press Open preview again." % [payload.get("page", "?"), page])
		"preview_error":
			preview_ready = false
			_say("Preview problem (%s): %s" % [payload.get("code", "?"), payload.get("text", "")])


func _on_ready() -> void:
	preview_ready = true
	_sources.clear()
	_snapshot()
	send.call("config", {"props": WebUICssCatalog.property_config()})
	_config_sent = true
	_push_sample()
	for entry: Dictionary in pending.duplicate():  # the page reloaded: show the unsaved changes again
		_replay(entry)
	var remembered: String = selection.get("selector", "")
	selection = {}
	if not remembered.is_empty():
		send.call("select", {"selector": remembered})
	_say("Ready. Click an element in the preview." if remembered.is_empty() else "Reloaded.")


func _replay(entry: Dictionary) -> void:
	match entry.kind:
		"decl":
			send.call("apply", _apply_payload(entry, entry.new))
		"new_rule":
			send.call("add_rule", {"file": entry.file, "selector": entry.selector, "decls": entry.decls, "important": false})
		"text":
			send.call("apply_text", {"text": entry.new, "selector": entry.element})
		"attr":
			send.call("select", {"selector": entry.element})
			send.call("apply_attr", {"name": entry.name, "value": entry.new})


func _on_apply_result(result: Dictionary) -> void:
	if result.get("ok", false):
		_attempt = {}
		return
	var prop: String = result.get("prop", "")
	_remove_decl_entry(result.get("file", ""), _ints(result.get("path", [])), prop)
	if result.get("error") == "ineffective" and not _attempt.is_empty() and _attempt.prop == prop:
		_attempt.blocker = result.get("blocker", "")
		_attempt.index += 1
		if _attempt.index < _attempt.plans.size():
			_run_plan(_attempt.prop, _attempt.value, _attempt.plans[_attempt.index])
			return
	_fail_change(prop, result)


func _on_rule_result(result: Dictionary) -> void:
	if result.get("kind") == "remove":
		return
	if result.get("ok", false):
		for entry: Dictionary in pending:
			if entry.kind == "new_rule" and entry.file == result.file and entry.selector == result.selector and entry.get("path", []).is_empty():
				entry["path"] = _ints(result.get("path", []))
		_attempt = {}
		return
	for i in range(pending.size() - 1, -1, -1):
		if pending[i].kind == "new_rule" and pending[i].file == result.get("file") and pending[i].selector == result.get("selector") and pending[i].get("path", []).is_empty():
			pending.remove_at(i)
			break
	var prop: String = result.get("prop", _attempt.get("prop", ""))
	if result.get("error") == "ineffective" and not _attempt.is_empty() and _attempt.prop == prop:
		_attempt.blocker = result.get("blocker", "")
		_attempt.index += 1
		if _attempt.index < _attempt.plans.size():
			_run_plan(_attempt.prop, _attempt.value, _attempt.plans[_attempt.index])
			return
	_fail_change(prop, result)


func _fail_change(prop: String, result: Dictionary) -> void:
	var label: String = WebUICssCatalog.spec(prop).get("label", prop)
	var blocker: String = _attempt.get("blocker", result.get("blocker", ""))
	match result.get("error", ""):
		"ineffective":
			_say("%s would have no effect: it is overridden by %s." % [label, blocker if blocker != "" else "a more specific rule"])
		"invalid_value":
			_say("%s: that is not a valid CSS value." % label)
		"selector_mismatch", "rule_not_found", "sheet_not_found":
			_say("The page and the stylesheet are out of step. Press Reload and try again.")
		_:
			_say("The page refused %s (%s)." % [label, result.get("error", "error")])
	_attempt = {}
	changed.emit()


# ---------------------------------------------------------------- understanding the selection

## Sections to show for the selection: [{"id", "title", "collapsed", "note", "rows": [row]}], where a row is
## {"type": "prop"|"sides"|"text"|"attr"|"info", ...}. Empty when nothing is selected.
func inspector() -> Array:
	if selection.is_empty():
		return []
	var out: Array = []
	for section: Dictionary in WebUICssCatalog.sections_for(selection):
		var rows: Array = []
		if section.id == "content":
			rows = _content_rows()
			if rows.is_empty():
				continue
		for key: String in section.props:
			if WebUICssCatalog.spec(key).is_empty():
				continue
			if WebUICssCatalog.spec(key).kind == "sides":
				rows.append({"type": "sides", "key": key, "label": WebUICssCatalog.spec(key).label, "sides": WebUICssCatalog.expand(key).map(func(side: String) -> Dictionary: return describe(side))})
			else:
				rows.append(describe(key))
		out.append({"id": section.id, "title": section.title, "collapsed": section.collapsed, "note": section.get("note", ""), "rows": rows})
	return out


## Everything the dock shows and decides for one property: {"type": "prop", "key", "label", "kind", "options",
## "hint", "text" (what to show in the field), "computed", "state" (rule | inherited | inline | external |
## default), "source" (where the value comes from), "editable", "reason" (why not), "shared" (how many elements
## the rule to be edited affects), "note", "unsaved"}.
func describe(key: String) -> Dictionary:
	var spec := WebUICssCatalog.spec(key)
	var row := {
		"type": "prop", "key": key, "label": spec.get("label", key), "kind": spec.get("kind", "text"),
		"options": spec.get("options", []), "hint": spec.get("hint", ""), "text": "", "computed": "", "state": "default",
		"source": "", "editable": false, "reason": "", "shared": 0, "note": "", "unsaved": false,
	}
	if selection.is_empty() or spec.is_empty():
		row.reason = "Nothing selected."
		return row
	row.computed = str(selection.get("computed", {}).get(key, ""))
	row.text = row.computed
	var state := _resolve(key)
	row.state = state.state
	if state.state == "rule":
		var winner: Dictionary = state.rule
		row.source = "%s  in %s%s" % [winner.selector, winner.file, _conditions_text(winner)]
		var decl: Dictionary = state.decl
		if decl.get("text", "") != "":
			var shorthand: bool = WebUICssCatalog.is_shorthand_for(decl.name, key)
			row.text = row.computed if shorthand else decl.text
			if shorthand:
				row.note = "Set by the shorthand `%s: %s`." % [decl.name, decl.text]
			elif decl.text.contains("var(--"):
				row.note = "Uses %s." % _vars_text(decl.text)
			elif decl.text in ["inherit", "initial", "unset", "revert"]:
				row.note = "Set to `%s`; the shown value is what that gives here." % decl.text
				row.text = decl.text
	elif state.state == "inherited":
		var from: Dictionary = selection.inherited[key]
		row.source = "inherited from %s%s" % [from.get("selector", from.get("tag", "a parent")), " (%s)" % from.file if str(from.get("file", "")) != "" else ""]
	elif state.state == "inline":
		row.source = "the element's style attribute"
		row.text = str(state.inline.value)
	elif state.state == "external":
		row.source = "%s (a <style> block)" % state.rule.selector
	else:
		row.source = "browser default"
	var plan := _plans(key)
	row.editable = not plan.plans.is_empty()
	row.reason = plan.reason
	row.shared = plan.get("shared", 0)
	if plan.get("warn", "") != "":
		row.note = (row.note + " " if row.note != "" else "") + plan.warn
	for entry: Dictionary in pending:
		if entry.kind == "decl" and entry.prop == key and _entry_applies(entry):
			row.text = entry.new
			row.unsaved = true
		elif entry.kind == "new_rule" and entry.decls.has(key) and _entry_applies(entry):
			row.text = str(entry.decls[key])
			row.unsaved = true
	return row


## Where the value of `key` on the selected element comes from.
func _resolve(key: String) -> Dictionary:
	var names := WebUICssCatalog.covers(key)
	var best := {}
	var best_rank := -1.0
	for i in range(selection.rules.size()):
		var rule: Dictionary = selection.rules[i]
		var decl := _declaration_in(rule, names)
		if decl.is_empty():
			continue
		var rank := (KIND_RANK_IMPORTANT if decl.important else 0.0) + float(rule.specificity) * 1000.0 + float(rule.order)
		if rank > best_rank:
			best_rank = rank
			best = {"rule": rule, "index": i, "decl": decl}
	var inline_decl := {}
	for name: String in names:
		if selection.get("inline", {}).has(name):
			inline_decl = selection.inline[name]
	if not inline_decl.is_empty() and (inline_decl.important or best.is_empty() or not best.decl.important):
		return {"state": "inline", "inline": inline_decl}
	if not best.is_empty():
		var rule: Dictionary = best.rule
		if str(rule.file) == "" or best.decl.get("external", false):
			return {"state": "external", "rule": rule, "index": best.index}
		return {"state": "rule", "rule": rule, "index": best.index, "decl": best.decl}
	if selection.get("inherited", {}).has(key):
		return {"state": "inherited"}
	return {"state": "default"}


## The last declaration in the rule that sets one of `names`: {name, text, important, external}. For rules that
## are not in the files only the names the page saw are known ("external").
func _declaration_in(rule: Dictionary, names: PackedStringArray) -> Dictionary:
	if str(rule.file) == "" or _is_unsaved_rule(rule):
		for name: String in names:
			if rule.declared.has(name):
				return {"name": name, "text": "", "important": bool(rule.declared[name]), "external": str(rule.file) == ""}
		return {}
	var source := _source_rule(rule)
	if source.is_empty():
		for name: String in names:
			if rule.declared.has(name):
				return {"name": name, "text": "", "important": bool(rule.declared[name]), "external": true}
		return {}
	var text: String = _sources[rule.file].text
	var found := {}
	for decl: Dictionary in source.decls:
		if names.has(decl.name):
			found = {"name": decl.name, "text": text.substr(decl.value_start, decl.value_end - decl.value_start), "important": decl.important, "external": false}
	return found


## The parsed source rule for a rule the page reported, or {} when it is not in the file (or differs).
func _source_rule(rule: Dictionary) -> Dictionary:
	var file: String = rule.file
	if file == "":
		return {}
	if not _sources.has(file):
		var full := _full_path(file)
		var state := WebUICssPatcher.read_file(full) if full != "" else {"ok": false}
		_sources[file] = {"text": state.text, "rules": WebUICssPatcher.parse(state.text)} if state.ok else {"text": "", "rules": []}
	var found := WebUICssPatcher.find_rule(_sources[file].rules, _ints(rule.path))
	return found if WebUICssPatcher.selector_matches(found, rule.selector) and not found.nested else {}


func _is_unsaved_rule(rule: Dictionary) -> bool:
	return _pending_rule_for(rule.file, _ints(rule.path)) >= 0


func _pending_rule_for(file: String, path: Array) -> int:
	for i in range(pending.size()):
		var entry: Dictionary = pending[i]
		if entry.kind == "new_rule" and entry.file == file and str(entry.get("path", [])) == str(path):
			return i
	return -1


func _entry_applies(entry: Dictionary) -> bool:
	for rule: Dictionary in selection.rules:
		if rule.file == entry.file and (entry.kind == "decl" and str(_ints(rule.path)) == str(entry.path) or entry.kind == "new_rule" and str(_ints(rule.path)) == str(entry.get("path", []))):
			return true
	return false


# ---------------------------------------------------------------- planning a change

## How a change to `key` could be made, best first: {"plans": [...], "reason": String, "shared": int, "warn": String}.
## A plan is {"kind": "decl" | "new_rule", "file", "path", "selector", "important", "existing": bool, "shared": int, "rule": index}.
func _plans(key: String) -> Dictionary:
	var out := {"plans": [], "reason": "", "shared": 0, "warn": ""}
	var state := _resolve(key)
	if state.state == "inline":
		out.reason = "Set by the element's style attribute in the HTML; edit or remove it there."
		return out
	if state.state == "external":
		out.reason = "Set by a rule in a <style> block of the page (%s), which the editor cannot change yet." % state.rule.selector
		return out
	var names := WebUICssCatalog.covers(key)
	var important: bool = state.state == "rule" and state.decl.important
	var plans: Array = []

	if target_rule == -2:
		var element_plan := _element_plan(key, important)
		if element_plan.is_empty():
			out.reason = "This element has no unique id, so an element-only rule cannot be written."
		else:
			out.plans = [element_plan]
		return out
	if target_rule >= 0:
		var forced := _rule_plan(target_rule, key, names, important)
		if forced.is_empty():
			out.reason = "The chosen rule is not an editable rule in a stylesheet file."
		else:
			out.plans = [forced]
			out.shared = forced.shared
			out.warn = _shared_warning(forced)
		return out

	# Automatic. Candidates are the editable rules matching the element, narrowest first.
	var editable: Array = []
	for i in range(selection.rules.size()):
		var plan := _rule_plan(i, key, names, important)
		if not plan.is_empty():
			editable.append(plan)
	editable.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ak: int = a.shared if a.shared > 0 else 1000000
		var bk: int = b.shared if b.shared > 0 else 1000000
		if ak != bk:
			return ak < bk
		return selection.rules[a.rule].specificity > selection.rules[b.rule].specificity)
	# A rule inside @media would take the change only at that size, so it is a candidate only when it is the
	# rule that sets the value now (below).
	var narrow: Array = editable.filter(func(p: Dictionary) -> bool: return p.shared == 1 and selection.rules[p.rule].get("conditions", []).is_empty())
	# The rule that sets the value now comes first if it is not shared.
	if state.state == "rule" and state.index < selection.rules.size():
		var winner_plan := _rule_plan(state.index, key, names, important)
		if not winner_plan.is_empty() and winner_plan.shared == 1:
			plans.append(winner_plan)
	for plan: Dictionary in narrow:
		if not plans.any(func(p: Dictionary) -> bool: return p.rule == plan.rule):
			plans.append(plan)
	var element_plan := _element_plan(key, important)
	if not element_plan.is_empty():
		plans.append(element_plan)
	if plans.is_empty():  # only shared rules are left: use the least shared one and say so
		plans = editable
		if not plans.is_empty():
			out.warn = _shared_warning(plans[0])
	if plans.is_empty():
		out.reason = "No stylesheet rule in a file matches this element, and it has no unique id to write an element-only rule for."
		return out
	out.plans = plans
	out.shared = plans[0].shared
	if out.warn == "":
		out.warn = _shared_warning(plans[0])
	return out


func _rule_plan(index: int, key: String, names: PackedStringArray, important: bool) -> Dictionary:
	if index < 0 or index >= selection.rules.size():
		return {}
	var rule: Dictionary = selection.rules[index]
	if str(rule.file) == "":
		return {}
	var unsaved := _pending_rule_for(rule.file, _ints(rule.path))
	var existing := false
	if unsaved < 0:
		var source := _source_rule(rule)
		if source.is_empty():
			return {}
		var write := WebUICssCatalog.write_name(key)
		for decl: Dictionary in source.decls:
			if decl.name == write:
				existing = true
	return {"kind": "decl", "file": rule.file, "path": _ints(rule.path), "selector": rule.selector, "important": important, "existing": existing, "shared": int(rule.affects), "rule": index, "unsaved_rule": unsaved >= 0}


func _element_plan(key: String, important: bool) -> Dictionary:
	if not selection.get("id_unique", false):
		return {}
	var selector := "#" + str(selection.id)
	# An element-only rule that is already pending (or exists) is reused.
	for i in range(selection.rules.size()):
		var rule: Dictionary = selection.rules[i]
		if rule.selector == selector and str(rule.file) != "":
			var plan := _rule_plan(i, key, WebUICssCatalog.covers(key), important)
			if not plan.is_empty():
				return plan
	var file := _stylesheet_for_new_rule()
	if file == "":
		return {}
	return {"kind": "new_rule", "file": file, "selector": selector, "important": important, "shared": 1, "rule": -2}


## The stylesheet a new rule goes into: the file of the most specific rule that matches the element.
func _stylesheet_for_new_rule() -> String:
	var best_file := ""
	var best := -1.0
	for rule: Dictionary in selection.rules:
		if str(rule.file) != "" and float(rule.specificity) * 1000.0 + float(rule.order) > best:
			best = float(rule.specificity) * 1000.0 + float(rule.order)
			best_file = rule.file
	if best_file == "" and not selection.get("sheets", []).is_empty():
		best_file = selection.sheets[0].file
	return best_file


func _shared_warning(plan: Dictionary) -> String:
	if plan.get("kind") != "decl" or int(plan.shared) <= 1:
		return ""
	var rule: Dictionary = selection.rules[plan.rule]
	return "Changes %s, used by %d elements." % [rule.selector, plan.shared]


# ---------------------------------------------------------------- editing

## Changes `key` on the selected element: applies it to the page at once and remembers it as unsaved.
## Returns false (with `status` set) when it cannot be done.
func set_property(key: String, value: String) -> bool:
	var new_value := _normalize_value(key, value)
	if selection.is_empty():
		_say("Select an element in the preview first.")
		return false
	if new_value == "":
		_say("Empty value ignored. Use Undo to take a change back.")
		return false
	var plan := _plans(key)
	if plan.plans.is_empty():
		_say(plan.reason)
		return false
	_attempt = {"prop": key, "value": new_value, "plans": plan.plans, "index": 0, "blocker": ""}
	_run_plan(key, new_value, plan.plans[0])
	return true


func _run_plan(key: String, value: String, plan: Dictionary) -> void:
	if plan.kind == "new_rule":
		_run_new_rule(key, value, plan)
		return
	var write := WebUICssCatalog.write_name(key)
	var old_value := ""
	if plan.existing:
		var rule: Dictionary = selection.rules[plan.rule]
		var decl := _declaration_in(rule, PackedStringArray([write]))
		old_value = decl.get("text", "")
	var entry := {"kind": "decl", "file": plan.file, "path": plan.path, "selector": plan.selector, "prop": key, "write": write, "old": old_value, "new": value, "important": plan.important}
	if plan.get("unsaved_rule", false):
		var rule_index := _pending_rule_for(plan.file, plan.path)
		pending[rule_index].decls[key] = value  # an edit of a rule that exists only in the page so far
		send.call("apply", _apply_payload(entry, value))
		_say("%d unsaved change%s." % [pending.size(), "" if pending.size() == 1 else "s"])
		changed.emit()
		return
	var existing := _find_decl_entry(entry.file, entry.path, key)
	if existing >= 0:
		entry.old = pending[existing].old  # what Undo restores is the value from before the first change
		pending.remove_at(existing)
	if value == entry.old and entry.old != "":
		send.call("apply", _apply_payload(entry, entry.old))  # back to the original: nothing left to save
		_say("Reverted %s." % WebUICssCatalog.spec(key).get("label", key))
		changed.emit()
		return
	pending.append(entry)
	send.call("apply", _apply_payload(entry, value))
	var warn: String = _shared_warning(plan)
	_say("%d unsaved change%s.%s" % [pending.size(), "" if pending.size() == 1 else "s", " " + warn if warn != "" else ""])
	changed.emit()


func _run_new_rule(key: String, value: String, plan: Dictionary) -> void:
	var write := WebUICssCatalog.write_name(key)
	for entry: Dictionary in pending:  # add to the element-only rule that is already pending
		if entry.kind == "new_rule" and entry.file == plan.file and entry.selector == plan.selector and not entry.get("path", []).is_empty():
			entry.decls[key] = value
			send.call("apply", {"file": entry.file, "path": entry.path, "selector": entry.selector, "prop": key, "value": value, "important": plan.important})
			_say("%d unsaved change%s." % [pending.size(), "" if pending.size() == 1 else "s"])
			changed.emit()
			return
	pending.append({"kind": "new_rule", "file": plan.file, "selector": plan.selector, "decls": {key: value}, "path": [], "important": plan.important})
	send.call("add_rule", {"file": plan.file, "selector": plan.selector, "decls": {key: value}, "important": plan.important})
	_say("%d unsaved change%s. Applies to this element only (%s)." % [pending.size(), "" if pending.size() == 1 else "s", plan.selector])
	changed.emit()


## Content of the selected element that can be edited in the HTML file: {"text": {...}, "attrs": [...]}.
func content_state() -> Dictionary:
	var out := {"text": {"value": "", "editable": false, "reason": "", "shown": false}, "texts": [], "attrs": []}
	if selection.is_empty():
		return out
	var kind: String = selection.get("kind", "")
	if kind in ["text", "button", "link", "container"]:
		var html := _page_html()
		var text_state: Dictionary = out.text
		text_state.shown = selection.text != "" or kind == "text"
		text_state.value = selection.text
		var own := _text_check(selection.text, selection.get("text_editable", false), selection.get("text_unique", false), selection.get("text_mixed", false), html)
		text_state.editable = own.editable
		text_state.reason = own.reason
		# Text that sits in elements inside this one (the <b>Play</b> of a button) is edited from here too.
		for inner: Dictionary in selection.get("texts", []):
			var check := _text_check(inner.text, true, inner.get("unique", false), false, html)
			out.texts.append({"selector": inner.selector, "tag": inner.tag, "value": inner.text, "editable": check.editable, "reason": check.reason})
	var attr_names: Array = []
	match kind:
		"image", "media":
			attr_names = ["src", "alt", "title"]
		"input":
			attr_names = ["type", "placeholder", "value", "title"]
		"button":
			attr_names = ["title", "aria-label"]
		"link":
			attr_names = ["href", "title"]
	var html_text := _page_html()
	for name: String in attr_names:
		var present: bool = selection.get("attrs", {}).has(name)
		var editable: bool = name in WebUICssCatalog.EDITABLE_ATTRIBUTES
		var reason := ""
		if not editable:
			reason = "Shown for information; change it in the HTML."
		elif not selection.get("id_unique", false):
			editable = false
			reason = "This element has no unique id, so its tag cannot be found safely in the HTML."
		elif html_text == "":
			editable = false
			reason = "The page's HTML file could not be read."
		else:
			var probe := WebUIHtmlPatcher.set_attribute(html_text, selection.id, name, str(selection.attrs.get(name, "")))
			editable = probe.ok
			reason = "" if probe.ok else probe.error
		out.attrs.append({"name": name, "value": str(selection.get("attrs", {}).get(name, "")), "present": present, "editable": editable, "reason": reason})
	return out


## Whether text can be edited in the HTML, and if not, why: {"editable", "reason"}.
func _text_check(text: String, editable_in_page: bool, unique_in_page: bool, mixed: bool, html: String) -> Dictionary:
	if not editable_in_page:
		return {"editable": false, "reason": "This element has several separate pieces of text; edit them where they sit." if mixed else "This element has no text of its own."}
	if not unique_in_page:
		return {"editable": false, "reason": "The same text appears in several elements of the page, so the right one in the HTML cannot be told apart."}
	if html == "":
		return {"editable": false, "reason": "The page's HTML file could not be read."}
	var probe := WebUIHtmlPatcher.replace_text(html, text, text)
	if not probe.ok and probe.code == "text_not_found":
		return {"editable": false, "reason": "This text is not in the HTML file: the page's script (or the sample state) puts it there, so change it in the script or in Godot. Its look can still be edited."}
	return {"editable": probe.ok, "reason": "" if probe.ok else probe.error}


## Changes text (in the page now, in the HTML file on Save): the selected element's own text, or with
## `element` (a selector from content_state().texts) the text of an element inside it.
func set_text(new_text: String, element := "") -> bool:
	var content := content_state()
	var info: Dictionary = content.text
	var target: String = selection.get("selector", "")
	var old_text: String = selection.get("text", "")
	if element != "":
		info = {"editable": false, "reason": "That text is not part of the selected element."}
		for inner: Dictionary in content.texts:
			if inner.selector == element:
				info = inner
				target = element
				old_text = inner.value
	if not info.editable:
		_say(info.reason if info.reason != "" else "This element's text cannot be edited.")
		return false
	var text := new_text.strip_edges()
	if text == "":
		_say("The text cannot be empty.")
		return false
	var existing := -1
	for i in range(pending.size()):
		if pending[i].kind == "text" and pending[i].element == target:
			existing = i
	if existing >= 0:
		old_text = pending[existing].old
		pending.remove_at(existing)
	if text != old_text:
		pending.append({"kind": "text", "file": page.get_file(), "element": target, "old": old_text, "new": text})
	send.call("apply_text", {"text": text, "selector": target})
	_say("%d unsaved change%s." % [pending.size(), "" if pending.size() == 1 else "s"])
	changed.emit()
	return true


## Changes an attribute of the selected element (in the page now, in the HTML file on Save).
func set_attribute(name: String, value: String) -> bool:
	for attr: Dictionary in content_state().attrs:
		if attr.name == name:
			if not attr.editable:
				_say(attr.reason)
				return false
			var existing := -1
			for i in range(pending.size()):
				if pending[i].kind == "attr" and pending[i].element == selection.selector and pending[i].name == name:
					existing = i
			var old: Variant = str(selection.attrs[name]) if selection.attrs.has(name) else null
			if existing >= 0:
				old = pending[existing].old
				pending.remove_at(existing)
			var removing: bool = value.strip_edges() == "" and old == null
			if not removing and str(old) != value.strip_edges():
				pending.append({"kind": "attr", "file": page.get_file(), "element": selection.selector, "id": selection.id, "name": name, "old": old, "new": value.strip_edges()})
			send.call("apply_attr", {"name": name, "value": value.strip_edges() if not removing else null})
			_say("%d unsaved change%s." % [pending.size(), "" if pending.size() == 1 else "s"])
			changed.emit()
			return true
	_say("This attribute cannot be edited here.")
	return false


# ---------------------------------------------------------------- sample state

## Where the sample state of `page_name` (relative to `dir`) is kept.
static func sample_path(dir: String, page_name: String) -> String:
	return dir.path_join(page_name.get_base_dir()).path_join(".webui-edit").path_join(page_name.get_file().get_basename() + ".json")


func _load_sample() -> void:
	sample_text = ""
	sample_error = ""
	var path := sample_path(ui_dir, page)
	if FileAccess.file_exists(path):
		sample_text = FileAccess.get_file_as_string(path)


func _push_sample() -> void:
	var parsed: Variant = JSON.parse_string(sample_text) if sample_text.strip_edges() != "" else null
	if typeof(parsed) == TYPE_DICTIONARY:
		send.call("sample", parsed)


## Checks `text` as sample state, shows it in the page and keeps it in the file next to the page. Empty text
## removes the sample. Returns false (with `sample_error` set) when it is not valid.
func set_sample(text: String) -> bool:
	var path := sample_path(ui_dir, page)
	if text.strip_edges() == "":
		sample_text = ""
		sample_error = ""
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		send.call("sample", {"states": {}, "events": []})
		_say("Sample state removed.")
		return true
	var json := JSON.new()
	if json.parse(text) != OK:
		sample_error = "Not valid JSON (line %d): %s" % [json.get_error_line(), json.get_error_message()]
		_say(sample_error)
		return false
	var parsed: Variant = json.data
	var problem := _sample_problem(parsed)
	if problem != "":
		sample_error = problem
		_say(problem)
		return false
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var gdignore := path.get_base_dir().path_join(".gdignore")
	if not FileAccess.file_exists(gdignore):
		FileAccess.open(gdignore, FileAccess.WRITE).close()  # keeps Godot from importing or exporting the folder
	var pretty := JSON.stringify(parsed, "  ")
	if WebUICssPatcher.write_file_atomic(path, pretty) != OK:
		sample_error = "Could not write %s." % path
		_say(sample_error)
		return false
	sample_text = pretty
	sample_error = ""
	send.call("sample", parsed)
	_say("Sample state applied and saved to %s." % path.trim_prefix(ui_dir.path_join("")))
	return true


static func _sample_problem(parsed: Variant) -> String:
	if typeof(parsed) != TYPE_DICTIONARY:
		return "The sample must be a JSON object like {\"states\": {\"hud\": {...}}, \"events\": []}."
	for key: String in parsed:
		if key not in ["states", "events"]:
			return "Unknown key \"%s\": use \"states\" and \"events\"." % key
	var states: Variant = parsed.get("states", {})
	if typeof(states) != TYPE_DICTIONARY:
		return "\"states\" must be an object of name: {values}."
	for name: String in states:
		if not WebUIBridge.is_valid_name(name):
			return "\"%s\" is not a valid state name." % name
		if typeof(states[name]) != TYPE_DICTIONARY:
			return "State \"%s\" must be an object." % name
	var events: Variant = parsed.get("events", [])
	if typeof(events) != TYPE_ARRAY:
		return "\"events\" must be a list of {\"name\", \"payload\"}."
	for event: Variant in events:
		if typeof(event) != TYPE_DICTIONARY or typeof(event.get("name")) != TYPE_STRING or not WebUIBridge.is_valid_name(event.name):
			return "Every event needs a valid \"name\"."
		if event.has("payload") and typeof(event.payload) != TYPE_DICTIONARY:
			return "The payload of event \"%s\" must be an object." % event.name
	return ""


## A starting point: the state and event names the page's scripts listen for, with empty values to fill in.
func sample_template() -> String:
	var names := _listened_names()
	var states := {}
	for name: String in names.states:
		states[name] = {}
	var events: Array = []
	for name: String in names.events:
		events.append({"name": name, "payload": {}})
	return JSON.stringify({"states": states, "events": events}, "  ")


## Names the page listens for: Godot.on / onState / onEvent in its HTML and the scripts in its folder.
func _listened_names() -> Dictionary:
	var out := {"states": PackedStringArray(), "events": PackedStringArray()}
	var base := ui_dir.path_join(page.get_base_dir()).simplify_path()
	var sources: Array = [_page_html()]
	_collect_scripts(base, sources)
	var states_rx := RegEx.create_from_string("Godot\\s*\\.\\s*(?:onState|on)\\s*\\(\\s*['\"]([^'\"]+)['\"]")
	var events_rx := RegEx.create_from_string("Godot\\s*\\.\\s*onEvent\\s*\\(\\s*['\"]([^'\"]+)['\"]")
	for source: String in sources:
		for m in states_rx.search_all(source):
			if WebUIBridge.is_valid_name(m.get_string(1)) and not out.states.has(m.get_string(1)):
				out.states.append(m.get_string(1))
		for m in events_rx.search_all(source):
			if WebUIBridge.is_valid_name(m.get_string(1)) and not out.events.has(m.get_string(1)):
				out.events.append(m.get_string(1))
	return out


func _collect_scripts(dir: String, into: Array) -> void:
	for file_name in DirAccess.get_files_at(dir):
		if file_name.get_extension().to_lower() == "js":
			into.append(FileAccess.get_file_as_string(dir.path_join(file_name)))
	for sub in DirAccess.get_directories_at(dir):
		if not sub.begins_with("."):
			_collect_scripts(dir.path_join(sub), into)


# ---------------------------------------------------------------- undo and save

func undo() -> void:
	if not pending.is_empty():
		var entry: Dictionary = pending.pop_back()
		match entry.kind:
			"decl":
				send.call("apply", _apply_payload(entry, entry.old))  # "" removes a declaration the change had added
				_say("Undid %s." % WebUICssCatalog.spec(entry.prop).get("label", entry.prop))
			"new_rule":
				if not entry.get("path", []).is_empty():
					send.call("remove_rule", {"file": entry.file, "path": entry.path, "selector": entry.selector})
				_say("Undid the element-only rule %s." % entry.selector)
			"text":
				send.call("apply_text", {"text": entry.old, "selector": entry.element})
				_say("Undid the text change.")
			"attr":
				send.call("select", {"selector": entry.element})
				send.call("apply_attr", {"name": entry.name, "value": entry.old})
				_say("Undid the %s change." % entry.name)
		changed.emit()
		return
	if _last_save.is_empty():
		return
	var problems := PackedStringArray()
	for file: String in _last_save.files:
		var record: Dictionary = _last_save.files[file]
		var now := WebUICssPatcher.read_file(_full_path(file))
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
	_sources.clear()
	send.call("reload", {})
	_say("Undid the last save (%d change%s)." % [count, "" if count == 1 else "s"])
	changed.emit()


## Writes every unsaved change into its file. Returns {"ok": bool, "saved": int, "error": String}.
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
		var result := WebUICssPatcher.edit_file(full, _hashes.get(entry.file, ""), _transform_for(entry))
		if not result.ok:
			error = "%s: %s" % [_entry_label(entry), result.error]
			break
		_hashes[entry.file] = result.hash
		record[entry.file].hash = result.hash
		pending.pop_front()
		saved += 1
	if saved > 0:
		_last_save = {"files": record, "count": saved}
	_sources.clear()
	send.call("synced", {})  # the page already shows what was written
	if error.is_empty():
		_say("Saved %d change%s." % [saved, "" if saved == 1 else "s"])
	else:
		_say("Saved %d, then stopped: %s" % [saved, error])
	changed.emit()
	return {"ok": error.is_empty(), "saved": saved, "error": error}


func _transform_for(entry: Dictionary) -> Callable:
	match entry.kind:
		"decl":
			return func(text: String) -> Dictionary:
				return WebUICssPatcher.set_declaration(text, entry.path, entry.selector, entry.write, entry.new, entry.important)
		"new_rule":
			var decls := {}
			for key: String in entry.decls:
				decls[WebUICssCatalog.write_name(key)] = entry.decls[key]
			if entry.get("important", false):
				for name: String in decls:
					decls[name] = str(decls[name]) + " !important"
			var expected: int = int(entry.path[0]) if not entry.get("path", []).is_empty() else -1
			return func(text: String) -> Dictionary:
				return WebUICssPatcher.append_rule(text, entry.selector, decls, expected)
		"text":
			return func(text: String) -> Dictionary:
				return WebUIHtmlPatcher.replace_text(text, entry.old, entry.new)
		"attr":
			if entry.new == "" and entry.old == null:
				return func(text: String) -> Dictionary: return WebUIHtmlPatcher.remove_attribute(text, entry.id, entry.name)
			return func(text: String) -> Dictionary:
				return WebUIHtmlPatcher.set_attribute(text, entry.id, entry.name, entry.new)
	return func(text: String) -> Dictionary: return {"ok": false, "text": text, "code": "unknown", "error": "Unknown change."}


func _entry_label(entry: Dictionary) -> String:
	match entry.kind:
		"decl":
			return str(WebUICssCatalog.spec(entry.prop).get("label", entry.prop))
		"new_rule":
			return "rule " + str(entry.selector)
		"text":
			return "text"
		"attr":
			return str(entry.name)
	return "change"


func set_selecting(on: bool) -> void:
	send.call("enable", {"on": on})


func select_selector(selector: String) -> void:
	send.call("select", {"selector": selector})


func reload() -> void:
	send.call("reload", {})


# ---------------------------------------------------------------- helpers

func _apply_payload(entry: Dictionary, value: String) -> Dictionary:
	return {"file": entry.file, "path": entry.path, "selector": entry.selector, "prop": entry.prop, "value": value, "important": entry.get("important", false)}


func _find_decl_entry(file: String, path: Array, prop: String) -> int:
	for i in range(pending.size()):
		var entry: Dictionary = pending[i]
		if entry.kind == "decl" and entry.prop == prop and entry.file == file and str(entry.path) == str(path):
			return i
	return -1


func _remove_decl_entry(file: String, path: Array, prop: String) -> void:
	var index := _find_decl_entry(file, path, prop)
	if index >= 0:
		pending.remove_at(index)


## Bare numbers get "px" where a length is expected.
static func _normalize_value(key: String, value: String) -> String:
	var text := value.strip_edges()
	var spec := WebUICssCatalog.spec(key)
	if spec.get("kind") == "length" and key not in ["line-height"] and RegEx.create_from_string("^-?\\d+(\\.\\d+)?$").search(text) and float(text) != 0.0:
		return text + "px"
	return text


static func _ints(values: Array) -> Array:
	var out: Array = []
	for v: Variant in values:
		out.append(int(v))
	return out


func _conditions_text(rule: Dictionary) -> String:
	var conditions: Array = rule.get("conditions", [])
	return "  (" + ", ".join(conditions) + ")" if not conditions.is_empty() else ""


func _vars_text(text: String) -> String:
	var found := PackedStringArray()
	for m in RegEx.create_from_string("var\\(\\s*(--[\\w-]+)").search_all(text):
		var name: String = m.get_string(1)
		var resolved: String = str(selection.get("vars", {}).get(name, ""))
		found.append("%s (%s)" % [name, resolved] if resolved != "" else name)
	return ", ".join(found)


func _page_html() -> String:
	var full := _full_path(page.get_file())
	if full == "":
		return ""
	var state := WebUICssPatcher.read_file(full)
	return state.text if state.ok else ""


## res:// path of a file the page reported (relative to the page's folder), or "" if it escapes the UI folder.
func _full_path(file: String) -> String:
	var full := ui_dir.path_join(page.get_base_dir()).path_join(file).simplify_path()
	return full if full.begins_with(ui_dir.simplify_path()) else ""


## A row for a piece of text: `element` is the page selector of the element that holds it, `inner` the
## same when it is not the selected element itself ("" for the selected element's own text).
func _text_row(label: String, element: String, text: String, inner: String, editable: bool, reason: String) -> Dictionary:
	var shown := text
	var unsaved := false
	for entry: Dictionary in pending:
		if entry.kind == "text" and entry.element == element:
			shown = entry.new
			unsaved = true
	return {"type": "text", "label": label, "text": shown, "editable": editable, "reason": reason, "unsaved": unsaved, "inner": inner, "element": element}


func _content_rows() -> Array:
	var state := content_state()
	var rows: Array = []
	var text_state: Dictionary = state.text
	if text_state.shown:
		rows.append(_text_row("Text", selection.selector, selection.text, "", text_state.editable, text_state.reason))
	for inner: Dictionary in state.texts:
		rows.append(_text_row("Text in <%s>" % inner.tag, inner.selector, inner.value, inner.selector, inner.editable, inner.reason))
	for attr: Dictionary in state.attrs:
		var unsaved := pending.any(func(e: Dictionary) -> bool: return e.kind == "attr" and e.element == selection.selector and e.name == attr.name)
		var shown: String = attr.value
		if unsaved:
			shown = str(pending.filter(func(e: Dictionary) -> bool: return e.kind == "attr" and e.element == selection.selector and e.name == attr.name).back().new)
		rows.append({"type": "attr", "name": attr.name, "label": attr.name, "text": shown, "editable": attr.editable, "reason": attr.reason, "unsaved": unsaved})
	return rows


## Remember the files as the page loaded them, so a save can tell if they changed since.
func _snapshot() -> void:
	_hashes.clear()
	var base := ui_dir.path_join(page.get_base_dir()).simplify_path()
	_scan_files(base, "")


func _scan_files(base: String, relative: String) -> void:
	var dir := base.path_join(relative) if not relative.is_empty() else base
	for file_name in DirAccess.get_files_at(dir):
		if file_name.get_extension().to_lower() in ["css", "html", "htm"]:
			var key := relative.path_join(file_name) if not relative.is_empty() else file_name
			var state := WebUICssPatcher.read_file(base.path_join(key))
			if state.ok:
				_hashes[key] = state.hash
	for sub in DirAccess.get_directories_at(dir):
		if not sub.begins_with("."):
			_scan_files(base, relative.path_join(sub) if not relative.is_empty() else sub)


func _say(text: String) -> void:
	status = text
	changed.emit()
