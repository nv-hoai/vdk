# AGENTS.md — AI agent guide for this repository

Purpose: help AI coding agents (Copilot-style assistants) work productively in this mixed Python/Flutter/Arduino workspace.

Project layout (key folders):
- `server/` — Python backend. See [server/README.md](server/README.md).
- `smarthomeapp/` — Flutter app. See [smarthomeapp/README.md](smarthomeapp/README.md) and `analysis_options.yaml` for lint rules.
- `esp32_client/` — ESP32 Arduino client. See [esp32_client/README.md](esp32_client/README.md).

Quick developer commands (agent should confirm before running):

- Server (Windows PowerShell/Cmd):

  python -m venv .venv
  .\\.venv\\Scripts\\activate
  pip install -r server/requirements.txt
  python server/main.py

- Flutter app (requires Flutter SDK):

  cd smarthomeapp
  flutter pub get
  flutter run -d <device>

- ESP32 client: follow `esp32_client/README.md` (builds via Arduino IDE or PlatformIO; agent should not assume tooling).

Guidelines for agents working in this repo
- Link, don't embed: prefer linking existing docs rather than copying them.
- Minimal edits: keep agent-made changes small, focused, and well-tested.
- Ask before running environment-changing commands (install, build, format).
- Preserve platform-specific files (Android/iOS/Windows directories) unless the user requests changes.
- Respect Dart analysis rules in `smarthomeapp/analysis_options.yaml` when modifying Dart code.

What I looked for (sources):
- `server/requirements.txt`, `server/main.py`
- `smarthomeapp/analysis_options.yaml`, `smarthomeapp/pubspec.yaml`, `smarthomeapp/README.md`
- `esp32_client/esp32_client.ino`, `esp32_client/README.md`

Suggested follow-ups (ask the user before proceeding)
- Create small skills/agents: `run-server`, `build-flutter`, `format-dart`, `explain-esp32-setup`.
- Add a `.github/copilot-instructions.md` only if a project-wide policy is needed (AGENTS.md preferred).

If you want, I can now create any of the suggested agent customizations.

---

Files added/modified

| File | Why useful |
|---|---|
| AGENTS.md | Central, minimal instructions for AI agents: project layout, quick commands, and agent behavior guidelines |
