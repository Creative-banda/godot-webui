#!/usr/bin/env python3
"""Godot WebUI setup helper (Python 3.8+, standard library only).

    python tools/setup.py                       install the desktop-preview dependency, then run the checks
    python tools/setup.py doctor                only run the checks
    python tools/setup.py wry [--force]         install / verify / repair the godot_wry desktop-preview extension
    python tools/setup.py add-to-project PATH   copy the addon into another Godot project (see --help)
    python tools/setup.py install-skill DIR     copy the AI-agent skill into a skills directory

What it installs: only godot_wry (pinned version, SHA-256 verified), into a user-level folder OUTSIDE any Godot
project, so it can never be packaged into an Android export. What it only checks and explains: JDK, Android SDK,
Godot export templates, the Android build template, the debug keystore. See docs/setup.md.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEPS = json.loads(Path(__file__).with_name("dependencies.json").read_text(encoding="utf-8"))
PLUGIN_CFG = "res://addons/webui/plugin.cfg"
SKILL_NAME = "godot-webui"
MARKER = "INSTALL.json"


class SetupError(Exception):
    """A problem the user can act on; printed without a traceback."""


# ---------------------------------------------------------------- output

class Report:
    def __init__(self) -> None:
        self.problems = 0
        self.warnings = 0

    def ok(self, text: str) -> None:
        print("  [ok] " + text)

    def info(self, text: str) -> None:
        print("  [--] " + text)

    def warn(self, text: str) -> None:
        self.warnings += 1
        print("  [!]  " + text)

    def fail(self, text: str) -> None:
        self.problems += 1
        print("  [XX] " + text)

    def fix(self, text: str) -> None:
        for line in text.splitlines():
            print("         " + line)


def heading(text: str) -> None:
    print("\n" + text)


# ---------------------------------------------------------------- platform helpers

def host_os() -> str:
    if sys.platform.startswith("win"):
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    if sys.platform.startswith("linux"):
        return "linux"
    return sys.platform


def data_dir() -> Path:
    """Same folder as Godot's OS.get_data_dir()."""
    system = host_os()
    if system == "windows":
        return Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming")
    if system == "macos":
        return Path.home() / "Library" / "Application Support"
    return Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")


def godot_config_dir() -> Path:
    system = host_os()
    if system == "windows":
        return data_dir() / "Godot"
    if system == "macos":
        return data_dir() / "Godot"
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "godot"


def godot_templates_dir() -> Path:
    system = host_os()
    if system == "linux":
        return data_dir() / "godot" / "export_templates"
    return data_dir() / "Godot" / "export_templates"


def default_wry_target() -> Path:
    env = os.environ.get("GODOT_WEBUI_WRY", "").strip()
    if env:
        path = Path(env)
        return path.parent if path.suffix == ".gdextension" else path
    return data_dir() / "godot_webui" / "godot_wry"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


# ---------------------------------------------------------------- download

def download(url: str, dest: Path, size: int, sha256: str, attempts: int = 3) -> None:
    """Download to dest, verifying size and SHA-256. Leaves no partial file behind."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    last_error = ""
    for attempt in range(1, attempts + 1):
        try:
            print("  downloading %s (attempt %d/%d)" % (url, attempt, attempts))
            request = urllib.request.Request(url, headers={"User-Agent": "godot-webui-setup"})
            with urllib.request.urlopen(request, timeout=30) as response, open(part, "wb") as out:
                digest = hashlib.sha256()
                received = 0
                next_report = 0
                while True:
                    chunk = response.read(256 * 1024)
                    if not chunk:
                        break
                    out.write(chunk)
                    digest.update(chunk)
                    received += len(chunk)
                    if size and received >= next_report:
                        print("\r  %3d%% (%d / %d bytes)" % (received * 100 // size, received, size), end="", flush=True)
                        next_report = received + max(size // 20, 1)
                print()
            if size and received != size:
                raise SetupError("size mismatch: got %d bytes, expected %d (interrupted download?)" % (received, size))
            if digest.hexdigest() != sha256:
                part.unlink(missing_ok=True)
                raise SetupError(
                    "SHA-256 mismatch for the downloaded file.\n  expected %s\n  actual   %s\n"
                    "Refusing to use it: the release asset changed or the download was tampered with. "
                    "Check %s manually before updating tools/dependencies.json." % (sha256, digest.hexdigest(), url))
            part.replace(dest)
            return
        except SetupError as error:
            part.unlink(missing_ok=True)
            if "SHA-256 mismatch" in str(error):
                raise
            last_error = str(error)
        except (urllib.error.URLError, OSError, TimeoutError) as error:
            last_error = str(getattr(error, "reason", error))
            part.unlink(missing_ok=True)
        if attempt < attempts:
            time.sleep(2 * attempt)
    raise SetupError(
        "could not download %s: %s\nManual fallback: download the file in a browser, then run\n"
        "  python tools/setup.py wry --archive PATH_TO_godot_wry.zip\n(the file is still checked against the pinned SHA-256)." % (url, last_error))


# ---------------------------------------------------------------- godot_wry

def wry_platform() -> dict:
    spec = DEPS["godot_wry"]
    system = host_os()
    entry = spec["platforms"].get(system)
    machine = platform.machine().lower()
    if not entry or machine not in entry["machines"]:
        raise SetupError(
            "no godot_wry build is pinned for %s/%s (supported: Windows x86_64, Linux x86_64, macOS). "
            "The desktop preview is optional; Android work does not need it." % (system, machine or "unknown"))
    return entry


def wanted_members(names: list, lib_dir: str, root: str) -> list:
    """Archive members to install: top-level files, icons, and the library folder for this OS."""
    wanted = []
    for name in names:
        if name.endswith("/") or not name.startswith(root):
            continue
        rel = name[len(root):]
        parts = rel.split("/")
        if ".." in parts or rel.startswith("/") or ":" in parts[0]:
            raise SetupError("unsafe path in archive: %s" % name)
        if rel.startswith(("examples/", "android/")):
            continue
        if rel.startswith("bin/") and not rel.startswith(lib_dir + "/"):
            continue
        wanted.append(name)
    return wanted


def installed_state(target: Path) -> tuple:
    """Returns (status, detail): 'missing', 'unmanaged', 'broken' or 'ok'."""
    if not target.exists():
        return "missing", "folder does not exist"
    marker = target / MARKER
    if not marker.exists():
        return "unmanaged", "no %s marker (installed by hand or by an older script)" % MARKER
    try:
        data = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return "broken", "unreadable %s" % MARKER
    spec = DEPS["godot_wry"]
    if data.get("version") != spec["version"] or data.get("archive_sha256") != spec["sha256"]:
        return "broken", "installed %s, pinned %s" % (data.get("version"), spec["version"])
    if data.get("platform") != host_os():
        return "broken", "installed for %s" % data.get("platform")
    for rel, expected in data.get("files", {}).items():
        file = target / rel
        if not file.is_file():
            return "broken", "missing file %s" % rel
        if sha256_file(file) != expected:
            return "broken", "file changed: %s" % rel
    return "ok", "%d files verified" % len(data.get("files", {}))


def install_wry(target: Path, archive: Path | None, cache: Path, force: bool) -> None:
    spec = DEPS["godot_wry"]
    entry = wry_platform()
    heading("godot_wry %s (desktop preview only)" % spec["version"])
    print("  target: %s" % target)

    in_project = ROOT / "addons" / "godot_wry"
    if in_project.exists():
        print("  [!]  %s exists. godot_wry must not live inside a Godot project (Android exports would package"
              " or fail on it). Delete that folder; the preview loads the copy at the target above." % in_project)

    state, detail = installed_state(target)
    if state == "ok" and not force:
        print("  [ok] already installed and verified (%s). Use --force to reinstall." % detail)
        return
    if state != "missing":
        print("  %s (%s): will %s." % (state, detail, "reinstall" if force else "repair"))

    if archive is None:
        archive = cache / ("godot_wry-%s.zip" % spec["version"])
        if archive.exists() and sha256_file(archive) != spec["sha256"]:
            print("  cached archive failed verification; discarding it")
            archive.unlink()
        if not archive.exists():
            download(spec["url"], archive, spec["size"], spec["sha256"])
        else:
            print("  using cached archive %s" % archive)
    elif not archive.is_file():
        raise SetupError("archive not found: %s" % archive)
    actual = sha256_file(archive)
    if actual != spec["sha256"]:
        raise SetupError("SHA-256 of %s is %s but %s is pinned for godot_wry %s. Refusing to install it."
                         % (archive, actual, spec["sha256"], spec["version"]))
    print("  archive verified (sha256 %s...)" % actual[:12])

    parent = target.parent
    parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".godot_wry_new_", dir=parent))
    backup = None
    try:
        files = {}
        with zipfile.ZipFile(archive) as bundle:
            members = wanted_members(bundle.namelist(), entry["lib_dir"], spec["archive_root"])
            if not any(m.endswith(".gdextension") for m in members):
                raise SetupError("the archive has no WRY.gdextension; unexpected layout")
            for name in members:
                rel = name[len(spec["archive_root"]):]
                out = staging / rel
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_bytes(bundle.read(name))
                files[rel] = sha256_file(out)
        if not any(rel.startswith(entry["lib_dir"] + "/") for rel in files):
            raise SetupError("the archive has no library for this OS under %s" % entry["lib_dir"])
        (staging / MARKER).write_text(json.dumps({
            "package": "godot_wry", "version": spec["version"], "archive_sha256": spec["sha256"],
            "platform": host_os(), "files": files}, indent=2), encoding="utf-8")
        if target.exists():
            backup = target.with_name(target.name + ".old")
            if backup.exists():
                shutil.rmtree(backup)
            target.rename(backup)
        staging.rename(target)
        staging = None
        if backup is not None:
            shutil.rmtree(backup, ignore_errors=True)
    except PermissionError as error:
        if backup is not None and not target.exists():
            backup.rename(target)
        raise SetupError("cannot replace %s (%s). Close Godot and any running game, then run again." % (target, error))
    except Exception:
        if backup is not None and not target.exists() and backup.exists():
            backup.rename(target)
        raise
    finally:
        if staging is not None:
            shutil.rmtree(staging, ignore_errors=True)

    state, detail = installed_state(target)
    if state != "ok":
        raise SetupError("installation finished but verification failed: %s" % detail)
    print("  [ok] installed and verified (%s)" % detail)
    if not entry["tested"]:
        print("  [!]  this OS is installed from the same pinned archive but has not been tested here.")
    if host_os() == "linux":
        print("  [!]  Linux also needs WebKitGTK installed and an X11 session.")


# ---------------------------------------------------------------- doctor

def find_godot(explicit: str | None) -> str | None:
    candidates = [explicit, os.environ.get("GODOT")]
    for name in ("godot", "godot4", "Godot"):
        candidates.append(shutil.which(name))
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return candidate
    return None


def run_text(command: list) -> str:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return ""
    return (result.stdout + result.stderr).strip()


def java_major() -> tuple:
    java = None
    home = os.environ.get("JAVA_HOME")
    if home:
        candidate = Path(home) / "bin" / ("java.exe" if host_os() == "windows" else "java")
        if candidate.exists():
            java = str(candidate)
    java = java or shutil.which("java")
    if not java:
        return None, None
    text = run_text([java, "-version"])
    match = re.search(r'version "(\d+)(?:\.(\d+))?', text)
    if not match:
        return java, None
    major = int(match.group(1))
    if major == 1 and match.group(2):
        major = int(match.group(2))
    return java, major


def editor_setting(name: str) -> str | None:
    """Reads a string from Godot's 4.x editor settings, if present."""
    config = godot_config_dir()
    candidates = sorted(config.glob("editor_settings-4*.tres"), reverse=True) if config.exists() else []
    pattern = re.compile(r'^%s\s*=\s*"(.*)"\s*$' % re.escape(name), re.M)
    for file in candidates:
        try:
            match = pattern.search(file.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
        if match and match.group(1):
            return match.group(1)
    return None


def template_requirements(template_dir: Path) -> dict:
    """compileSdk / buildTools / ndkVersion from the Android template's config.gradle."""
    archive = template_dir / "android_source.zip"
    if not archive.exists():
        return {}
    try:
        with zipfile.ZipFile(archive) as bundle:
            text = bundle.read("config.gradle").decode("utf-8", errors="replace")
    except (OSError, KeyError, zipfile.BadZipFile):
        return {}
    found = {}
    for key, pattern in (("compileSdk", r"compileSdk\s*:\s*(\d+)"), ("buildTools", r"buildTools\s*:\s*'([^']+)'"),
                         ("ndk", r"ndkVersion\s*:\s*'([^']+)'")):
        match = re.search(pattern, text)
        if match:
            found[key] = match.group(1)
    return found


def check_android_sdk(report: Report, needs: dict) -> None:
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or editor_setting("export/android/android_sdk_path")
    if not sdk or not Path(sdk).is_dir():
        report.fail("Android SDK not found (looked at ANDROID_HOME, ANDROID_SDK_ROOT and Godot's editor settings).")
        report.fix("Install the Android SDK (Android Studio or the command-line tools), then set\n"
                   "Editor Settings > Export > Android > Android SDK Path in Godot.")
        return
    sdk_path = Path(sdk)
    report.ok("Android SDK: %s" % sdk_path)
    missing = []
    if "compileSdk" in needs and not (sdk_path / "platforms" / ("android-" + needs["compileSdk"])).is_dir():
        missing.append("platforms;android-%s" % needs["compileSdk"])
    if "buildTools" in needs and not (sdk_path / "build-tools" / needs["buildTools"]).is_dir():
        missing.append("build-tools;%s" % needs["buildTools"])
    if "ndk" in needs and not (sdk_path / "ndk" / needs["ndk"]).is_dir():
        missing.append("ndk;%s" % needs["ndk"])
    if needs and not missing:
        report.ok("SDK has what the export template asks for (platform %s, build-tools %s, NDK %s)"
                  % (needs.get("compileSdk"), needs.get("buildTools"), needs.get("ndk")))
    elif missing:
        report.fail("SDK is missing: %s" % ", ".join(missing))
        report.fix('sdkmanager "%s"' % '" "'.join(missing))
    if not (sdk_path / "platform-tools").is_dir():
        report.warn("platform-tools (adb) not found in the SDK; needed to run on a device.")


def doctor(project: Path, godot: str | None, wry_target: Path) -> Report:
    report = Report()
    system = host_os()

    heading("Godot")
    exe = find_godot(godot)
    if exe:
        version = run_text([exe, "--version"]).splitlines()[0] if run_text([exe, "--version"]) else ""
        minor = DEPS["godot"]["supported_minor"]
        if version.startswith(minor):
            report.ok("%s (%s)" % (version, exe))
        elif version:
            report.warn("%s found, but this addon targets %s (tested %s)." % (version, minor, DEPS["godot"]["tested"]))
        else:
            report.warn("could not read the version of %s" % exe)
    else:
        report.info("Godot executable not found on PATH (optional: set GODOT or pass --godot PATH for the test run).")

    heading("Android runtime (the shipped game)")
    aars = [project / "addons" / "webui" / "bin" / name for name in ("WebUI-debug.aar", "WebUI-release.aar")]
    if all(a.exists() for a in aars):
        report.ok("native plugin AARs present in addons/webui/bin; nothing to install for the device runtime")
    else:
        report.fail("addons/webui/bin/WebUI-*.aar missing; the Android export cannot include the native plugin")
        report.fix("Restore them from the repository, or rebuild: cd native/android && ./gradlew copyToAddon")

    heading("Android export (Godot's own requirements; not installed by this script)")
    java, major = java_major()
    wanted_java = DEPS["java"]["major"]
    if not java:
        report.fail("JDK not found (Godot's Android export needs JDK %d)." % wanted_java)
        report.fix("Install a JDK %d and set Editor Settings > Export > Android > Java SDK Path." % wanted_java)
    elif major == wanted_java:
        report.ok("JDK %d (%s)" % (major, java))
    else:
        report.warn("JDK %s found (%s); Godot's Android export expects JDK %d." % (major, java, wanted_java))

    tested = DEPS["godot"]["tested"]
    templates = godot_templates_dir() / tested
    needs = {}
    if (templates / "android_source.zip").exists() and (templates / "android_debug.apk").exists():
        report.ok("export templates %s: %s" % (tested, templates))
        needs = template_requirements(templates)
    else:
        report.fail("Godot %s export templates not found at %s" % (tested, templates))
        report.fix("In the Godot editor: Editor > Manage Export Templates > Download and Install.")
    check_android_sdk(report, needs)

    keystore = editor_setting("export/android/debug_keystore")
    if keystore and Path(keystore).is_file():
        report.ok("debug keystore: %s" % keystore)
    elif (Path.home() / ".android" / "debug.keystore").is_file():
        report.warn("~/.android/debug.keystore exists but Godot's editor settings do not point at it "
                    "(Editor Settings > Export > Android > Debug Keystore).")
    else:
        report.warn("no debug keystore configured (needed to run on a device).")
        report.fix('keytool -keyalg RSA -genkeypair -alias androiddebugkey -keypass android -keystore debug.keystore '
                   '-storepass android -dname "CN=Android Debug,O=Android,C=US" -validity 9999 -deststoretype pkcs12\n'
                   "then set it in Editor Settings > Export > Android.")

    build_version = project / "android" / ".build_version"
    if (project / "android" / "build").is_dir():
        have = build_version.read_text(encoding="utf-8").strip() if build_version.exists() else "unknown version"
        if have == tested:
            report.ok("Android build template installed (%s)" % have)
        else:
            report.warn("Android build template is %s, Godot %s expects its own: Project > Install Android Build Template." % (have, tested))
    else:
        report.warn("Android build template not installed in this project: Project > Install Android Build Template (once per project).")
    presets = project / "export_presets.cfg"
    if presets.exists():
        text = presets.read_text(encoding="utf-8", errors="replace")
        if re.search(r"^gradle_build/use_gradle_build=false", text, re.M):
            report.warn("export_presets.cfg has Use Gradle Build off; WebUI needs it on (the export log will say so too).")
        elif "gradle_build/use_gradle_build=true" in text:
            report.ok("export preset has Use Gradle Build on")

    heading("Desktop preview (optional development aid)")
    state, detail = installed_state(wry_target)
    if state == "ok":
        report.ok("godot_wry %s installed and verified (%s) at %s" % (DEPS["godot_wry"]["version"], detail, wry_target))
    elif state == "missing":
        report.info("godot_wry not installed (only needed to preview the UI on desktop): python tools/setup.py wry")
    else:
        report.warn("godot_wry at %s needs repair (%s): python tools/setup.py wry" % (wry_target, detail))
    if (project / "addons" / "godot_wry").exists():
        report.warn("addons/godot_wry is inside the project. Delete it: it breaks or bloats Android exports.")
    if system == "linux":
        report.info("Linux preview also needs WebKitGTK and an X11 session.")

    heading("Native plugin rebuild (only if you edit Java code)")
    gradle = project / "native" / "android" / "webui" / "build.gradle"
    if gradle.exists():
        text = gradle.read_text(encoding="utf-8", errors="replace")
        sdk_match = re.search(r"compileSdk\s+(\d+)", text)
        tools_match = re.search(r"buildToolsVersion\s+'([^']+)'", text)
        report.info("needs JDK %d, Android platform %s and build-tools %s, plus internet for Gradle: "
                    "cd native/android && ./gradlew copyToAddon" % (wanted_java, sdk_match.group(1) if sdk_match else "?",
                                                                    tools_match.group(1) if tools_match else "?"))
    return report


# ---------------------------------------------------------------- other projects and the skill

def enable_plugin_text(text: str) -> str:
    """Add the WebUI plugin to [editor_plugins] enabled=PackedStringArray(...) in project.godot text."""
    if PLUGIN_CFG in text:
        return text
    entry = '"%s"' % PLUGIN_CFG
    section = re.search(r"^\[editor_plugins\]\s*$", text, re.M)
    if section:
        tail = text[section.end():]
        next_section = re.search(r"^\[", tail, re.M)
        body_end = section.end() + (next_section.start() if next_section else len(tail))
        body = text[section.end():body_end]
        enabled = re.search(r"^enabled=PackedStringArray\((.*?)\)\s*$", body, re.M)
        if enabled:
            inner = enabled.group(1).strip()
            new_line = "enabled=PackedStringArray(%s)" % (inner + ", " + entry if inner else entry)
            body = body[:enabled.start()] + new_line + body[enabled.end():]
        else:
            body = "\nenabled=PackedStringArray(%s)\n" % entry + body.lstrip("\n")
        return text[:section.end()] + body + text[body_end:]
    return text.rstrip("\n") + "\n\n[editor_plugins]\n\nenabled=PackedStringArray(%s)\n" % entry


def copy_tree(src: Path, dst: Path) -> int:
    count = 0
    for file in sorted(src.rglob("*")):
        if file.is_dir() or "__pycache__" in file.parts:
            continue
        out = dst / file.relative_to(src)
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, out)
        count += 1
    return count


def install_skill(skills_dir: Path) -> Path:
    source = ROOT / "skills" / SKILL_NAME
    if not (source / "SKILL.md").exists():
        raise SetupError("skill source not found at %s" % source)
    dest = skills_dir / SKILL_NAME
    if dest.exists():
        shutil.rmtree(dest)
    copy_tree(source, dest)
    return dest


def add_to_project(target: Path, enable: bool, skill_dir: Path | None) -> None:
    if target.resolve() == ROOT.resolve():
        raise SetupError("that is this repository; pass your own game's project folder")
    project_file = target / "project.godot"
    if not project_file.is_file():
        raise SetupError("%s is not a Godot project (no project.godot)" % target)
    text = project_file.read_text(encoding="utf-8")
    if "config_version=5" not in text:
        raise SetupError("%s is not a Godot 4 project (expected config_version=5)" % project_file)
    heading("Adding the WebUI addon to %s" % target)
    if (target / "addons" / "godot_wry").exists():
        print("  [!]  addons/godot_wry is inside that project. Delete it (see docs/desktop-preview.md).")
    count = copy_tree(ROOT / "addons" / "webui", target / "addons" / "webui")
    print("  [ok] copied %d files to addons/webui (existing files overwritten)" % count)
    if enable:
        new_text = enable_plugin_text(text)
        if new_text == text:
            print("  [ok] plugin already enabled in project.godot")
        else:
            backup = project_file.with_name("project.godot.webui-backup")
            if not backup.exists():
                shutil.copy2(project_file, backup)
            project_file.write_text(new_text, encoding="utf-8")
            print("  [ok] enabled the plugin in project.godot (backup: %s). Close the Godot editor first if it is open;"
                  " it may overwrite this change." % backup.name)
    else:
        print("  [--] plugin not enabled: Project > Project Settings > Plugins > godot-webui (or re-run with --enable-plugin)")
    if skill_dir is not None:
        print("  [ok] skill installed at %s" % install_skill(skill_dir))
    print("\n  Still manual in that project:")
    print("   - Project > Install Android Build Template; Project > Export > Android > Use Gradle Build")
    print("   - put your UI in a folder with an index.html (outside addons/); add .webui_preview/ to its .gitignore")
    print("   - optional desktop preview: python tools/setup.py wry")


# ---------------------------------------------------------------- command line

def main(argv: list | None = None) -> int:
    # Shared options work before or after the command (SUPPRESS keeps a missing option from overriding the other).
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--godot", default=argparse.SUPPRESS, help="path to the Godot editor executable (for version checks)")
    common.add_argument("--cache", type=Path, default=argparse.SUPPRESS, help="download cache (default tools/.cache, git-ignored)")
    common.add_argument("--project", type=Path, default=argparse.SUPPRESS, help="Godot project to check (default: this repository)")
    parser = argparse.ArgumentParser(prog="setup.py", description=__doc__.split("\n\n")[0], parents=[common],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")

    wry = sub.add_parser("wry", parents=[common], help="install, verify or repair the pinned godot_wry desktop-preview extension")
    wry.add_argument("--force", action="store_true", help="reinstall even if it verifies")
    wry.add_argument("--archive", type=Path, help="use a godot_wry.zip you downloaded yourself (still hash-checked)")
    wry.add_argument("--target", type=Path, help="install folder (default: user data dir, or $GODOT_WEBUI_WRY)")
    sub.add_parser("doctor", parents=[common], help="check the environment and explain anything missing")
    add = sub.add_parser("add-to-project", parents=[common], help="copy the addon into another Godot project")
    add.add_argument("path", type=Path)
    add.add_argument("--enable-plugin", action="store_true", help="also enable the plugin in its project.godot (backs it up first)")
    add.add_argument("--with-skill", nargs="?", const="", metavar="SKILLS_DIR",
                     help="also install the agent skill (default: <project>/.claude/skills)")
    skill = sub.add_parser("install-skill", parents=[common], help="copy the agent skill into a skills directory")
    skill.add_argument("dir", nargs="?", type=Path, help="skills directory, e.g. ~/.claude/skills or <project>/.claude/skills")
    skill.add_argument("--claude-user", action="store_true", help="use ~/.claude/skills")
    args = parser.parse_args(argv)
    godot = getattr(args, "godot", None)
    cache = getattr(args, "cache", ROOT / "tools" / ".cache")
    project = getattr(args, "project", ROOT)

    try:
        command = args.command or "setup"
        if command in ("setup", "wry"):
            target = getattr(args, "target", None) or default_wry_target()
            install_wry(target, getattr(args, "archive", None), cache, getattr(args, "force", False))
        if command in ("setup", "doctor"):
            report = doctor(project, godot, default_wry_target())
            print("\n%d problem(s), %d warning(s)." % (report.problems, report.warnings))
            if report.problems:
                print("Problems marked [XX] need manual action (they are Godot/Android prerequisites this script does not install).")
            return 1 if report.problems else 0
        if command == "add-to-project":
            skill_dir = None
            if args.with_skill is not None:
                skill_dir = Path(args.with_skill) if args.with_skill else args.path / ".claude" / "skills"
            add_to_project(args.path, args.enable_plugin, skill_dir)
        if command == "install-skill":
            if args.claude_user:
                dest = Path.home() / ".claude" / "skills"
            elif args.dir:
                dest = args.dir
            else:
                raise SetupError("give a skills directory, or --claude-user")
            print("skill installed at %s" % install_skill(dest))
        return 0
    except SetupError as error:
        print("\nERROR: %s" % error, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
