@tool
class_name WebUIHtmlPatcher
extends RefCounted
## Changes the visible text or one attribute of one element in an existing HTML file without rewriting
## it. It only acts when the target can be found in the source with certainty, and refuses otherwise:
##  - text: the element's text must appear exactly once in the source as plain element text (outside
##    comments, <script> and <style>), so a label that exists several times or that JavaScript fills in
##    is never guessed at;
##  - attributes: the element must have an id that occurs exactly once.
## Everything outside the changed characters stays byte-identical. Results use the same shape as
## WebUICssPatcher: {"ok", "text", "code", "error"}.


## Replaces the plain text `old_text` of an element with `new_text` (escaped for HTML).
## Codes: bad_text, text_not_found, text_not_unique.
static func replace_text(html: String, old_text: String, new_text: String) -> Dictionary:
	var words := _words(old_text)
	if words.is_empty():
		return _fail(html, "bad_text", "There is no text to replace.")
	if new_text.strip_edges().is_empty() or _has_control_chars(new_text):
		return _fail(html, "bad_text", "The new text is empty or contains control characters.")
	var parts := PackedStringArray()
	for word: String in words:
		parts.append(_regex_escape(_escape_text(word)))
	var pattern := RegEx.create_from_string(">(\\s*)" + "\\s+".join(parts) + "(\\s*)<")
	var masked := _masked(html)
	var matches := pattern.search_all(masked)
	if matches.is_empty():
		return _fail(html, "text_not_found", "The text \"%s\" is not plain element text in the HTML file (it may be set by JavaScript, use entities, or span several tags)." % old_text.left(40))
	if matches.size() > 1:
		return _fail(html, "text_not_unique", "The text \"%s\" appears %d times in the HTML file, so the right one cannot be told apart." % [old_text.left(40), matches.size()])
	var m := matches[0]
	var start := m.get_start() + 1 + m.get_string(1).length()
	var end := m.get_end() - 1 - m.get_string(2).length()
	return _ok(html.substr(0, start) + _escape_text(new_text.strip_edges()) + html.substr(end))


## Sets (or adds) attribute `name` of the element whose id is `element_id`. Codes: bad_attribute,
## id_not_found, id_not_unique.
static func set_attribute(html: String, element_id: String, name: String, value: String) -> Dictionary:
	var located := _locate_tag(html, element_id)
	if not located.ok:
		return located
	if not RegEx.create_from_string("^[a-zA-Z][a-zA-Z0-9:_-]*$").search(name) or _has_control_chars(value):
		return _fail(html, "bad_attribute", "Cannot write attribute '%s'." % name)
	var tag: String = located.tag
	var quoted := RegEx.create_from_string("(?i)(\\s" + name + "\\s*=\\s*)(\"[^\"]*\"|'[^']*')").search(tag)
	var bare := RegEx.create_from_string("(?i)(\\s" + name + "\\s*=\\s*)([^\\s\"'>]+)").search(tag)
	var new_tag := ""
	if quoted:
		var quote: String = quoted.get_string(2).left(1)
		new_tag = tag.substr(0, quoted.get_start(2)) + quote + _escape_attribute(value, quote) + quote + tag.substr(quoted.get_end(2))
	elif bare:
		new_tag = tag.substr(0, bare.get_start(2)) + "\"" + _escape_attribute(value, "\"") + "\"" + tag.substr(bare.get_end(2))
	else:
		var close := tag.length() - 1  # the ">"
		if close > 0 and tag[close - 1] == "/":
			close -= 1
		var gap := tag.substr(0, close).length()
		while gap > 0 and tag[gap - 1] in [" ", "\t", "\n", "\r"]:
			gap -= 1
		new_tag = tag.substr(0, gap) + " %s=\"%s\"" % [name, _escape_attribute(value, "\"")] + tag.substr(gap)
	return _ok(html.substr(0, located.start) + new_tag + html.substr(located.start + tag.length()))


## Removes attribute `name` from the element with id `element_id` (used to undo an added attribute).
static func remove_attribute(html: String, element_id: String, name: String) -> Dictionary:
	var located := _locate_tag(html, element_id)
	if not located.ok:
		return located
	var tag: String = located.tag
	var found := RegEx.create_from_string("(?i)\\s" + name + "(\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s\"'>]+))?").search(tag)
	if found == null:
		return _ok(html)
	return _ok(html.substr(0, located.start) + tag.substr(0, found.get_start()) + tag.substr(found.get_end()) + html.substr(located.start + tag.length()))


# ---------------------------------------------------------------- helpers

static func _locate_tag(html: String, element_id: String) -> Dictionary:
	if not RegEx.create_from_string("^[A-Za-z][A-Za-z0-9_:.-]*$").search(element_id):
		return _fail(html, "id_not_found", "'%s' is not a usable element id." % element_id)
	var masked := _masked(html)
	var pattern := RegEx.create_from_string("<([A-Za-z][\\w:-]*)\\b[^<>]*?\\sid\\s*=\\s*(\"|')" + _regex_escape(element_id) + "\\2[^<>]*>")
	var matches := pattern.search_all(masked)
	if matches.is_empty():
		return _fail(html, "id_not_found", "No element with id \"%s\" in the HTML file." % element_id)
	if matches.size() > 1:
		return _fail(html, "id_not_unique", "The id \"%s\" is used %d times in the HTML file." % [element_id, matches.size()])
	var m := matches[0]
	var result := _ok(html)
	result["start"] = m.get_start()
	result["tag"] = html.substr(m.get_start(), m.get_end() - m.get_start())
	return result


## The same text with comments, scripts and styles blanked out (same length), so searches cannot land in them.
static func _masked(html: String) -> String:
	var out := html
	for pattern in ["(?s)<!--.*?-->", "(?is)<script\\b.*?</script\\s*>", "(?is)<style\\b.*?</style\\s*>"]:
		var found := RegEx.create_from_string(pattern).search_all(out)
		for i in range(found.size() - 1, -1, -1):
			var m := found[i]
			out = out.substr(0, m.get_start()) + " ".repeat(m.get_end() - m.get_start()) + out.substr(m.get_end())
	return out


## Escapes the characters that mean something in a regular expression.
static func _regex_escape(text: String) -> String:
	var out := ""
	for i in range(text.length()):
		var c := text[i]
		if c in [".", "^", "$", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "/", "-", "\\"]:
			out += "\\" + c
		else:
			out += c
	return out


static func _words(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for word in text.split(" ", false):
		for piece in word.split("\n", false):
			for sub in piece.split("\t", false):
				for part in sub.split("\r", false):
					if not part.is_empty():
						out.append(part)
	return out


static func _escape_text(text: String) -> String:
	return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


static func _escape_attribute(text: String, quote: String) -> String:
	var out := text.replace("&", "&amp;").replace("<", "&lt;")
	return out.replace("\"", "&quot;") if quote == "\"" else out.replace("'", "&#39;")


static func _has_control_chars(text: String) -> bool:
	for i in range(text.length()):
		var c := text.unicode_at(i)
		if c < 32 and c != 9 and c != 10 and c != 13:
			return true
	return false


static func _ok(text: String) -> Dictionary:
	return {"ok": true, "text": text, "code": "", "error": ""}


static func _fail(text: String, code: String, message: String) -> Dictionary:
	return {"ok": false, "text": text, "code": code, "error": message}
