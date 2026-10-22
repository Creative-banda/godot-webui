# Contributing

Thanks for your interest in Godot WebUI. The project is early and Android-only; bug reports, device test results and focused fixes are the most useful contributions.

## Reporting issues

Please include: Godot version, Android version and device, the System WebView version if known, what you expected, and the console output (Godot prints WebUI errors as `WebUI error <code>: <text>`, and page `console.*` output as `[WebUI:js:...]`). Do not post secrets, keystores or signing details.

## Development setup

- Godot 4.7.1 with the Android export templates and a Gradle-based export (see the README's Installation section).
- To rebuild the native plugin: JDK 17 and the Android SDK (platform 35, build-tools 35.0.1), then:

  ```bash
  cd native/android
  ./gradlew copyToAddon        # Windows: .\gradlew.bat copyToAddon
  ```

  This writes `addons/webui/bin/WebUI-debug.aar` and `WebUI-release.aar`. Those files are tracked; commit them together with the Java change that produced them. Do not commit `native/android/**/build/`.
- Changing the Godot version: update `godotVersion` in `native/android/webui/build.gradle` and check the export still works.

## Tests

```bash
godot --headless --path . --import --quit
godot --headless --path . -s res://tests/headless_test.gd
```

The exit code is the number of failed checks. This test runs on desktop with the null backend; it does not cover the Android code. For native changes, test on a device and say in your pull request what you tested and on which device.

## Pull requests

- Keep changes focused; explain the problem and how you checked the fix.
- Match the surrounding code style (GDScript uses tabs; files are UTF-8 per `.editorconfig`).
- Do not claim support for platforms or behaviours that you have not verified.
- iOS and desktop backends are out of scope for this release; open an issue to discuss before starting one.
- Keep the README, `AGENTS.md` and `CHANGELOG.md` accurate when you change behaviour or the API.

## Security

Report vulnerabilities as described in [SECURITY.md](SECURITY.md), not in public issues.
