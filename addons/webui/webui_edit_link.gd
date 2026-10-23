@tool
class_name WebUIEditLink
extends Node
## Editor side of the link to the edit preview. The preview runs as its own program (the Godot
## executable on webui_edit_preview.tscn) in a normal window, not as the editor's "play" game: a game
## played from the editor can be embedded in the editor's Game workspace, where it cannot stay above
## the editor, and the editor's debugger channel only exists for that kind of game.
##
## Messages are one JSON object per line over a TCP connection on 127.0.0.1:
##   preview -> editor  {"op": ..., ...}               the page's edit-mode messages (see edit_mode.js)
##   editor -> preview  {"op": "apply"|"select"|..., "payload": {...}}
## The editor listens on a free port and passes it to the preview on its command line. The connection
## never leaves this computer.

const SCENE := "res://addons/webui/webui_edit_preview.tscn"
const PORT_ARG := "--webui-edit-port"

## A page message from the preview: a Dictionary with an "op".
signal page_message(payload: Dictionary)
## The preview connected (true) or went away (false).
signal session_changed(running: bool)

var _server := TCPServer.new()
var _peer: StreamPeerTCP
var _pid := -1
var _buffer := ""
var _connected := false


## Starts (or restarts) the preview window. Returns false if the program could not be started.
func launch() -> bool:
	stop()
	if _server.listen(0, "127.0.0.1") != OK:
		return false
	var args := PackedStringArray(["--path", ProjectSettings.globalize_path("res://"), SCENE, "--", PORT_ARG, str(_server.get_local_port())])
	_pid = OS.create_process(OS.get_executable_path(), args)
	if _pid <= 0:
		_server.stop()
		_pid = -1
		return false
	return true


func is_running() -> bool:
	return _connected


## Closes the preview window and the connection.
func stop() -> void:
	var was_connected := _connected
	if _peer:
		_peer.disconnect_from_host()
		_peer = null
	_connected = false
	_buffer = ""
	_server.stop()
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1
	if was_connected:
		session_changed.emit(false)


## Sends a command to the preview. Returns false when no preview is connected.
func send(op: String, payload: Dictionary) -> bool:
	if not _connected or _peer == null:
		return false
	var line := JSON.stringify({"op": op, "payload": payload}) + "\n"
	return _peer.put_data(line.to_utf8_buffer()) == OK


func _exit_tree() -> void:
	stop()


func _process(_delta: float) -> void:
	if _server.is_listening() and _server.is_connection_available():
		_peer = _server.take_connection()
		_server.stop()  # one preview at a time
	if _peer == null:
		if _pid > 0 and not OS.is_process_running(_pid):  # it never connected (for example it crashed on start)
			_pid = -1
			_server.stop()
			session_changed.emit(false)
		return
	_peer.poll()
	match _peer.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			if not _connected:
				_connected = true
				session_changed.emit(true)
			var available := _peer.get_available_bytes()
			if available > 0:
				_buffer += _peer.get_utf8_string(available)
				_drain()
		StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
			var was_connected := _connected
			_peer = null
			_connected = false
			_buffer = ""
			_pid = -1
			if was_connected:
				session_changed.emit(false)


func _drain() -> void:
	while true:
		var newline := _buffer.find("\n")
		if newline < 0:
			return
		var line := _buffer.substr(0, newline)
		_buffer = _buffer.substr(newline + 1)
		var data: Variant = JSON.parse_string(line)
		if typeof(data) == TYPE_DICTIONARY and typeof(data.get("op")) == TYPE_STRING:
			page_message.emit(data)
