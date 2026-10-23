@tool
class_name WebUIEditorDock
extends VBoxContainer
## The visual editor dock: pick a page, open it in the edit preview, click an element there, change
## its CSS here, Save writes the change into the stylesheet in place. The logic lives in
## WebUIEditorModel; this class only builds the controls and shows what the model says.

var model: WebUIEditorModel

var _link: WebUIEditLink
var _open_preview := Callable()
var _pages: Array = []            # [{"ui_dir", "page"}]
var _page_option: OptionButton
var _select_check: CheckBox
var _selection_label: Label
var _rule_option: OptionButton
var _rows := {}                   # property -> {"kind", "label", "edit", "picker"}
var _undo_button: Button
var _save_button: Button
var _status_label: Label
var _refreshing := false
var _rules_signature := ""


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


# ---------------------------------------------------------------- building

func _build() -> void:
	name = "WebUI"
	custom_minimum_size = Vector2(300, 0)
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

	_selection_label = Label.new()
	_selection_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	add_child(_selection_label)

	var rule_row := HBoxContainer.new()
	var rule_caption := Label.new()
	rule_caption.text = "Edit rule"
	rule_row.add_child(rule_caption)
	_rule_option = OptionButton.new()
	_rule_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rule_option.clip_text = true
	_rule_option.tooltip_text = "Automatic writes each change to the rule that currently wins that property. Pick a rule to send every change there instead."
	_rule_option.item_selected.connect(func(index: int) -> void:
		if _refreshing:
			return
		model.target_rule = index - 1
		model.changed.emit())
	rule_row.add_child(_rule_option)
	add_child(rule_row)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)
	add_child(scroll)

	var group := ""
	var grid: GridContainer
	for spec: Dictionary in WebUIEditorModel.PROPERTIES:
		if spec.group != group:
			group = spec.group
			var header := Label.new()
			header.text = group
			header.add_theme_font_size_override("font_size", 13)
			header.modulate = Color(1, 1, 1, 0.7)
			column.add_child(header)
			grid = GridContainer.new()
			grid.columns = 2
			grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			column.add_child(grid)
		_add_row(grid, spec)

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


func _add_row(grid: GridContainer, spec: Dictionary) -> void:
	var prop: String = spec.name
	var label := Label.new()
	label.text = prop.trim_suffix("-width") if prop == "border-top-width" else prop
	if prop == "border-top-width":
		label.text = "border-width"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	grid.add_child(label)
	var row := {"kind": spec.kind, "label": label}
	match spec.kind:
		"enum":
			var option := OptionButton.new()
			option.custom_minimum_size = Vector2(130, 0)
			for value: String in spec.options:
				option.add_item(value)
			option.item_selected.connect(func(index: int) -> void:
				if not _refreshing:
					model.set_property(prop, option.get_item_text(index)))
			grid.add_child(option)
			row["edit"] = option
		"color":
			var holder := HBoxContainer.new()
			holder.custom_minimum_size = Vector2(130, 0)
			var picker := ColorPickerButton.new()
			picker.custom_minimum_size = Vector2(34, 0)
			picker.edit_alpha = true
			var edit := _make_line_edit(prop)
			picker.color_changed.connect(func(color: Color) -> void:
				if not _refreshing:
					model.set_property(prop, "#" + color.to_html(color.a < 1.0)))
			holder.add_child(picker)
			holder.add_child(edit)
			grid.add_child(holder)
			row["edit"] = edit
			row["picker"] = picker
		_:
			var edit := _make_line_edit(prop)
			edit.custom_minimum_size = Vector2(130, 0)
			grid.add_child(edit)
			row["edit"] = edit
	_rows[prop] = row


func _make_line_edit(prop: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.select_all_on_focus = true
	var commit := func(text: String) -> void:
		if _refreshing or text.strip_edges() == str(edit.get_meta("shown", "")):
			return
		model.set_property(prop, text)
	edit.text_submitted.connect(commit)
	edit.focus_exited.connect(func() -> void: commit.call(edit.text))
	return edit


# ---------------------------------------------------------------- showing the model

func _refresh() -> void:
	if _status_label == null:
		return
	_refreshing = true
	var selection := model.selection
	if selection.is_empty():
		_selection_label.text = "Nothing selected." if model.preview_ready else "Preview not running."
	else:
		var tag: String = selection.get("tag", "")
		var classes: Array = selection.get("classes", [])
		var shown: String = tag + ("#" + selection.id if str(selection.get("id", "")) != "" else "") + "".join(classes.map(func(c: String) -> String: return "." + c))
		var text: String = selection.get("text", "")
		_selection_label.text = "%s%s" % [shown, '  "%s"' % text if not text.is_empty() else ""]
	_refresh_rules()
	for prop: String in _rows:
		_refresh_row(prop)
	_undo_button.disabled = not model.can_undo()
	_save_button.disabled = not model.has_pending()
	_save_button.text = "Save (%d)" % model.pending.size() if model.has_pending() else "Save"
	_status_label.text = model.status
	_refreshing = false


func _refresh_rules() -> void:
	var rules: Array = model.selection.get("rules", [])
	var signature := str(rules.size()) + "|" + str(model.target_rule) + "|" + str(model.selection.get("selector", ""))
	if signature == _rules_signature:
		return
	_rules_signature = signature
	_rule_option.clear()
	_rule_option.add_item("Automatic")
	for rule: Dictionary in rules:
		var where: String = rule.file if str(rule.file) != "" else "(inline / <style>)"
		var conditions: Array = rule.get("conditions", [])
		_rule_option.add_item("%s  %s%s" % [rule.selector, where, "  " + ", ".join(conditions) if not conditions.is_empty() else ""])
		if str(rule.file) == "":
			_rule_option.set_item_disabled(_rule_option.item_count - 1, true)
	_rule_option.select(clampi(model.target_rule + 1, 0, _rule_option.item_count - 1))


func _refresh_row(prop: String) -> void:
	var row: Dictionary = _rows[prop]
	var editable := not model.selection.is_empty() and model.choose_rule(prop) >= 0
	var value := model.current_value(prop)
	var label: Label = row.label
	label.tooltip_text = model.target_description(prop) if not model.selection.is_empty() else ""
	var edit: Control = row.edit
	match row.kind:
		"enum":
			var option: OptionButton = edit
			option.disabled = not editable
			var found := -1
			for i in range(option.item_count):
				if option.get_item_text(i) == value.text:
					found = i
			if found == -1 and value.text != "":
				option.add_item(value.text)  # a value outside the common list (e.g. an authored keyword)
				found = option.item_count - 1
			option.select(found)
		_:
			var line: LineEdit = edit
			line.editable = editable
			if not line.has_focus():
				line.text = value.text
				line.set_meta("shown", value.text)
			line.modulate = Color(1, 1, 1, 1.0 if value.declared else 0.55)
			if row.kind == "color":
				var picker: ColorPickerButton = row.picker
				picker.disabled = not editable
				picker.color = _to_color(value.text, str(model.selection.get("computed", {}).get(prop, "")))
	label.modulate = Color(1, 1, 1, 1.0 if editable else 0.4)


## A CSS colour text as a Color; `fallback_text` (the computed rgb()) when it is not a literal (var(), etc.).
static func _to_color(text: String, fallback_text: String) -> Color:
	var parsed := _parse_css_color(text)
	return parsed if parsed != null else (_parse_css_color(fallback_text) if _parse_css_color(fallback_text) != null else Color.BLACK)


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
