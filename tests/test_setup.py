"""Tests for tools/setup.py (standard library only). Run: python -m unittest tests/test_setup.py -v

Nothing here touches the real user-data folder or the network: installs go to temp folders and
downloads use file:// URLs or a closed local port."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

SETUP_PATH = Path(__file__).resolve().parent.parent / "tools" / "setup.py"
spec = importlib.util.spec_from_file_location("webui_setup", SETUP_PATH)
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)

ROOT_PREFIX = "addons/godot_wry/"


def make_archive(path: Path, extra: dict | None = None) -> str:
    members = {
        ROOT_PREFIX + "WRY.gdextension": b"[configuration]\nentry_symbol = \"x\"\n",
        ROOT_PREFIX + "index.html": b"<html></html>",
        ROOT_PREFIX + "icons/webview.svg": b"<svg/>",
        ROOT_PREFIX + "bin/x86_64-pc-windows-msvc/godot_wry.dll": b"WINDOWS-LIB",
        ROOT_PREFIX + "bin/x86_64-unknown-linux-gnu/libgodot_wry.so": b"LINUX-LIB",
        ROOT_PREFIX + "bin/android/arm64-v8a/libgodot_wry.so": b"ANDROID-LIB",
        ROOT_PREFIX + "examples/demo.tscn": b"example",
    }
    members.update(extra or {})
    with zipfile.ZipFile(path, "w") as bundle:
        for name, data in members.items():
            bundle.writestr(name, data)
    return hashlib.sha256(path.read_bytes()).hexdigest()


class WryInstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        self.archive = self.tmp / "godot_wry.zip"
        self.sha = make_archive(self.archive)
        deps = json.loads(json.dumps(setup.DEPS))
        deps["godot_wry"]["sha256"] = self.sha
        deps["godot_wry"]["size"] = self.archive.stat().st_size
        deps["godot_wry"]["url"] = self.archive.as_uri()
        patches = [
            mock.patch.object(setup, "DEPS", deps),
            mock.patch.object(setup, "host_os", return_value="windows"),
            mock.patch("platform.machine", return_value="AMD64"),
        ]
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        self.target = self.tmp / "data" / "godot_wry"

    def install(self, **kwargs):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            setup.install_wry(self.target, kwargs.get("archive"), self.tmp / "cache", kwargs.get("force", False))
        return out.getvalue()

    def test_installs_only_this_platform_and_verifies(self):
        self.install(archive=self.archive)
        installed = {p.relative_to(self.target).as_posix() for p in self.target.rglob("*") if p.is_file()}
        self.assertIn("WRY.gdextension", installed)
        self.assertIn("bin/x86_64-pc-windows-msvc/godot_wry.dll", installed)
        self.assertNotIn("bin/x86_64-unknown-linux-gnu/libgodot_wry.so", installed)
        self.assertFalse(any(p.startswith(("bin/android", "examples")) for p in installed))
        self.assertEqual(setup.installed_state(self.target)[0], "ok")

    def test_second_run_is_a_no_op_and_repairs_damage(self):
        self.install(archive=self.archive)
        self.assertIn("already installed", self.install(archive=self.archive))
        dll = self.target / "bin" / "x86_64-pc-windows-msvc" / "godot_wry.dll"
        dll.write_bytes(b"CORRUPT")
        self.assertEqual(setup.installed_state(self.target)[0], "broken")
        text = self.install(archive=self.archive)
        self.assertIn("repair", text)
        self.assertEqual(dll.read_bytes(), b"WINDOWS-LIB")

    def test_unmanaged_install_is_repaired_with_marker(self):
        self.target.mkdir(parents=True)
        (self.target / "WRY.gdextension").write_text("hand installed")
        self.assertEqual(setup.installed_state(self.target)[0], "unmanaged")
        self.install(archive=self.archive)
        self.assertEqual(setup.installed_state(self.target)[0], "ok")
        self.assertNotEqual((self.target / "WRY.gdextension").read_text(), "hand installed")

    def test_wrong_archive_is_refused_and_nothing_is_installed(self):
        other = self.tmp / "other.zip"
        make_archive(other, {ROOT_PREFIX + "extra": b"x"})
        with self.assertRaises(setup.SetupError) as raised:
            self.install(archive=other)
        self.assertIn("SHA-256", str(raised.exception))
        self.assertFalse(self.target.exists())

    def test_zip_slip_is_rejected(self):
        with self.assertRaises(setup.SetupError):
            setup.wanted_members([ROOT_PREFIX + "../evil.txt"], "bin/x", ROOT_PREFIX)

    def test_download_from_url_uses_cache_and_verifies(self):
        self.install()  # url is a file:// URL of the archive
        cached = self.tmp / "cache" / ("godot_wry-%s.zip" % setup.DEPS["godot_wry"]["version"])
        self.assertTrue(cached.exists())
        self.assertEqual(setup.installed_state(self.target)[0], "ok")

    def test_download_rejects_hash_mismatch_and_leaves_no_file(self):
        dest = self.tmp / "dl" / "x.zip"
        with self.assertRaises(setup.SetupError) as raised:
            setup.download(self.archive.as_uri(), dest, self.archive.stat().st_size, "0" * 64, attempts=1)
        self.assertIn("SHA-256 mismatch", str(raised.exception))
        self.assertFalse(dest.exists())
        self.assertFalse(dest.with_suffix(".zip.part").exists())

    def test_download_failure_has_a_manual_fallback_message(self):
        with self.assertRaises(setup.SetupError) as raised:
            setup.download("http://127.0.0.1:9/nothing.zip", self.tmp / "n.zip", 1, "0" * 64, attempts=1)
        self.assertIn("--archive", str(raised.exception))

    def test_unsupported_machine_explains_itself(self):
        with mock.patch("platform.machine", return_value="riscv64"):
            with self.assertRaises(setup.SetupError) as raised:
                setup.wry_platform()
        self.assertIn("optional", str(raised.exception))


class EnablePluginTests(unittest.TestCase):
    CFG = '"res://addons/webui/plugin.cfg"'

    def test_adds_section_when_missing(self):
        out = setup.enable_plugin_text("config_version=5\n\n[application]\n\nconfig/name=\"x\"\n")
        self.assertIn("[editor_plugins]", out)
        self.assertIn("enabled=PackedStringArray(%s)" % self.CFG, out)

    def test_appends_to_existing_list(self):
        text = '[editor_plugins]\n\nenabled=PackedStringArray("res://addons/other/plugin.cfg")\n\n[physics]\n'
        out = setup.enable_plugin_text(text)
        self.assertIn('PackedStringArray("res://addons/other/plugin.cfg", %s)' % self.CFG, out)
        self.assertIn("[physics]", out)

    def test_empty_list_and_missing_enabled_line(self):
        self.assertIn("PackedStringArray(%s)" % self.CFG, setup.enable_plugin_text("[editor_plugins]\n\nenabled=PackedStringArray()\n"))
        self.assertIn("PackedStringArray(%s)" % self.CFG, setup.enable_plugin_text("[editor_plugins]\n\n[physics]\n"))

    def test_already_enabled_is_unchanged(self):
        text = "[editor_plugins]\n\nenabled=PackedStringArray(%s)\n" % self.CFG
        self.assertEqual(setup.enable_plugin_text(text), text)


class AddToProjectTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        self.project = self.tmp / "game"
        self.project.mkdir()
        (self.project / "project.godot").write_text('config_version=5\n\n[application]\n\nconfig/name="game"\n', encoding="utf-8")

    def run_add(self, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            setup.add_to_project(self.project, kwargs.get("enable", False), kwargs.get("skill"))

    def test_copies_addon_and_enables_plugin_with_backup(self):
        self.run_add(enable=True)
        self.assertTrue((self.project / "addons" / "webui" / "plugin.cfg").exists())
        self.assertTrue((self.project / "addons" / "webui" / "bin" / "WebUI-release.aar").exists())
        self.assertIn("res://addons/webui/plugin.cfg", (self.project / "project.godot").read_text(encoding="utf-8"))
        self.assertTrue((self.project / "project.godot.webui-backup").exists())
        self.run_add(enable=True)  # idempotent
        text = (self.project / "project.godot").read_text(encoding="utf-8")
        self.assertEqual(text.count("res://addons/webui/plugin.cfg"), 1)

    def test_without_enable_leaves_project_file_alone(self):
        before = (self.project / "project.godot").read_text(encoding="utf-8")
        self.run_add()
        self.assertEqual((self.project / "project.godot").read_text(encoding="utf-8"), before)

    def test_refuses_non_godot4_and_own_repo(self):
        (self.project / "project.godot").write_text("config_version=4\n")
        with self.assertRaises(setup.SetupError):
            self.run_add()
        with self.assertRaises(setup.SetupError):
            with contextlib.redirect_stdout(io.StringIO()):
                setup.add_to_project(setup.ROOT, False, None)
        with self.assertRaises(setup.SetupError):
            with contextlib.redirect_stdout(io.StringIO()):
                setup.add_to_project(self.tmp / "nope", False, None)

    def test_skill_install(self):
        skills = self.tmp / "skills"
        self.run_add(skill=skills)
        self.assertTrue((skills / setup.SKILL_NAME / "SKILL.md").exists())


class AgentFilesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        self.project = self.tmp / "game"
        self.project.mkdir()

    def run_agents(self, agents):
        with contextlib.redirect_stdout(io.StringIO()):
            return setup.install_agent_files(self.project, agents)

    def read(self, rel):
        return (self.project / rel).read_text(encoding="utf-8")

    def test_every_agent_gets_a_pointer_to_a_skill_that_exists(self):
        self.run_agents(["all"])
        for entry in setup.AGENT_FILES.values():
            text = self.read(entry["path"])
            self.assertIn("SKILL.md", text)
            self.assertIn("read `", text)
        self.assertTrue((self.project / "skills" / "godot-webui" / "SKILL.md").exists())
        self.assertTrue((self.project / ".claude" / "skills" / "godot-webui" / "SKILL.md").exists())
        self.assertIn(".claude/skills/godot-webui/SKILL.md", self.read("CLAUDE.md"))
        self.assertIn("skills/godot-webui/SKILL.md", self.read("AGENTS.md"))

    def test_tool_specific_files_have_their_front_matter(self):
        self.run_agents(["cursor", "kiro", "windsurf"])
        self.assertTrue(self.read(".cursor/rules/godot-webui.mdc").startswith("---\n"))
        self.assertIn("alwaysApply: true", self.read(".cursor/rules/godot-webui.mdc"))
        self.assertIn("inclusion: always", self.read(".kiro/steering/godot-webui.md"))
        self.assertIn("trigger: always_on", self.read(".windsurf/rules/godot-webui.md"))

    def test_existing_instruction_files_keep_the_users_text_and_are_updated_not_duplicated(self):
        (self.project / "AGENTS.md").write_text("# My rules\n\nBe nice.\n", encoding="utf-8")
        self.run_agents(["agents-md"])
        text = self.read("AGENTS.md")
        self.assertTrue(text.startswith("# My rules\n\nBe nice.\n"))
        self.assertEqual(text.count(setup.BLOCK_BEGIN), 1)
        self.run_agents(["agents-md"])
        self.assertEqual(self.read("AGENTS.md"), text)  # idempotent
        (self.project / "AGENTS.md").write_text(text.replace("binding", "OLD").replace("Be nice.", "Be very nice."), encoding="utf-8")
        self.run_agents(["agents-md"])
        again = self.read("AGENTS.md")
        self.assertIn("Be very nice.", again)
        self.assertEqual(again.count(setup.BLOCK_BEGIN), 1)
        self.assertNotIn("OLD", again)

    def test_unknown_agent_is_refused_and_defaults_are_sensible(self):
        with self.assertRaises(setup.SetupError):
            self.run_agents(["notepad"])
        self.assertEqual(setup.DEFAULT_AGENTS, ["agents-md", "claude"])

    def test_add_to_project_can_set_up_agents(self):
        (self.project / "project.godot").write_text('config_version=5\n', encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()):
            setup.add_to_project(self.project, False, None, ["cursor"])
        self.assertTrue((self.project / ".cursor" / "rules" / "godot-webui.mdc").exists())
        self.assertTrue((self.project / "addons" / "webui" / "plugin.cfg").exists())

    def test_the_skill_documents_what_the_script_installs(self):
        skill = (setup.ROOT / "skills" / "godot-webui" / "references" / "new-project.md").read_text(encoding="utf-8")
        for name in setup.AGENT_FILES:
            self.assertIn(name, skill, "new-project.md should explain the %s target" % name)


class DoctorTests(unittest.TestCase):
    def test_doctor_runs_on_an_empty_project_and_reports_without_crashing(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(tmp, ignore_errors=True))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            report = setup.doctor(tmp, None, tmp / "no_wry")
        text = out.getvalue()
        self.assertIn("Android runtime", text)
        self.assertIn("Desktop preview", text)
        self.assertGreaterEqual(report.problems, 1)  # the AARs are missing in an empty project


if __name__ == "__main__":
    unittest.main()
