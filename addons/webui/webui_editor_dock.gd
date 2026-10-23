@tool
class_name WebUIEditorDock
extends VBoxContainer
## The visual editor dock: pick a page, open it in the edit preview, click an element there, and the
## inspector below shows the sections and properties that suit that kind of element. Changing a value
## updates the preview at once; Save writes it into the source file in place. The logic lives in
## WebUIEditorModel; this class builds the controls and shows what the model says.

const FONT_PRESETS := ["system-ui", "sans-serif", "serif", "monospace", "ui-monospace", "cursive", "fantasy"]
const NOTE_COLOR := Color(1, 1, 1, 0.55)
const WARN_COLOR := Color(1.0, 0.72, 0.35, 0.95)

var model: WebUIEditorModel

var _link: WebUIEditLink
var _open_preview := Callable()
var _pages: Array = []            # [{"ui_dir", "page"}]
var _page_option: OptionButton
var _select_check: CheckBox
var _title_label: Label
var _kind_label: Label
var _scope_option: OptionButton
var _scope_values: Array = []     # target_rule value for each _scope_option item
var _sections_box: VBoxContainer
var _rows := {}                   # key -> {"type", "edit", "picker", "note", "label", ...}
var _collapsed := {}              # section id -> bool, remembered between selections
var _undo_button: Button
var _save_button: Button
var _status_label: Label
var _refreshing := false
var _signature := ""
var _scope_signature := ""
var _sample_edit: TextEdit
var _sample_body: VBoxContainer
var _sample_header: Button
var _sample_note: Label
var _sample_shown := ""
var _sample_page := ""
var _page_listens := false   # the page listens for state, so without a sample it shows placeholders


## `link` is the WebUIEditLink of the running editor plugin (null in tests);
## `open_preview` is called to (re)start the preview window and returns whether it started.
func setup(new_model: WebUIEditorModel, link: WebUIEditLink, open_preview: Callable) -> void:
	model = new_model
	_link = link
	_open_preview = open_preview
	model.send = _send
	model.changed.connect(_refresh)
	if _link:
		_link.page_message.connect(model.on_page_message)
		_link.session_changed.connect(_on_session_changed)
	_build()
	_discover_pages()
	_refresh()


func _send(op: String, payload: Dictionary) -> void:
	if _link == null or not _link.send(op, payload):
		model.status = "The preview is not running. Press Open preview."


func _on_session_changed(running: bool) -> void:
	if not running:
		model.preview_ready = false
		model.selection = {}
		model.status = "The preview was closed." + (" Unsaved changes are kept; open it again to continue." if model.has_pending() else "")
	model.changed.emit()


# ---------------------------------------------------------------- building the fixed parts

func _build() -> void:
	name = "WebUI"
	custom_minimum_size = Vector2(320, 0)
	add_theme_constant_override("separation", 6)

	var top := HBoxContainer.new()
	_page_option = OptionButton.new()
	_page_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page_option.tooltip_text = "The UI page to edit (every .html in your UI folders)."
	_page_option.clip_text = true
	top.add_child(_page_option)
	var refresh := Button.new()
	refresh.text = "Rescan"
	refresh.tooltip_text = "Look for pages again."
	refresh.pressed.connect(_discover_pages)
	top.add_child(refresh)
	add_child(top)

	var run := HBoxContainer.new()
	var open := Button.new()
	open.text = "Open preview"
	open.tooltip_text = "Run the page in the desktop preview with edit mode (needs godot_wry, see docs/desktop-preview.md)."
	open.pressed.connect(_on_open_pressed)
	run.add_child(open)
	var reload := Button.new()
	reload.text = "Reload"
	reload.tooltip_text = "Re-read the files and reload the page (unsaved changes are re-applied)."
	reload.pressed.connect(func() -> void: model.reload())
	run.add_child(reload)
	_select_check = CheckBox.new()
	_select_check.text = "Select"
	_select_check.button_pressed = true
	_select_check.tooltip_text = "On: clicking in the preview selects an element. Off: use the page normally (to reach other screens), then turn it on again."
	_select_check.toggled.connect(func(on: bool) -> void: model.set_selecting(on))
	run.add_child(_select_check)
	add_child(run)

	_title_label = Label.new()
	_title_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_title_label.add_theme_font_size_override("font_size", 14)
	add_child(_title_label)
	_kind_label = Label.new()
	_kind_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_kind_label.modulate = NOTE_COLOR
	add_child(_kind_label)

	var scope_row := HBoxContainer.new()
	var scope_caption := Label.new()
	scope_caption.text = "Apply to"
	scope_row.add_child(scope_caption)
	_scope_option = OptionButton.new()
	_scope_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scope_option.clip_text = true
	_scope_option.tooltip_text = "Automatic picks the narrowest rule that can take the change without affecting other elements, and writes a rule for this element alone when only shared rules exist. Choose a rule to write to it directly."
	_scope_option.item_selected.connect(func(index: int) -> void:
		if _refreshing or index < 0 or index >= _scope_values.size():
			return
		model.target_rule = _scope_values[index]
		model.changed.emit())
	scope_row.add_child(_scope_option)
	add_child(scope_row)

	_build_sample_section()

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_sections_box = VBoxContainer.new()
	_sections_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sections_box.add_theme_constant_override("separation", 4)
	scroll.add_child(_sections_box)
	add_child(scroll)

	var buttons := HBoxContainer.new()
	_undo_button = Button.new()
	_undo_button.text = "Undo"
	_undo_button.pressed.connect(func() -> void: model.undo())
	buttons.add_child(_undo_button)
	_save_button = Button.new()
	_save_button.text = "Save"
	_save_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_button.pressed.connect(func() -> void: model.save())
	buttons.add_child(_save_button)
	add_child(buttons)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.modulate = Color(1, 1, 1, 0.8)
	add_child(_status_label)


## The "Sample state" block: JSON the preview gives the page in place of the game's set_state / emit_event.
func _build_sample_section() -> void:
	_sample_header = Button.new()
	_sample_header.flat = true
	_sample_header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_sample_header.tooltip_text = "The preview has no game behind it, so pages show their placeholders. Describe the state Godot would send and the page shows it. Kept next to the page in a hidden .webui-edit folder, which is never exported."
	add_child(_sample_header)
	_sample_body = VBoxContainer.new()
	_sample_body.visible = false
	_sample_edit = TextEdit.new()
	_sample_edit.custom_minimum_size = Vector2(0, 110)
	_sample_edit.placeholder_text = "{
  \"states\": { \"hud\": { \"health\": 80 } },
  \"events\": [ { \"name\": \"toast\", \"payload\": { \"text\": \"Hi\" } } ]
}"
	_sample_edit.add_theme_font_size_override("font_size", 12)
	_sample_body.add_child(_sample_edit)
	var row := HBoxContainer.new()
	var apply := Button.new()
	apply.text = "Apply"
	apply.tooltip_text = "Check the JSON, show it in the preview and save it next to the page."
	apply.pressed.connect(func() -> void: model.set_sample(_sample_edit.text))
	row.add_child(apply)
	var template := Button.new()
	template.text = "From the page"
	template.tooltip_text = "Fill in the state and event names the page's scripts listen for (Godot.on / onEvent), with empty values."
	template.pressed.connect(func() -> void: _sample_edit.text = model.sample_template())
	row.add_child(template)
	_sample_body.add_child(row)
	_sample_note = Label.new()
	_sample_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sample_note.add_theme_font_size_override("font_size", 11)
	_sample_note.modulate = WARN_COLOR
	_sample_body.add_child(_sample_note)
	add_child(_sample_body)
	_sample_header.pressed.connect(func() -> void:
		_sample_body.visible = not _sample_body.visible
		_refresh_sample())


func _refresh_sample() -> void:
	var open := _sample_body.visible
	var page_key := model.ui_dir + "|" + model.page
	if page_key != _sample_page and model.page != "":
		var listened: Variant = JSON.parse_string(model.sample_template())
		_page_listens = typeof(listened) == TYPE_DICTIONARY and not (listened.states.is_empty() and listened.events.is_empty())
	var has_sample := model.sample_text.strip_edges() != ""
	var marker := " ●" if has_sample else (" – none, the page shows placeholders" if _page_listens else "")
	_sample_header.text = ("▾ " if open else "▸ ") + "Sample state" + marker
	if page_key != _sample_page or (model.sample_text != _sample_shown and not _sample_edit.has_focus()):
		_sample_page = page_key
		_sample_shown = model.sample_text
		_sample_edit.text = model.sample_text
	_sample_note.text = model.sample_error
	_sample_note.visible = model.sample_error != ""


# ---------------------------------------------------------------- showing the model

func _refresh() -> void:
	# Also false for a dock that was built by an older version of this script while the editor was open
	# (a reloaded script keeps the instance but not the controls it did not create): restart the plugin.
	if _status_label == null or _sample_body == null:
		return
	_refreshing = true
	_refresh_header()
	_refresh_scope()
	_refresh_sample()
	var sections := model.inspector()
	var signature := _signature_of(sections)
	if signature != _signature:
		_signature = signature
		_rebuild_sections(sections)
	_update_rows(sections)
	_undo_button.disabled = not model.can_undo()
	_save_button.disabled = not model.has_pending()
	_save_button.text = "Save (%d)" % model.pending.size() if model.has_pending() else "Save"
	_status_label.text = model.status
	_refreshing = false


func _refresh_header() -> void:
	var selection := model.selection
	if selection.is_empty():
		_title_label.text = "Nothing selected." if model.preview_ready else "Preview not running."
		_kind_label.text = "Click an element in the preview." if model.preview_ready else ""
		return
	var classes: Array = selection.get("classes", [])
	_title_label.text = str(selection.tag) + ("#" + str(selection.id) if str(selection.get("id", "")) != "" else "") + "".join(classes.map(func(c: String) -> String: return "." + c))
	var parts := PackedStringArray([_kind_name(str(selection.get("kind", "")))])
	parts.append("display: %s" % selection.get("display", ""))
	parts.append("%d matching rule%s" % [selection.rules.size(), "" if selection.rules.size() == 1 else "s"])
	_kind_label.text = " · ".join(parts)


static func _kind_name(kind: String) -> String:
	return {"text": "Text element", "container": "Container", "button": "Button", "link": "Link", "input": "Form control", "image": "Image", "media": "Media", "svg": "SVG graphic"}.get(kind, "Element")


func _refresh_scope() -> void:
	var selection := model.selection
	var signature := str(selection.get("selector", "")) + "|" + str(model.target_rule) + "|" + str(selection.get("rules", []).size()) + "|" + str(pending_signature())
	if signature == _scope_signature:
		return
	_scope_signature = signature
	_scope_option.clear()
	_scope_values = [-1]
	_scope_option.add_item("Automatic")
	if selection.is_empty():
		_scope_option.select(0)
		return
	if selection.get("id_unique", false):
		_scope_option.add_item("This element only (#%s)" % selection.id)
		_scope_values.append(-2)
	var rules: Array = selection.rules
	for i in range(rules.size()):
		var rule: Dictionary = rules[i]
		if str(rule.file) == "":
			continue
		var shared := int(rule.affects)
		_scope_option.add_item("%s  %s%s" % [rule.selector, rule.file, "  [%d elements]" % shared if shared > 1 else ""])
		_scope_values.append(i)
	var selected := _scope_values.find(model.target_rule)
	_scope_option.select(maxi(selected, 0))


func pending_signature() -> String:
	return str(model.pending.size())


## Changes only when the set of sections and rows must be rebuilt (a different kind of element, a
## different selection); a changed value alone does not.
func _signature_of(sections: Array) -> String:
	var parts := PackedStringArray([str(model.selection.get("selector", ""))])
	for section: Dictionary in sections:
		parts.append(section.id)
		for row: Dictionary in section.rows:
			parts.append("%s:%s:%s" % [row.get("type", ""), _row_id(row), row.get("editable", "")])
	return "|".join(parts)


func _rebuild_sections(sections: Array) -> void:
	for child in _sections_box.get_children():
		child.queue_free()
	_rows.clear()
	for section: Dictionary in sections:
		var id: String = str(model.selection.get("kind", "")) + ":" + str(section.id)  # remembered per kind of element
		if not _collapsed.has(id):
			_collapsed[id] = section.collapsed
		var body := VBoxContainer.new()
		body.add_theme_constant_override("separation", 3)
		body.visible = not _collapsed[id]
		var header := Button.new()
		header.flat = true
		header.alignment = HORIZONTAL_ALIGNMENT_LEFT
		header.text = ("▸ " if _collapsed[id] else "▾ ") + section.title
		header.add_theme_font_size_override("font_size", 13)
		header.pressed.connect(func() -> void:
			_collapsed[id] = not _collapsed[id]
			body.visible = not _collapsed[id]
			header.text = ("▸ " if _collapsed[id] else "▾ ") + section.title)
		_sections_box.add_child(header)
		if str(section.note) != "":
			var note := Label.new()
			note.text = section.note
			note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			note.modulate = NOTE_COLOR
			note.add_theme_font_size_override("font_size", 11)
			body.add_child(note)
		for row: Dictionary in section.rows:
			_add_row(body, row)
		_sections_box.add_child(body)
		_sections_box.add_child(HSeparator.new())


## Key a row is registered under: a property key, or content:text:<element> / content:<attribute>.
static func _row_id(row: Dictionary) -> String:
	if row.has("key"):
		return str(row.key)
	if row.type == "text":
		return "content:text:" + str(row.get("element", ""))
	return "content:" + str(row.get("name", row.type))


func _add_row(parent: VBoxContainer, row: Dictionary) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	var line := HBoxContainer.new()
	var label := Label.new()
	label.text = str(row.label)
	label.custom_minimum_size = Vector2(92, 0)
	label.clip_text = true
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	line.add_child(label)
	var entry := {"type": row.type, "label": label}
	match row.type:
		"sides":
			var holder := HBoxContainer.new()
			holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var edits: Array = []
			var letters := ["T", "R", "B", "L"]
			for i in range(4):
				var side: Dictionary = row.sides[i]
				var edit := _make_line_edit(str(side.key), "length")
				edit.placeholder_text = letters[i]
				edit.custom_minimum_size = Vector2(44, 0)
				holder.add_child(edit)
				edits.append(edit)
			line.add_child(holder)
			entry["edits"] = edits
		"text":
			var inner: String = row.get("inner", "")  # "" = the selected element's own text
			var edit := LineEdit.new()
			edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			edit.text_submitted.connect(func(text: String) -> void:
				if not _refreshing:
					model.set_text(text, inner))
			edit.focus_exited.connect(func() -> void:
				if not _refreshing and edit.text != str(edit.get_meta("shown", "")):
					model.set_text(edit.text, inner))
			line.add_child(edit)
			entry["edit"] = edit
		"attr":
			var edit := LineEdit.new()
			edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var attr_name: String = row.name
			edit.text_submitted.connect(func(text: String) -> void:
				if not _refreshing:
					model.set_attribute(attr_name, text))
			edit.focus_exited.connect(func() -> void:
				if not _refreshing and edit.text != str(edit.get_meta("shown", "")):
					model.set_attribute(attr_name, edit.text))
			line.add_child(edit)
			entry["edit"] = edit
		_:
			var key: String = row.key
			match row.kind:
				"enum":
					var option := OptionButton.new()
					option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
					option.clip_text = true
					for value: String in row.options:
						option.add_item(value)
					option.item_selected.connect(func(index: int) -> void:
						if not _refreshing:
							model.set_property(key, option.get_item_text(index)))
					line.add_child(option)
					entry["edit"] = option
				"color":
					var picker := ColorPickerButton.new()
					picker.custom_minimum_size = Vector2(34, 0)
					picker.edit_alpha = true
					var edit := _make_line_edit(key, "color")
					picker.color_changed.connect(func(color: Color) -> void:
						if not _refreshing:
							model.set_property(key, "#" + color.to_html(color.a < 1.0)))
					line.add_child(picker)
					line.add_child(edit)
					entry["edit"] = edit
					entry["picker"] = picker
				"font":
					var edit := _make_line_edit(key, "text")
					var presets := OptionButton.new()
					presets.custom_minimum_size = Vector2(28, 0)
					presets.tooltip_text = "Font families"
					for family: String in PackedStringArray(FONT_PRESETS) + PackedStringArray(model.selection.get("fonts", [])):
						presets.add_item(family)
					presets.selected = -1
					presets.item_selected.connect(func(index: int) -> void:
						if _refreshing:
							return
						var family := presets.get_item_text(index)
						model.set_property(key, "\"%s\", sans-serif" % family if family.contains(" ") else family)
						presets.selected = -1)
					line.add_child(edit)
					line.add_child(presets)
					entry["edit"] = edit
				_:
					var edit := _make_line_edit(key, str(row.kind))
					line.add_child(edit)
					entry["edit"] = edit
	box.add_child(line)
	var note := Label.new()
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 11)
	note.visible = false
	box.add_child(note)
	entry["note"] = note
	parent.add_child(box)
	_rows[_row_id(row)] = entry


func _make_line_edit(key: String, kind: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.select_all_on_focus = true
	edit.set_meta("key", key)
	var commit := func(text: String) -> void:
		if _refreshing or text.strip_edges() == str(edit.get_meta("shown", "")):
			return
		model.set_property(key, text)
	edit.text_submitted.connect(commit)
	edit.focus_exited.connect(func() -> void: commit.call(edit.text))
	if kind in ["length", "number"]:
		edit.gui_input.connect(func(event: InputEvent) -> void:
			if event is InputEventKey and event.pressed and event.keycode in [KEY_UP, KEY_DOWN]:
				var stepped := _nudge(edit.text, 1.0 if event.keycode == KEY_UP else -1.0, event.shift_pressed, event.alt_pressed)
				if stepped != "":
					edit.text = stepped
					edit.accept_event()
					commit.call(stepped))
	return edit


## "14px" + 1 -> "15px". Shift steps by 10, Alt by 0.1. "" when there is no number to step.
static func _nudge(text: String, direction: float, big: bool, fine: bool) -> String:
	var m := RegEx.create_from_string("^\\s*(-?\\d*\\.?\\d+)\\s*([a-z%]*)\\s*$").search(text)
	if m == null:
		return ""
	var step := 10.0 if big else (0.1 if fine else 1.0)
	var value := float(m.get_string(1)) + direction * step
	var number := ("%.1f" % value).rstrip("0").rstrip(".") if absf(value - roundf(value)) > 0.001 else str(int(roundf(value)))
	return number + m.get_string(2)


func _update_rows(sections: Array) -> void:
	for section: Dictionary in sections:
		for row: Dictionary in section.rows:
			if row.type == "sides":
				var entry: Dictionary = _rows.get(str(row.key), {})
				if entry.is_empty():
					continue
				var any_unsaved := false
				var notes := PackedStringArray()
				for i in range(4):
					var side: Dictionary = row.sides[i]
					var edit: LineEdit = entry.edits[i]
					_show_text(edit, str(side.text))
					edit.editable = side.editable
					edit.modulate = Color(1, 1, 1, 1.0 if side.state in ["rule", "inline"] or side.unsaved else 0.55)
					edit.tooltip_text = "%s: %s" % [side.label, side.source if side.editable else side.reason]
					any_unsaved = any_unsaved or side.unsaved
					if side.note != "" and not notes.has(side.note):
						notes.append(side.note)
				_set_note(entry, "  ".join(notes), WARN_COLOR if _any_prefix(notes, "Changes ") else NOTE_COLOR)
				entry.label.modulate = Color(1, 1, 1, 1.0 if _editable_any(row.sides) else 0.45)
				continue
			var id := _row_id(row)
			var item: Dictionary = _rows.get(id, {})
			if item.is_empty():
				continue
			if row.type in ["text", "attr"]:
				var edit: LineEdit = item.edit
				_show_text(edit, str(row.text))
				edit.editable = row.editable
				edit.modulate = Color(1, 1, 1, 1.0 if row.editable else 0.6)
				_set_note(item, "" if row.editable else str(row.reason), WARN_COLOR)
				item.label.modulate = Color(1, 1, 1, 1.0 if row.editable else 0.6)
				continue
			_update_prop_row(item, row)


func _editable_any(sides: Array) -> bool:
	for side: Dictionary in sides:
		if side.editable:
			return true
	return false


func _any_prefix(texts: PackedStringArray, prefix: String) -> bool:
	for text in texts:
		if text.begins_with(prefix):
			return true
	return false


func _update_prop_row(item: Dictionary, row: Dictionary) -> void:
	var editable: bool = row.editable
	var dim := 1.0 if (row.state in ["rule", "inline"] or row.unsaved) else 0.6
	item.label.tooltip_text = "%s\nValue from: %s" % [row.key, row.source] if row.source != "" else str(row.key)
	item.label.modulate = Color(1, 1, 1, 1.0 if editable else 0.5)
	var control: Control = item.edit
	if control is OptionButton:
		var option: OptionButton = control
		option.disabled = not editable
		var found := -1
		for i in range(option.item_count):
			if option.get_item_text(i) == str(row.text):
				found = i
		if found == -1 and str(row.text) != "":
			option.add_item(str(row.text))
			found = option.item_count - 1
		option.select(found)
	else:
		var edit: LineEdit = control
		_show_text(edit, str(row.text))
		edit.editable = editable
		edit.modulate = Color(1, 1, 1, dim)
		edit.placeholder_text = str(row.hint)
		edit.tooltip_text = str(row.source) if row.source != "" else ""
		if item.has("picker"):
			var picker: ColorPickerButton = item.picker
			picker.disabled = not editable
			picker.color = _to_color(str(row.text), str(row.computed))
	var note_text := ""
	var color := NOTE_COLOR
	if not editable and str(row.reason) != "":
		note_text = str(row.reason)
		color = WARN_COLOR
	elif str(row.note) != "":
		note_text = str(row.note)
		color = WARN_COLOR if str(row.note).contains("Changes ") else NOTE_COLOR
	elif row.state == "inherited":
		note_text = "Inherited from %s" % str(row.source).trim_prefix("inherited from ")
	_set_note(item, note_text, color)


func _show_text(edit: LineEdit, text: String) -> void:
	edit.set_meta("shown", text)
	if not edit.has_focus():
		edit.text = text


func _set_note(item: Dictionary, text: String, color: Color) -> void:
	var note: Label = item.note
	note.text = text
	note.visible = text != ""
	note.modulate = color


## A CSS colour text as a Color; `fallback_text` (the computed rgb()) when it is not a literal (var(), etc.).
static func _to_color(text: String, fallback_text: String) -> Color:
	var parsed: Variant = _parse_css_color(text)
	if parsed != null:
		return parsed
	var fallback: Variant = _parse_css_color(fallback_text)
	return fallback if fallback != null else Color.BLACK


static func _parse_css_color(text: String) -> Variant:
	var t := text.strip_edges().to_lower()
	var m := RegEx.create_from_string("^rgba?\\(\\s*([\\d.]+)[,\\s]+([\\d.]+)[,\\s]+([\\d.]+)(?:\\s*[,/]\\s*([\\d.]+%?))?\\s*\\)$").search(t)
	if m:
		var alpha := 1.0
		if m.get_string(4) != "":
			alpha = float(m.get_string(4).trim_suffix("%")) / (100.0 if m.get_string(4).ends_with("%") else 1.0)
		return Color(float(m.get_string(1)) / 255.0, float(m.get_string(2)) / 255.0, float(m.get_string(3)) / 255.0, alpha)
	if t.begins_with("#") or t in ["transparent", "black", "white", "red", "green", "blue", "yellow", "orange", "gray", "grey", "purple", "pink", "cyan"]:
		if t == "transparent":
			return Color(0, 0, 0, 0)
		var probe := Color.from_string(t, Color(-1, -1, -1))
		return null if probe.r < 0.0 else probe
	return null


# ---------------------------------------------------------------- pages and the preview

func _discover_pages() -> void:
	_pages.clear()
	_page_option.clear()
	var scan := WebUIExportScan.resolve()
	for folder: String in scan.folders:
		for page in _html_files(folder, ""):
			_pages.append({"ui_dir": folder, "page": page})
			_page_option.add_item("%s  (%s)" % [page, folder.trim_prefix("res://")])
	if _pages.is_empty():
		_page_option.add_item("No UI pages found")
		_page_option.disabled = true
	else:
		_page_option.disabled = false
	if model:
		model.status = "%d page%s found." % [_pages.size(), "" if _pages.size() == 1 else "s"] if not _pages.is_empty() else "No folder with an .html file found (see Project Settings > webui/export/ui_folders)."
		model.changed.emit()


func _html_files(folder: String, relative: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := folder.path_join(relative) if not relative.is_empty() else folder
	for file_name in DirAccess.get_files_at(dir):
		if file_name.get_extension().to_lower() in ["html", "htm"]:
			out.append(relative.path_join(file_name) if not relative.is_empty() else file_name)
	for sub in DirAccess.get_directories_at(dir):
		if not sub.begins_with(".") and not FileAccess.file_exists(dir.path_join(sub).path_join(".gdignore")):
			out.append_array(_html_files(folder, relative.path_join(sub) if not relative.is_empty() else sub))
	return out


## Opens `page_path` (a res:// .html file) in the editor: selects it, brings the dock to the front and starts the
## preview. Returns "" on success, or why it could not (the page is not in a UI folder, or unsaved changes
## belong to another page).
func open_page(page_path: String) -> String:
	_discover_pages()
	var index := -1
	for i in range(_pages.size()):
		if str(_pages[i].ui_dir).path_join(str(_pages[i].page)) == page_path:
			index = i
	if index < 0:
		return "%s is not in a UI folder the WebUI editor can list: it needs a folder with .html files outside addons/ (or one named in Project Settings > webui/export/ui_folders)." % page_path
	_page_option.select(index)
	_show_dock()
	_on_open_pressed()
	return model.status if model.status.begins_with("Save or undo") else ""


## Brings the dock's tab to the front when it sits in a tab container.
func _show_dock() -> void:
	var node: Node = self
	while node.get_parent() != null:
		var parent := node.get_parent()
		if parent is TabContainer:
			var tabs := parent as TabContainer
			var tab := tabs.get_tab_idx_from_control(node as Control)
			if tab >= 0:
				tabs.current_tab = tab
			return
		node = parent


func _on_open_pressed() -> void:
	var index := _page_option.selected
	if index < 0 or index >= _pages.size():
		model.status = "Pick a page first."
		model.changed.emit()
		return
	var target: Dictionary = _pages[index]
	if model.has_pending() and (model.ui_dir != target.ui_dir or model.page != target.page):
		model.status = "Save or undo your changes before opening another page."
		model.changed.emit()
		return
	var same_folder_running: bool = model.preview_ready and model.ui_dir == target.ui_dir
	if model.ui_dir != target.ui_dir or model.page != target.page:
		model.open_page(target.ui_dir, target.page)
	if WebUIEditPreview.write_target(target.ui_dir, target.page) != OK:
		model.status = "Could not write %s." % WebUIEditPreview.TARGET_FILE
		model.changed.emit()
		return
	# A running preview can show another page of its folder without restarting.
	if same_folder_running and _link != null and _link.send("page", {"page": target.page}):
		model.status = "Opening %s ..." % target.page
		model.changed.emit()
		return
	model.status = "Starting the preview ..."
	model.changed.emit()
	if _open_preview.is_valid() and not _open_preview.call():
		model.status = "Could not start the preview window."
		model.changed.emit()
