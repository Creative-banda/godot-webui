# Security Policy

## Supported versions

Godot WebUI is at an early stage (0.1.0). Only the latest commit on the default branch is considered for fixes.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability.

Use GitHub's private vulnerability reporting on this repository ("Security" tab → "Report a vulnerability"). If that option is not available, open a public issue that says you have a security concern, **without** exploit details, and the maintainer will arrange a private channel.

Helpful details: affected component (native plugin, GDScript bridge or `godot.js`), Godot and Android versions, and steps to reproduce.

## Scope

Relevant areas include: the JavaScript-to-native message bridge, local content serving and path handling, navigation and request blocking, and handling of malformed messages or payloads. The page content shown in the overlay is treated as potentially untrusted by design: it can only send validated events that you register handlers for.
