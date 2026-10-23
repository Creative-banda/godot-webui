# Setup

One command prepares the environment, and it tells you plainly what it cannot do for you.

```bash
python tools/setup.py          # Windows: python tools\setup.py
```

Requirements for the script itself: Python 3.8 or newer. It uses only the standard library, so there is nothing to `pip install`.

It does two things:

1. **Installs** the optional desktop-preview dependency (godot_wry, pinned and checksum-verified) into a user-level folder outside every Godot project.
2. **Checks** everything else (Godot, JDK, Android SDK, export templates, build template, keystore, export preset) and prints what is missing and how to fix it. It does not install those: they belong to Godot and Android tooling and need your choices (SDK location, signing keys).

It exits with status 1 if a required prerequisite is missing, 0 otherwise.

## What is needed for what

| You want to... | You need | Installed by the script? |
|---|---|---|
| **Run the game on an Android device** (runtime) | Nothing beyond the addon: `addons/webui/bin/WebUI-debug.aar` and `WebUI-release.aar` (tracked in the repository) are packaged into the APK by the export plugin | No install needed; the script checks the files exist |
| **Export for Android** | Godot 4.7.1, its export templates, JDK 17, Android SDK with the platform / build-tools / NDK the template asks for (Godot 4.7.1: platform 36, build-tools 36.1.0, NDK 29.0.14206865; the script reads these from your installed template), a debug keystore, the Android build template in the project, *Use Gradle Build* on | No. Checked and explained |
| **Preview the UI on desktop** (F5/F6, optional) | godot_wry v0.2.0 in a user-level folder; WebView2 on Windows; WebKitGTK and X11 on Linux | **Yes**: `python tools/setup.py wry` (also part of the default run) |
| **Rebuild the native plugin** (only if you edit Java) | JDK 17, Android platform 35, build-tools 35.0.1, internet for Gradle | No. `cd native/android && ./gradlew copyToAddon` |

These categories are separate: the Android runtime and export never need godot_wry, and godot_wry is never part of an Android export.

## Commands

| Command | Purpose |
|---|---|
| `python tools/setup.py` | Install/verify godot_wry, then run `doctor` |
| `python tools/setup.py doctor` | Checks only; changes nothing |
| `python tools/setup.py wry` | Install, verify or repair godot_wry. `--force` reinstalls, `--archive PATH` uses a zip you downloaded yourself (still hash-checked), `--target DIR` overrides the folder |
| `python tools/setup.py add-to-project PATH` | Copy the addon into another Godot 4 project. `--enable-plugin` also enables it in that project's `project.godot` (backed up first; close the editor before running); `--with-skill [DIR]` also installs the AI-agent skill |
| `python tools/setup.py install-skill DIR` | Copy `skills/godot-webui` into a skills directory (`--claude-user` uses `~/.claude/skills`) |

Common options (before or after the command): `--godot PATH` (editor executable for the version check; or set `GODOT`), `--project PATH` (project to check, default this repository), `--cache DIR` (download cache, default `tools/.cache/`, git-ignored).

## Where godot_wry goes, and why

| OS | Folder |
|---|---|
| Windows | `%APPDATA%\godot_webui\godot_wry` (tested) |
| macOS | `~/Library/Application Support/godot_webui/godot_wry` (not tested) |
| Linux | `${XDG_DATA_HOME:-~/.local/share}/godot_webui/godot_wry` (not tested) |

Override with the environment variable `GODOT_WEBUI_WRY` (a folder, or the `WRY.gdextension` file); the addon honours the same variable. The addon loads the extension from there at run time. It must stay **outside** the project: an extension inside `res://` is packaged into Android exports by Godot's built-in GDExtension handling (the export fails when its Android libraries are missing), and an export plugin cannot prevent that. The script warns if it finds `addons/godot_wry` inside the project; delete that folder.

Only the files for your own OS are installed (plus `WRY.gdextension`), and a small `INSTALL.json` records the version and a SHA-256 of every installed file.

## Versions and integrity

Pinned in `tools/dependencies.json`: godot_wry `v0.2.0` from the project's GitHub release, with the archive's SHA-256 (`3df4a42f...4c6d`) and size. The archive is verified after download and again before installing; a mismatch is refused and nothing is installed. The release page publishes no checksums, so the pin is from an archive that was downloaded, inspected (no unsafe paths; the Windows DLL contains no unexpected URLs) and tested here. godot_wry is third-party native code that runs inside the editor and the game process: review it before trusting it, and re-check the hash if you ever update the pin (change `version`, `url`, `sha256` and `size` together).

## Running it again

Safe to repeat. A verified installation is left alone ("already installed"). A missing, damaged or hand-installed copy is repaired; an older pin is replaced. The new copy is built next to the old one and swapped in, with rollback on failure. If a file is locked (Godot or a game still running with the extension loaded) the script stops with "Close Godot and any running game, then run again" and leaves the old copy in place.

## Verify

1. `python tools/setup.py doctor` shows no `[XX]` lines. (`[ok]` fine, `[!]` advice, `[--]` information.)
2. Run the tests (they use fake backends and need no device):
   ```bash
   python -m unittest discover -s tests -p "test_setup.py"
   godot --headless --path . --import --quit
   godot --headless --path . -s res://tests/headless_test.gd
   godot --headless --path . -s res://tests/api_test.gd
   ```
3. Open this project in Godot 4.7.1 and press F6 on `examples/minimal_hud/minimal.tscn`: the HTML HUD appears over the game, the Attack button changes the dummy's health. That is the desktop preview, not an Android run.

## When something fails

| Message | Cause and fix |
|---|---|
| `SHA-256 mismatch ...` | The download is corrupt or the release changed. Delete `tools/.cache/` and retry; if it persists, inspect the release before changing the pin. Nothing was installed. |
| `could not download ...` | No network, proxy or GitHub outage (the script retried 3 times). Download `godot_wry.zip` from the release page in a browser and run `python tools/setup.py wry --archive PATH_TO_ZIP`. |
| `cannot replace ... Close Godot` | A running Godot or game holds the DLL. Close it and run again. |
| `no godot_wry build is pinned for <os>/<machine>` | Unsupported OS/CPU for the pin (Windows x86_64, Linux x86_64 and macOS are pinned). The preview is optional; Android work does not need it. |
| `[XX] Android SDK not found` / `SDK is missing ...` | Install the SDK and set *Editor Settings > Export > Android > Android SDK Path*; the script prints the exact `sdkmanager` packages the export template needs. |
| `[XX] export templates not found` | In Godot: *Editor > Manage Export Templates > Download and Install* (version 4.7.1). |
| `[XX] JDK not found` / `[!] JDK n found` | Install JDK 17 and set *Editor Settings > Export > Android > Java SDK Path*. |
| `[!] no debug keystore` | Create one with the printed `keytool` command and set it in the editor settings. |
| `[!] Android build template not installed` | *Project > Install Android Build Template* (once per project). |
| `addons/godot_wry is inside the project` | Delete it; run `python tools/setup.py wry` for the supported location. |

Manual fallback for the preview dependency (no script): extract the contents of the archive's `addons/godot_wry/` folder into the folder in the table above (for your OS only `bin/<your platform>` is needed) and make sure `WRY.gdextension` sits directly inside it.

## Using the addon in your own game

```bash
python tools/setup.py add-to-project /path/to/your/game --enable-plugin --with-skill
```

Then, in that project: *Project > Install Android Build Template*, *Project > Export > Android > Use Gradle Build*, put your UI in a folder with an `index.html` (outside `addons/`), and add `.webui_preview/` to its `.gitignore`. No export filter is needed. Without `--enable-plugin`, enable *godot-webui* under *Project Settings > Plugins* yourself.

## Teaching an AI coding agent

The skill lives in `skills/godot-webui/` (`SKILL.md` plus `references/`). Options:

- **Claude Code:** copy it to `<project>/.claude/skills/godot-webui` (`python tools/setup.py install-skill <project>/.claude/skills`, or `add-to-project ... --with-skill`) or to `~/.claude/skills/godot-webui` (`install-skill --claude-user`). Claude Code discovers skills in those folders.
- **Other agents:** most read an instruction file (`AGENTS.md`, `CLAUDE.md`, rules files). Point it at the skill: "For UI work with the Godot WebUI addon, read `skills/godot-webui/SKILL.md` first and follow it." This repository's `AGENTS.md` already does. Discovery directories differ between agents; this is not a standard the script can assume.
- The skill folder is self-contained and contains a `.gdignore`, so it is safe to place inside a Godot project.
