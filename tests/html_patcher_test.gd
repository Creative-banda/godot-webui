extends SceneTree
## Run: godot --headless --path . -s res://tests/html_patcher_test.gd
## Covers WebUIHtmlPatcher (text and attribute edits that touch only the changed characters, and
## refusals when the target cannot be found with certainty) and WebUICssPatcher.append_rule /
## the `important` flag. Exit code = number of failures.

var failures := 0
const HTML := "<!doctype html>\n<body>\n  <!-- Play -->\n  <button id=\"b1\" class=\"x\">\n    Play now\n  </button>\n  <span id=\"s\">A &amp; B</span><span>Dup</span><span>Dup</span>\n  <img id=\"i\" src=\"a.png\">\n  <input id=\"n\" value='old' disabled>\n  <script>var t = '>Play now<';</script>\n  <style>b>Play now<i {}</style>\n</body>"


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _initialize() -> void:
	_test_text()
	_test_attributes()
	_test_css_additions()
	quit(failures)


func _test_text() -> void:
	var r := WebUIHtmlPatcher.replace_text(HTML, "Play now", "Start")
	check(r.ok and r.text == HTML.replace("Play now\n  </button>", "Start\n  </button>").replace("var t = '>Start<'", "var t = '>Play now<'"), "text is replaced in place, keeping the whitespace around it")
	check(r.text.contains("<!-- Play -->") and r.text.contains("var t = '>Play now<';") and r.text.contains("b>Play now<i"), "comments, scripts and styles are never touched")
	check(WebUIHtmlPatcher.replace_text(HTML, "Dup", "x").code == "text_not_unique", "text that appears twice is refused")
	check(WebUIHtmlPatcher.replace_text(HTML, "Nope", "x").code == "text_not_found", "text that is not there is refused")
	check(WebUIHtmlPatcher.replace_text(HTML, "A & B", "C < D").text.contains(">C &lt; D<"), "text is read and written with entities")
	check(WebUIHtmlPatcher.replace_text(HTML, "Play now", "  ").code == "bad_text" and WebUIHtmlPatcher.replace_text(HTML, "", "x").code == "bad_text", "empty text is refused")
	check(WebUIHtmlPatcher.replace_text("<p>Hello\n   world</p>", "Hello world", "Hi").text == "<p>Hi</p>", "text broken over lines is found")
	check(WebUIHtmlPatcher.replace_text("<p>a.b (c)</p>", "a.b (c)", "x").ok, "regex characters in the text are literal")


func _test_attributes() -> void:
	var a := WebUIHtmlPatcher.set_attribute(HTML, "i", "alt", "Logo \"x\"")
	check(a.ok and a.text.contains("<img id=\"i\" src=\"a.png\" alt=\"Logo &quot;x&quot;\">"), "a missing attribute is added with its value escaped")
	check(WebUIHtmlPatcher.set_attribute(HTML, "i", "src", "b.png").text.contains("src=\"b.png\""), "an existing attribute is replaced")
	check(WebUIHtmlPatcher.set_attribute(HTML, "n", "value", "new").text.contains("<input id=\"n\" value='new' disabled>"), "single quotes are kept")
	check(WebUIHtmlPatcher.remove_attribute(a.text, "i", "alt").text == HTML, "removing the added attribute gives back the original file")
	check(WebUIHtmlPatcher.set_attribute("<img id=\"i\" src=\"a\"/>", "i", "alt", "x").text == "<img id=\"i\" src=\"a\" alt=\"x\"/>", "self-closing tags")
	check(WebUIHtmlPatcher.set_attribute(HTML, "zz", "alt", "x").code == "id_not_found", "unknown id refused")
	check(WebUIHtmlPatcher.set_attribute("<p id=\"a\"></p><p id=\"a\"></p>", "a", "title", "x").code == "id_not_unique", "duplicate id refused")
	check(WebUIHtmlPatcher.set_attribute(HTML, "b1", "bad name", "x").code == "bad_attribute", "bad attribute name refused")
	check(WebUIHtmlPatcher.set_attribute("<!-- <p id=\"a\"> --><p id=\"b\"></p>", "a", "title", "x").code == "id_not_found", "an element inside a comment does not count")


func _test_css_additions() -> void:
	var css := ".a {\n  color: red;\n}\n"
	var r := WebUICssPatcher.append_rule(css, "#id", {"color": "blue", "margin-top": "4px"}, 1)
	check(r.ok and r.path == [1] and r.text == ".a {\n  color: red;\n}\n\n#id {\n  color: blue;\n  margin-top: 4px;\n}\n", "a new rule is appended at the end with the file's formatting")
	check(WebUICssPatcher.append_rule(css, "#id", {"color": "blue"}, 5).code == "file_differs", "a file with another number of rules than the page is refused")
	check(WebUICssPatcher.append_rule(css, "#id {", {"color": "blue"}).code == "bad_selector" and WebUICssPatcher.append_rule(css, "#id", {"color": "a;b"}).code == "bad_value", "unsafe selector or value refused")
	check(WebUICssPatcher.append_rule(css, "#id", {}).code == "bad_value", "a rule without declarations is refused")
	check(WebUICssPatcher.append_rule(".a {}", "#id", {"top": "0"}).text.ends_with("}\n"), "a file without a final newline is handled")
	check(WebUICssPatcher.append_rule("", "#id", {"top": "0"}).text == "#id {\n  top: 0;\n}\n", "an empty file")
	check(WebUICssPatcher.append_rule(".a {\r\n  top: 1px;\r\n}\r\n", "#id", {"top": "0"}).text.contains("\r\n\r\n#id {\r\n  top: 0;\r\n}\r\n"), "CRLF files keep CRLF")

	var important := WebUICssPatcher.set_declaration(".a { margin: 0 !important }", [0], ".a", "margin-top", "4px", true)
	check(important.ok and important.text == ".a { margin: 0 !important; margin-top: 4px !important; }", "an appended declaration can carry !important")
	var replaced := WebUICssPatcher.set_declaration(".a { color: red }", [0], ".a", "color", "blue", true)
	check(replaced.text == ".a { color: blue !important }", "a replaced value can gain !important")
	check(WebUICssPatcher.set_declaration(".a { color: red !important }", [0], ".a", "color", "blue").text == ".a { color: blue !important }", "an existing !important stays")
