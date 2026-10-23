class_name WebUICssPatcher
extends RefCounted
## Changes single CSS declarations inside an existing stylesheet without rewriting it.
##
## A rule is addressed the way the browser's CSSOM addresses it: `path` is the list of rule indices
## from the top of the sheet (`document.styleSheets[n].cssRules[i]`, then `.cssRules[j]` inside an
## `@media`), counting every rule at each level. The page reports that path together with the
## rule's `selectorText`; the patcher re-parses the file, checks that the selector at that path
## still matches, and only then edits. Anything unexpected is refused with an error code and the
## text is returned unchanged. Only the one value (or one appended declaration) changes; comments,
## formatting, other rules and line endings are left byte-for-byte.
##
## Not supported (refused, never guessed): rules that contain nested rules (CSS nesting), values
## containing `;`, `{`, `}` or comments, rules inside at-rules other than @media, @supports, @layer,
## @container and @scope, and anything that does not parse as the expected rule.

const CONTAINER_AT_RULES := ["media", "supports", "layer", "container", "scope"]
const PROPERTY_PATTERN := "^(--[A-Za-z0-9_-]+|-?[a-z][a-z0-9-]*)$"


## Sets `prop: value` in the style rule at `path` whose selector is `expected_selector`. With
## `important`, a declaration that has to be written (or rewritten) gets `!important`: needed when the
## declaration it overrides is important too. Returns {"ok": bool, "text": String, "code": String,
## "error": String}. On failure `text` is the input unchanged and `code` is one of: bad_property,
## bad_value, no_rule, not_style_rule, nesting_unsupported, selector_mismatch.
static func set_declaration(text: String, path: Array, expected_selector: String, prop: String, value: String, important := false) -> Dictionary:
	var name := prop.strip_edges()
	if not name.begins_with("--"):
		name = name.to_lower()
	if not RegEx.create_from_string(PROPERTY_PATTERN).search(name):
		return _fail(text, "bad_property", "Invalid property name '%s'." % prop)
	var new_value := value.strip_edges()
	if new_value.is_empty() or _value_is_unsafe(new_value):
		return _fail(text, "bad_value", "Value '%s' cannot be written safely (empty, or contains ; { } or a comment)." % value)

	var rule := find_rule(parse(text), path)
	if rule.is_empty():
		return _fail(text, "no_rule", "No rule at path %s." % [path])
	if rule.kind != "style":
		return _fail(text, "not_style_rule", "The rule at path %s is not a style rule." % [path])
	if rule.nested:
		return _fail(text, "nesting_unsupported", "'%s' contains nested rules; edit it by hand." % rule.prelude)
	if _normalize_selector(rule.prelude) != _normalize_selector(expected_selector):
		return _fail(text, "selector_mismatch", "The file has '%s' at path %s, not '%s'. The file probably changed; reload the preview." % [rule.prelude, path, expected_selector])

	var existing: Dictionary = {}
	for decl: Dictionary in rule.decls:
		if decl.name == name:
			existing = decl  # the last one wins in CSS, so that is the one to change
	if not existing.is_empty():
		var rewritten: String = new_value + (" !important" if important and not existing.important else "")
		return _ok(text.substr(0, existing.value_start) + rewritten + text.substr(existing.value_end))
	return _ok(_append_declaration(text, rule, name, new_value + (" !important" if important else "")))


## True if `selector` (as the page reports it) is what the rule at `path` has in `text`.
static func rule_matches(text: String, path: Array, expected_selector: String) -> bool:
	var rule := find_rule(parse(text), path)
	return not rule.is_empty() and rule.kind == "style" and _normalize_selector(rule.prelude) == _normalize_selector(expected_selector)


## Value of the last `prop` declaration in the rule (without `!important`), or "" if absent.
static func get_declaration(text: String, path: Array, prop: String) -> String:
	var rule := find_rule(parse(text), path)
	var found := ""
	if rule.is_empty() or rule.kind != "style":
		return found
	for decl: Dictionary in rule.decls:
		if decl.name == prop.to_lower():
			found = text.substr(decl.value_start, decl.value_end - decl.value_start)
	return found


# ---------------------------------------------------------------- files

## Reads a stylesheet. Returns {"ok", "text", "hash", "error"}; `hash` identifies the exact contents.
static func read_file(file_path: String) -> Dictionary:
	if not FileAccess.file_exists(file_path):
		return {"ok": false, "text": "", "hash": "", "error": "%s does not exist." % file_path}
	var text := _read_text(file_path)
	return {"ok": true, "text": text, "hash": text.sha256_text(), "error": ""}


## FileAccess.get_file_as_string() silently drops a UTF-8 byte-order mark, which a rewrite would then
## delete from the file; decoding the bytes ourselves keeps it.
static func _read_text(file_path: String) -> String:
	var bytes := FileAccess.get_file_as_bytes(file_path)
	if bytes.size() >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF:
		return "﻿" + bytes.slice(3).get_string_from_utf8()
	return bytes.get_string_from_utf8()


## Patches one declaration in `file_path`. `loaded_hash` is the hash from read_file() when the page
## was loaded: if the file changed since (an editor, an AI agent, git), nothing is written.
## Returns the set_declaration() result plus "hash" (of the new contents) and "code" "file_changed"
## or "write_failed" when relevant.
static func patch_file(file_path: String, loaded_hash: String, path: Array, expected_selector: String, prop: String, value: String, important := false) -> Dictionary:
	return edit_file(file_path, loaded_hash, func(text: String) -> Dictionary:
		return set_declaration(text, path, expected_selector, prop, value, important))


## Edits a file in place through `transform(text) -> {"ok", "text", "code", "error"}` (any of this
## addon's patchers), with the same safeguards as patch_file: refuses when the file changed since
## `loaded_hash`, writes through a temporary file, reports the new hash.
static func edit_file(file_path: String, loaded_hash: String, transform: Callable) -> Dictionary:
	var current := read_file(file_path)
	if not current.ok:
		return {"ok": false, "text": "", "code": "read_failed", "error": current.error, "hash": ""}
	if current.hash != loaded_hash:
		return {"ok": false, "text": current.text, "code": "file_changed", "error": "%s changed on disk since it was loaded; reload the preview before editing." % file_path, "hash": current.hash}
	var result: Dictionary = transform.call(current.text)
	if not result.ok:
		result["hash"] = current.hash
		return result
	var write := write_file_atomic(file_path, result.text)
	if write != OK:
		return {"ok": false, "text": current.text, "code": "write_failed", "error": "Could not write %s (error %d); the file was left unchanged." % [file_path, write], "hash": current.hash}
	result["hash"] = result.text.sha256_text()
	return result


## Adds a new rule `selector { prop: value; ... }` at the end of the stylesheet. `expected_index` is the
## number of top-level rules the page's copy of the sheet has: when the file has a different number it
## is not what the page shows and nothing is written. Returns set_declaration()'s shape plus "path"
## (the new rule's address).
static func append_rule(text: String, selector: String, decls: Dictionary, expected_index := -1) -> Dictionary:
	var sel := selector.strip_edges()
	if sel.is_empty() or _value_is_unsafe(sel) or sel.contains("\n") or sel.contains("\r"):
		return _fail(text, "bad_selector", "Cannot write the selector '%s'." % selector)
	if decls.is_empty():
		return _fail(text, "bad_value", "A rule needs at least one declaration.")
	var eol := "\r\n" if text.contains("\r\n") else "\n"
	var unit := _indent_unit(text)
	var body := ""
	for prop: String in decls:
		var name := prop.strip_edges()
		if not name.begins_with("--"):
			name = name.to_lower()
		var value: String = str(decls[prop]).strip_edges()
		if not RegEx.create_from_string(PROPERTY_PATTERN).search(name):
			return _fail(text, "bad_property", "Invalid property name '%s'." % prop)
		if value.is_empty() or _value_is_unsafe(value):
			return _fail(text, "bad_value", "Value '%s' cannot be written safely." % value)
		body += "%s%s: %s;%s" % [unit, name, value, eol]
	var count := parse(text).size()
	if expected_index >= 0 and count != expected_index:
		return _fail(text, "file_differs", "The page has %d rules in this stylesheet but the file has %d; reload the preview." % [expected_index, count])
	var base := text.rstrip(" \t\r\n")
	var separator := (eol + eol) if not base.is_empty() else ""
	var out := base + separator + sel + " {" + eol + body + "}" + eol
	var result := _ok(out)
	result["path"] = [count]
	return result


## Writes to a temporary file next to the target, then renames it over the target, so a failed
## write never leaves a half-written stylesheet.
static func write_file_atomic(file_path: String, text: String) -> Error:
	var temp := file_path + ".webui_tmp"
	var out := FileAccess.open(temp, FileAccess.WRITE)
	if out == null:
		return FileAccess.get_open_error()
	out.store_string(text)
	out.close()
	if FileAccess.get_open_error() != OK:
		return FileAccess.get_open_error()
	var written := _read_text(temp)
	if written != text:
		DirAccess.remove_absolute(temp)
		return ERR_FILE_CORRUPT
	var err := DirAccess.rename_absolute(temp, file_path)
	if err != OK:
		DirAccess.remove_absolute(temp)
	return err


# ---------------------------------------------------------------- parsing

## Parses `text` into a tree of rules. Each rule is a Dictionary:
##   kind: "style" | "at" (container at-rule with children) | "opaque" (@keyframes, @font-face, ...)
##         | "statement" (@import, @layer a, b;)
##   prelude: selector or at-rule header, comments removed, trimmed
##   path: Array[int] CSSOM-style address
##   body_start / body_end: indices just after `{` and of the matching `}` (-1 for statements)
##   children: Array (for "at")
##   decls: Array of {name, value_start, value_end, important, colon, decl_start, decl_end} (for "style")
##   nested: bool (for "style": has a nested rule block inside)
static func parse(text: String) -> Array:
	return _parse_rules(text, 0, text.length(), [])


## The rule at `path`, or {} when there is none.
static func find_rule(rules: Array, path: Array) -> Dictionary:
	var level := rules
	var found := {}
	for i in range(path.size()):
		var index: int = path[i]
		if index < 0 or index >= level.size():
			return {}
		found = level[index]
		level = found.get("children", [])
	return found if not path.is_empty() else {}


## Flat listing "path|kind|prelude", handy for comparing with the browser's CSSOM.
static func dump(text: String) -> PackedStringArray:
	var lines := PackedStringArray()
	_dump(parse(text), lines)
	return lines


static func _dump(rules: Array, lines: PackedStringArray) -> void:
	for rule: Dictionary in rules:
		lines.append("%s|%s|%s" % [".".join(rule.path.map(func(i: int) -> String: return str(i))), rule.kind, rule.prelude])
		if rule.kind == "at":
			_dump(rule.children, lines)


static func _parse_rules(t: String, start: int, end: int, base_path: Array) -> Array:
	var rules: Array = []
	var index := 0
	var i := start
	while true:
		i = _skip_trivia(t, i, end)
		if i >= end:
			break
		if t[i] == "}":
			i += 1
			continue
		var p := _find_stop(t, i, end)
		if p >= end or t[p] == "}":
			break  # unterminated: stop rather than guess
		var prelude := _strip_comments(t.substr(i, p - i)).strip_edges()
		var path := base_path.duplicate()
		path.append(index)
		var at_name := _at_name(prelude)
		if t[p] == ";":
			if at_name != "charset":  # @charset is not part of the CSSOM
				rules.append({"kind": "statement", "prelude": prelude, "path": path, "body_start": -1, "body_end": -1, "children": [], "decls": [], "nested": false})
				index += 1
			i = p + 1
			continue
		var close := _find_block_end(t, p, end)
		var rule := {"prelude": prelude, "path": path, "body_start": p + 1, "body_end": close, "children": [], "decls": [], "nested": false}
		if not at_name.is_empty():
			if at_name in CONTAINER_AT_RULES:
				rule.kind = "at"
				rule.children = _parse_rules(t, p + 1, close, path)
			else:
				rule.kind = "opaque"
		else:
			rule.kind = "style"
			var body := _parse_declarations(t, p + 1, close)
			rule.decls = body.decls
			rule.nested = body.nested
		rules.append(rule)
		index += 1
		i = close + 1
	return rules


static func _parse_declarations(t: String, start: int, end: int) -> Dictionary:
	var decls: Array = []
	var nested := false
	var i := start
	while i < end:
		i = _skip_trivia(t, i, end)
		if i >= end:
			break
		var p := _find_stop(t, i, end)
		if p < end and t[p] == "{":
			nested = true
			i = _find_block_end(t, p, end) + 1
			continue
		var stmt_end := mini(p, end)
		var colon := _find_colon(t, i, stmt_end)
		if colon != -1:
			var name := _strip_comments(t.substr(i, colon - i)).strip_edges()
			if not name.begins_with("--"):
				name = name.to_lower()
			var value_start := colon + 1
			while value_start < stmt_end and t[value_start] in [" ", "\t", "\r", "\n"]:
				value_start += 1
			var value_end := stmt_end
			while value_end > value_start and t[value_end - 1] in [" ", "\t", "\r", "\n"]:
				value_end -= 1
			var important := false
			var bang := RegEx.create_from_string("(?i)\\s*!\\s*important$").search(t.substr(value_start, value_end - value_start))
			if bang:
				important = true
				value_end = value_start + bang.get_start()
			decls.append({
				"name": name, "value_start": value_start, "value_end": value_end, "important": important,
				"colon": colon, "decl_start": i, "decl_end": stmt_end + (1 if stmt_end < end and t[stmt_end] == ";" else 0),
			})
		i = stmt_end + 1
	return {"decls": decls, "nested": nested}


## Index of the next top-level `{`, `;` or `}` at or after `i` (skipping strings, comments and
## anything inside parentheses or brackets), or `end`.
static func _find_stop(t: String, i: int, end: int) -> int:
	var depth := 0
	while i < end:
		var c := t[i]
		if c == "/" and i + 1 < end and t[i + 1] == "*":
			i = _skip_comment(t, i, end)
			continue
		if c == "\"" or c == "'":
			i = _skip_string(t, i, end)
			continue
		if c == "\\":
			i += 2
			continue
		if c == "(" or c == "[":
			depth += 1
		elif c == ")" or c == "]":
			depth = maxi(0, depth - 1)
		elif depth == 0 and (c == "{" or c == ";" or c == "}"):
			return i
		i += 1
	return end


## Index of the `}` matching the `{` at `open_index` (or `end` when unterminated).
static func _find_block_end(t: String, open_index: int, end: int) -> int:
	var depth := 0
	var i := open_index
	while i < end:
		var c := t[i]
		if c == "/" and i + 1 < end and t[i + 1] == "*":
			i = _skip_comment(t, i, end)
			continue
		if c == "\"" or c == "'":
			i = _skip_string(t, i, end)
			continue
		if c == "\\":
			i += 2
			continue
		if c == "{":
			depth += 1
		elif c == "}":
			depth -= 1
			if depth == 0:
				return i
		i += 1
	return end


static func _find_colon(t: String, i: int, end: int) -> int:
	while i < end:
		var c := t[i]
		if c == "/" and i + 1 < end and t[i + 1] == "*":
			i = _skip_comment(t, i, end)
			continue
		if c == ":":
			return i
		i += 1
	return -1


static func _skip_trivia(t: String, i: int, end: int) -> int:
	while i < end:
		var c := t[i]
		if c == " " or c == "\t" or c == "\r" or c == "\n" or c == "﻿" or c == "\f":
			i += 1
		elif c == "/" and i + 1 < end and t[i + 1] == "*":
			i = _skip_comment(t, i, end)
		else:
			break
	return i


static func _skip_comment(t: String, i: int, end: int) -> int:
	var close := t.find("*/", i + 2)
	return end if close == -1 or close + 2 > end else close + 2


static func _skip_string(t: String, i: int, end: int) -> int:
	var quote := t[i]
	i += 1
	while i < end:
		var c := t[i]
		if c == "\\":
			i += 2
			continue
		if c == quote:
			return i + 1
		if c == "\n":
			return i  # unterminated string ends at the line break, as in CSS
		i += 1
	return end


static func _strip_comments(s: String) -> String:
	var out := ""
	var i := 0
	var n := s.length()
	while i < n:
		if s[i] == "/" and i + 1 < n and s[i + 1] == "*":
			i = _skip_comment(s, i, n)
		else:
			out += s[i]
			i += 1
	return out


static func _at_name(prelude: String) -> String:
	if not prelude.begins_with("@"):
		return ""
	var name := ""
	for k in range(1, prelude.length()):
		var c := prelude[k]
		if c == " " or c == "\t" or c == "\n" or c == "\r" or c == "(" or c == "{":
			break
		name += c
	name = name.to_lower()
	# Vendor-prefixed names (@-webkit-keyframes) are never containers.
	return name if not name.begins_with("-") else "vendor"


# ---------------------------------------------------------------- editing

static func _append_declaration(text: String, rule: Dictionary, name: String, value: String) -> String:
	var eol := "\r\n" if text.contains("\r\n") else "\n"
	var unit := _indent_unit(text)
	var body_start: int = rule.body_start
	var body_end: int = rule.body_end
	var body := text.substr(body_start, body_end - body_start)
	var multiline := body.contains("\n")
	var space := " "
	var last_decl: Dictionary = {}
	if not rule.decls.is_empty():
		last_decl = rule.decls[rule.decls.size() - 1]
		space = " " if last_decl.value_start - last_decl.colon > 1 else ""
	var declaration := "%s:%s%s;" % [name, space, value]

	# Insert right after the last non-blank character of the body, so a trailing comment stays put.
	var at := body_end
	while at > body_start and text[at - 1] in [" ", "\t", "\r", "\n"]:
		at -= 1
	var insert := ""
	if last_decl.is_empty():
		var rule_indent := _line_indent(text, _rule_start(text, rule))
		if multiline:
			return text.substr(0, body_start) + eol + rule_indent + unit + declaration + eol + rule_indent + text.substr(body_end)
		return text.substr(0, body_start) + " " + declaration + " " + text.substr(body_end)

	if text[last_decl.decl_end - 1] != ";":
		insert += ";"  # the last declaration had no semicolon
	if multiline:
		insert += eol + _line_indent(text, last_decl.decl_start) + declaration
	else:
		insert += " " + declaration
	return text.substr(0, at) + insert + text.substr(at)


## Start of the line holding the rule's prelude (for indentation of an empty block).
static func _rule_start(text: String, rule: Dictionary) -> int:
	var brace: int = rule.body_start - 1
	return maxi(0, text.rfind("\n", brace) + 1)


static func _line_indent(text: String, index: int) -> String:
	var line_start := text.rfind("\n", index) + 1
	var j := line_start
	while j < text.length() and text[j] in [" ", "\t"]:
		j += 1
	return text.substr(line_start, j - line_start)


static func _indent_unit(text: String) -> String:
	for line in text.split("\n"):
		if line.begins_with("\t"):
			return "\t"
		if line.begins_with("  "):
			var k := 0
			while k < line.length() and line[k] == " ":
				k += 1
			return " ".repeat(mini(k, 4))
	return "  "


static func _normalize_selector(selector: String) -> String:
	var s := _strip_comments(selector)
	var out := ""
	for k in range(s.length()):
		var c := s[k]
		if c in [" ", "\t", "\r", "\n"]:
			continue
		if c == "'" or c == "\"":
			continue  # the browser writes [type=range] as [type="range"]
		out += c
	return out.to_lower()


static func _value_is_unsafe(value: String) -> bool:
	for bad in [";", "{", "}", "/*", "*/", "<", "\\"]:
		if value.contains(bad):
			return true
	return false


static func _ok(text: String) -> Dictionary:
	return {"ok": true, "text": text, "code": "", "error": ""}


static func _fail(text: String, code: String, message: String) -> Dictionary:
	return {"ok": false, "text": text, "code": code, "error": message}


## True when the parsed `rule` (from parse()) is a plain style rule with this selector (as the page reports it).
static func selector_matches(rule: Dictionary, expected_selector: String) -> bool:
	return not rule.is_empty() and rule.kind == "style" and _normalize_selector(rule.prelude) == _normalize_selector(expected_selector)
