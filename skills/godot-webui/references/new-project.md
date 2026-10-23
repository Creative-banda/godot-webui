# Using Godot WebUI in a new project, and teaching an AI agent about it

Two things are needed in a new project: the **addon** (the code) and the **skill** (what an AI agent must know to use it without guessing). The setup script installs both and writes the small instruction files that make different AI tools read the skill.

## 1. Install into a project

Run from a clone of the Godot WebUI repository (Python 3.8+, nothing to `pip install`). Close the Godot editor for the target project first; it can overwrite `project.godot`.

```bash
python tools/setup.py add-to-project PATH_TO_YOUR_GAME --enable-plugin --with-skill --agents agents-md,claude,cursor
```

- Copies `addons/webui/` into the project and enables the plugin (a `project.godot.webui-backup` is made first).
- `--with-skill` installs the skill at `<project>/.claude/skills/godot-webui` (Claude Code).
- `--agents LIST` also installs the skill at `<project>/skills/godot-webui` (plain files any agent can read) and writes the per-tool instruction files below. Use `all` for every tool listed.

Still manual in the Godot editor of that project: *Project > Install Android Build Template*, *Project > Export > Android > Use Gradle Build*, put UI in a folder with an `index.html` (outside `addons/`), and add `.webui_preview/` to `.gitignore`. The WebUI dock's preview needs a one-time `python tools/setup.py wry` (optional, outside the project).

Already have the addon and only need the agent files (or want to refresh them after updating the skill)?

```bash
python tools/setup.py agent-files PATH_TO_YOUR_GAME --agents all
```

It is safe to repeat: files that belong to the skill are rewritten; shared files such as `AGENTS.md` only get a block between `<!-- godot-webui:begin -->` and `<!-- godot-webui:end -->` that is replaced in place, and your own text is never touched. Commit the generated files so every agent session starts from them.

## 2. Which tool reads what

`--agents` names and what they write. These follow each tool's documented convention as known when this was written; they were not run against every tool, so if a tool ignores its file, use the generic method below.

| `--agents` name | Writes | Tool |
|---|---|---|
| `agents-md` | `AGENTS.md` (block), `skills/godot-webui/` | Read by many agents: Codex, Cursor, GitHub Copilot, Windsurf, Kiro and others |
| `claude` | `.claude/skills/godot-webui/` (the skill, auto-discovered) and a block in `CLAUDE.md` | Claude Code |
| `cursor` | `.cursor/rules/godot-webui.mdc` (always applied), `skills/godot-webui/` | Cursor |
| `kiro` | `.kiro/steering/godot-webui.md` (always included), `skills/godot-webui/` | Kiro |
| `windsurf` | `.windsurf/rules/godot-webui.md` (always on), `skills/godot-webui/` | Windsurf |
| `copilot` | block in `.github/copilot-instructions.md`, `skills/godot-webui/` | GitHub Copilot |
| `gemini` | block in `GEMINI.md`, `skills/godot-webui/` | Gemini CLI |

Other tools (Antigravity, Cline, Continue, Aider, Zed, JetBrains AI, ...): run with `agents-md`, then either point the tool's own rules or instructions setting at `skills/godot-webui/SKILL.md`, or paste the prompt from section 3 at the start of the session. All the tool needs is to read `skills/godot-webui/SKILL.md` before it touches UI code; every file above only says that, in the tool's own format.

Claude Code can also use one copy for all projects: `python tools/setup.py install-skill --claude-user` installs it in `~/.claude/skills`.

## 3. Prompts

### Starting in a new project (paste into any agent)

```
This Godot 4.7 project builds its game UI with the Godot WebUI addon (HTML/CSS/JS in a native Android
WebView overlay, with a JS <-> GDScript bridge and a visual editor dock).

First read skills/godot-webui/SKILL.md completely (in Claude Code the skill is named godot-webui), then
the references it points to for the task. Its rules are binding: use only the API listed in
references/api.md and addons/webui/webui.gd / web/godot.js, never invent methods or events; no gameplay
logic in the page; Android is the only runtime; relative URLs only; write pages the visual editor can
edit (external CSS files, unique ids, static text in the HTML, sample state in .webui-edit/) and make them
responsive on phones, tablets and any window size.

Then check whether the addon is installed and enabled (addons/webui and the plugin entry in
project.godot). If not, tell me and follow references/new-project.md. Report what you found before
changing anything.
```

### Building a screen or HUD

```
Using the godot-webui skill (skills/godot-webui/SKILL.md), build <WHAT: e.g. a pause menu with Resume,
Settings and Quit> in <ui folder, e.g. res://ui>.

- Godot owns the state; the page sends intent. List every event the page sends (name + payload) and every
  state/event Godot sends (name + payload) before writing code, and add the GDScript side with
  validation.
- Follow section 4 of the skill so I can adjust the design in the WebUI dock myself: CSS in a separate
  .css file, no <style> blocks or inline styles, unique ids on buttons/labels/panels, static text in the
  HTML, tokens in :root, plain HTML/CSS/JS.
- Make it responsive (skill rule 8, references/responsive.md): fluid units and clamp(), breakpoints for height/orientation/wider screens, safe areas, touch targets of at least 44 CSS px; check it at phone portrait and landscape, tablet and a wide window, and report the sizes checked.
- Create the sample state file (.webui-edit/<page>.json plus an empty .gdignore) matching what Godot sends.
- Finish with the report described in section 7 of the skill, including what you could not verify on a
  device.
```

### Making an existing page editable in the dock

```
Using the godot-webui skill, review <page, e.g. res://ui/hud.html> for the visual editor (skill section 4
and references/visual-editor.md). Move <style> blocks and inline styles into the page's .css file
without changing how it looks, give unique ids to the elements I would tweak, put static text in the
HTML instead of script, and add a sample state file. Do not change behaviour or the bridge. List
anything that still cannot be edited in the dock and why.
```

### Reviewing work another agent did

```
Review the WebUI changes in this branch against skills/godot-webui/SKILL.md. Check: every GodotWebUI /
Godot.* call exists in the installed source; no gameplay logic in the page; payloads validated in
GDScript; state resent from page_ready; relative URLs only; no remote resources; touch mode and
data-webui-touch correct; the page is editor-friendly (section 4). Report problems with file and line;
do not claim anything about a real device.
```

## 4. When the agent needs the addon source

In a game project the addon source is `addons/webui/` (authoritative) and the full documentation is in the WebUI repository (`README.md`, `docs/setup.md`, `docs/desktop-preview.md`). The skill is self-contained for rules and API; if a call is not in `references/api.md`, the agent should read `addons/webui/webui.gd` or `addons/webui/web/godot.js` instead of guessing.
