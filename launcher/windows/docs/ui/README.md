# Windows launcher UI evidence (v2, 2026-11-16)

Screenshots rendered by the Avalonia launcher itself through the developer-only
`--ui-smoke` mode on Xvfb (no mockups):

- `v2-library.png` — Library: import card and empty state; no build/install/push buttons.
- `v2-deploy.png` — Deploy: readiness, per-game selection, one 一键部署 action and the
  five visible steps (compile → compose → sign/install → push → verify).
- `v2-settings.png` — minimal Settings (Apple ID/Impactor, device, language, logs, about).

Build and render:

    cd launcher/windows
    dotnet build Launcher.slnx
    THREEDS2APPLE_UI_SMOKE_SHOT=/tmp/v2-deploy.png THREEDS2APPLE_UI_SMOKE_VIEW=deploy \
      xvfb-run -a dotnet src/Launcher.Desktop/bin/Debug/net10.0/3ds2apple-launcher.dll --ui-smoke

These are development renders; real Windows/GUI/device acceptance is in
`docs/windows-launcher.md`.
