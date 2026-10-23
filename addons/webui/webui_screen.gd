@tool
class_name WebUIScreen
extends Control
## Marks a scene as showing an HTML page through Godot WebUI, and draws a preview of that page in the 2D
## editor so the scene is no longer an empty canvas. Add it as a child of the scene root, pick the .html
## file, and press Refresh Preview in the Inspector.
##
## It is an editor aid only. At runtime it hides itself and does nothing: it never creates a WebView, never
## starts the overlay, never takes input and never touches GodotWebUI, so the page is still shown by
## GodotWebUI.start() exactly as before. Scripts may read get_ui_dir() / get_page_file() to learn which page
## belongs to the scene instead of repeating the path.
##
## The preview is a static picture made by a separate program (WebUIScreenPreview, webui_preview_capture.gd)
## and kept in res://.godot/webui_previews/. It is NOT the Android rendering: see the limits in
## docs/desktop-preview.md. This script must stay free of editor-only classes (EditorInterface, ...): it is
## part of exported games.

signal status_changed

const POLL_IDLE_SECONDS := 2.0
const POLL_CAPTURE_SECONDS := 0.25
const CAPTURE_TIMEOUT_SECONDS := 45.0
const FRAME_COLOR := Color(0.4, 0.8, 1.0, 0.9)

## The HTML page this node stands for (a res:// file, normally inside your UI folder).
@export_file("*.html") var page := "":
	set(value):
		if value == page:
			return
		page = value
		_page_changed()
## Optional: show this PNG instead of the generated preview (a screenshot of your own, or a fallback when
## the capture cannot run on this machine).
@export_file("*.png") var manual_preview := "":
	set(value):
		manual_preview = value
		if is_inside_tree():
			_reload_preview()
## Draw the preview in the editor (never drawn at runtime).
@export var show_preview := true:
	set(value):
		show_preview = value
		queue_redraw()
## Draw the project's background color behind the preview. Off by default: the page is transparent where it
## has nothing, so the scene's own nodes stay visible through it, as they are under the real overlay.
@export var show_backdrop := false:
	set(value):
		show_backdrop = value
		queue_redraw()

var _texture: ImageTexture
var _meta := {}
var _state := ""             # see get_status()
var _problem := ""
var _capture_pid := -1
var _capture_started := 0.0
var _poll := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # never takes input, in the editor or in a game
	focus_mode = Control.FOCUS_NONE
	if not Engine.is_editor_hint():
		visible = false  # the game draws the page itself (GodotWebUI); this node only records which one
		set_process(false)
		return
	if not has_meta("_edit_lock_"):
		set_meta("_edit_lock_", true)  # a full-screen node would otherwise swallow clicks meant for the nodes behind it
		_cover_viewport()
	elif size.x < 1.0 or size.y < 1.0:
		_cover_viewport()
	_reload_preview()


## Makes the node the size of the game viewport: it fills a Control parent; under any other parent (a Node2D
## scene root, say) anchors have nothing to refer to in the editor, so the project's viewport size is used.
func _cover_viewport() -> void:
	if get_parent() is Control:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	else:
		set_anchors_preset(Control.PRESET_TOP_LEFT)
		position = Vector2.ZERO
		size = Vector2(WebUIScreenPreview.viewport_size())


func _exit_tree() -> void:
	_stop_capture()


# ---------------------------------------------------------------- what the node knows

## The folder of the page that GodotWebUI.start() takes, e.g. "res://ui" ("" when no page is assigned).
func get_ui_dir() -> String:
	return WebUIScreenPreview.ui_dir_for(page) if page != "" else ""


## The page's file name inside get_ui_dir(), e.g. "menu.html" (the second argument of GodotWebUI.start()).
func get_page_file() -> String:
	var dir := get_ui_dir()
	return page.trim_prefix(dir.path_join("")) if dir != "" else ""


## {"state", "text", "notes"}. States: no_page, invalid, no_preview, capturing, fresh, stale, failed, manual.
func get_status() -> Dictionary:
	if _state == "" and Engine.is_editor_hint() and is_inside_tree():
		_reload_preview()
	var notes: Array = _meta.get("notes", [])
	match _state:
		"no_page", "invalid":
			return {"state": _state, "text": _problem, "notes": []}
		"manual":
			return {"state": "manual", "text": "Showing your own preview image %s." % manual_preview.get_file(), "notes": []}
		"no_preview":
			return {"state": _state, "text": "No preview yet. Press Refresh Preview.", "notes": []}
		"capturing":
			return {"state": _state, "text": "Capturing the preview (%d s)..." % int(_now() - _capture_started), "notes": []}
		"failed":
			return {"state": _state, "text": "Capture failed: %s" % _problem, "notes": []}
		"stale":
			return {"state": _state, "text": "The page changed since this preview was made. Press Refresh Preview.", "notes": notes}
		"fresh":
			var size: Array = _meta.get("size", [0, 0])
			return {"state": _state, "text": "Preview is up to date (%d x %d)." % [int(size[0]), int(size[1])], "notes": notes}
	return {"state": _state, "text": "", "notes": []}


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if _state in ["no_page", "invalid"]:
		warnings.append(_problem)
	return warnings


# ---------------------------------------------------------------- refreshing

## Makes a new preview of the page in a separate program and shows it when it is done. Returns false (the
## reason is in get_status()) when there is nothing to capture.
func refresh_preview() -> bool:
	if not Engine.is_editor_hint():
		return false
	_problem = WebUIScreenPreview.page_problem(page)
	if _problem != "":
		_set_state("no_page" if page.strip_edges() == "" else "invalid")
		return false
	_stop_capture()
	var size := WebUIScreenPreview.viewport_size()
	DirAccess.remove_absolute(WebUIScreenPreview.cache_meta(page))  # a half-made preview must not look finished
	_capture_pid = WebUIScreenPreview.start_capture(page, size)
	if _capture_pid <= 0:
		_capture_pid = -1
		_problem = "the capture program could not be started."
		_set_state("failed")
		return false
	_capture_started = _now()
	_poll = 0.0
	_set_state("capturing")
	set_process(true)
	return true


func _process(delta: float) -> void:
	_poll += delta
	if _capture_pid > 0:
		if _poll < POLL_CAPTURE_SECONDS:
			return
		_poll = 0.0
		if OS.is_process_running(_capture_pid):
			if _now() - _capture_started > CAPTURE_TIMEOUT_SECONDS:
				_stop_capture()
				_problem = "timed out after %d seconds." % int(CAPTURE_TIMEOUT_SECONDS)
				_set_state("failed")
			else:
				status_changed.emit()  # the seconds counter
			return
		_capture_pid = -1
		_finish_capture()
		return
	if _poll < POLL_IDLE_SECONDS:
		return
	_poll = 0.0
	_check_stale()


func _finish_capture() -> void:
	var meta := WebUIScreenPreview.read_meta(page)
	if meta.is_empty():
		_problem = "the capture program ended without a result."
		_set_state("failed")
		return
	if not meta.get("ok", false):
		_problem = str(meta.get("error", "unknown error"))
		_set_state("failed")
		return
	_reload_preview()


func _stop_capture() -> void:
	if _capture_pid > 0 and OS.is_process_running(_capture_pid):
		OS.kill(_capture_pid)
	_capture_pid = -1


func _check_stale() -> void:
	if _state not in ["fresh", "stale"] or page == "":
		return
	var current := WebUIScreenPreview.signature(page, WebUIScreenPreview.viewport_size())
	var next := "fresh" if str(_meta.get("signature", "")) == current else "stale"
	if next != _state:
		_set_state(next)


# ---------------------------------------------------------------- showing the preview

func _page_changed() -> void:
	if not is_inside_tree() or not Engine.is_editor_hint():
		return
	_stop_capture()
	_reload_preview()
	update_configuration_warnings()


func _reload_preview() -> void:
	_texture = null
	_meta = {}
	_problem = WebUIScreenPreview.page_problem(page)
	if _problem != "":
		_set_state("no_page" if page.strip_edges() == "" else "invalid")
		return
	if manual_preview != "":
		_texture = WebUIScreenPreview.load_texture(manual_preview)
		if _texture != null:
			_set_state("manual")
			return
	_meta = WebUIScreenPreview.read_meta(page)
	if _meta.get("ok", false):
		_texture = WebUIScreenPreview.load_texture(WebUIScreenPreview.cache_png(page))
	if _texture == null:
		_meta = {}
		_set_state("no_preview")
		return
	var current := WebUIScreenPreview.signature(page, WebUIScreenPreview.viewport_size())
	_set_state("fresh" if str(_meta.get("signature", "")) == current else "stale")


func _set_state(state: String) -> void:
	_state = state
	queue_redraw()
	status_changed.emit()
	if Engine.is_editor_hint() and is_inside_tree():
		update_configuration_warnings()


func _draw() -> void:
	if not Engine.is_editor_hint() or not show_preview:
		return
	# A node that was already open when this script was reloaded (or saved by an older version) has not gone
	# through _ready(): bring it up to date here instead of drawing nothing.
	if _state == "":
		_reload_preview()
	var rect := Rect2(Vector2.ZERO, size)
	if rect.size.x <= 1.0 or rect.size.y <= 1.0:
		# Anchors resolve to nothing under a non-Control parent (a Node2D scene root): cover the viewport.
		_cover_viewport.call_deferred()
		rect = Rect2(Vector2.ZERO, Vector2(WebUIScreenPreview.viewport_size()))
	if show_backdrop or _texture == null:
		# Only a placeholder (no picture yet) or an explicit choice gets a backdrop: a filled rectangle would hide
		# the nodes of the scene that the transparent page is meant to sit above.
		draw_rect(rect, ProjectSettings.get_setting("rendering/environment/defaults/default_clear_color", Color(0.3, 0.3, 0.3)))
	if _texture != null:
		draw_texture_rect(_texture, _fit(rect, _texture.get_size()), false)
	else:
		_draw_placeholder(rect)
	draw_rect(rect, FRAME_COLOR, false, 2.0)
	var status := get_status()
	var label := "WebUI  %s" % (page.get_file() if page != "" else "(no page)")
	if _state == "stale":
		label += "  (out of date)"
	elif _state == "capturing":
		label += "  (capturing...)"
	_draw_tag(label, rect.position + Vector2(0, -30), _state in ["stale", "failed", "invalid"])  # above the frame: never over the page


## `inner` fitted into `outer`, centered, keeping its aspect ratio.
static func _fit(outer: Rect2, inner: Vector2) -> Rect2:
	if inner.x <= 0.0 or inner.y <= 0.0:
		return outer
	var scale := minf(outer.size.x / inner.x, outer.size.y / inner.y)
	var fitted := inner * scale
	return Rect2(outer.position + (outer.size - fitted) * 0.5, fitted)


func _draw_placeholder(rect: Rect2) -> void:
	var step := 48.0
	var x := -rect.size.y
	while x < rect.size.x:
		draw_line(Vector2(x, rect.size.y), Vector2(x + rect.size.y, 0.0), Color(1, 1, 1, 0.06), 2.0)
		x += step
	var font := ThemeDB.fallback_font
	var lines := PackedStringArray()
	match _state:
		"no_page", "invalid":
			lines = PackedStringArray(["WebUI screen", _problem])
		"failed":
			lines = PackedStringArray(["Preview failed", _problem])
		"capturing":
			lines = PackedStringArray(["Making the preview...", page.get_file()])
		_:
			lines = PackedStringArray(["WebUI screen: " + page.get_file(), "No preview yet. Press Refresh Preview in the Inspector."])
	var y := rect.size.y * 0.5 - 14.0 * lines.size()
	for i in range(lines.size()):
		var font_size := 28 if i == 0 else 18
		var text_size := font.get_string_size(lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		draw_string(font, Vector2((rect.size.x - text_size.x) * 0.5, y + i * 34.0), lines[i], HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 24.0, font_size, Color(1, 1, 1, 0.85))


func _draw_tag(text: String, at: Vector2, warn: bool) -> void:
	var font := ThemeDB.fallback_font
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16)
	var box := Rect2(at, text_size + Vector2(14, 8))
	draw_rect(box, Color(0.95, 0.6, 0.15, 0.92) if warn else Color(0.1, 0.45, 0.7, 0.92))
	draw_string(font, at + Vector2(7, 4 + font.get_ascent(16)), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
