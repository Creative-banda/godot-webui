extends SceneTree
## Run: godot --headless --path . -s res://tests/edit_link_test.gd
## Covers the editor's link to the preview (WebUIEditLink) over a real local TCP connection, with a
## plain client standing in for the preview program. Exit code = number of failures.

var failures := 0


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _initialize() -> void:
	await process_frame
	var link := WebUIEditLink.new()
	root.add_child(link)
	var got: Array = []
	var sessions: Array = []
	link.page_message.connect(func(p: Dictionary) -> void: got.append(p))
	link.session_changed.connect(func(running: bool) -> void: sessions.append(running))
	check(not link.send("apply", {}), "nothing to send to before a preview connects")

	link._server.listen(0, "127.0.0.1")
	var client := StreamPeerTCP.new()
	check(client.connect_to_host("127.0.0.1", link._server.get_local_port()) == OK, "a client can connect to the link's port")
	for i in range(60):
		client.poll()
		await process_frame
		if link.is_running():
			break
	check(link.is_running() and sessions == [true], "the link reports the preview as connected")

	client.put_data(('{"op":"ready"}\n{"op":"selected","selector":"#a"}\n{"op":"half').to_utf8_buffer())
	for i in range(30):
		await process_frame
	check(got.size() == 2 and got[0].op == "ready" and got[1].selector == "#a", "complete lines arrive as messages, a partial one waits")
	client.put_data('"}\n'.to_utf8_buffer())
	for i in range(30):
		await process_frame
	check(got.size() == 3 and got[2].op == "half", "the partial line completes later")
	client.put_data("not json\n[1,2]\n{\"nop\":1}\n".to_utf8_buffer())
	for i in range(30):
		await process_frame
	check(got.size() == 3, "garbage, non-objects and messages without an op are ignored")

	check(link.send("apply", {"prop": "color", "value": "red"}), "a command is sent")
	var text := ""
	for i in range(60):
		client.poll()
		var n := client.get_available_bytes()
		if n > 0:
			text += client.get_utf8_string(n)
		if text.contains("\n"):
			break
		await process_frame
	var parsed: Variant = JSON.parse_string(text.strip_edges())
	check(typeof(parsed) == TYPE_DICTIONARY and parsed.op == "apply" and parsed.payload.value == "red", "the preview receives it as one JSON line")

	client.disconnect_from_host()
	for i in range(60):
		await process_frame
		if not link.is_running():
			break
	check(not link.is_running() and sessions == [true, false], "closing the preview is noticed")
	link.stop()
	quit(failures)
