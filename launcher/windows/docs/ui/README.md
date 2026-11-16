# Windows launcher UI evidence

## v3 polish (task-33, 2026-11-16)

Real Windows 11 window captures of the packaged single-file launcher (Avalonia 12,
x64, embedded payload extracted on first run). They are not mockups: the launcher was
started from `out/launchers/publish-win-x64/3ds2apple-launcher.exe` and its window was
captured with the Win32 `PrintWindow` API.

What changed in v3 (user screenshot feedback):

- the two top tabs (游戏库 / 部署) are centered relative to the whole window;
- the Library import area is exactly one **导入 / Import** button that opens the file
  picker — the ROM path textbox, the display-name override field, the explanatory
  card, the duplicate empty-state card and the readiness caption in the content area
  are gone; imported game cards remain below the button;
- Settings no longer has the "其余全部自动 / Everything else is automatic" block and no
  manual self-test button (language, Apple ID/Impactor, device, logs, about only);
- the readiness self-check runs automatically at startup and shows a persistent status
  light in the bottom bar: green dot + `已完成准备` (Ready) when every bundled
  component passes, red dot + `未完成准备` (Not ready) when something is missing.
  Hovering the light shows the per-component details; clicking it re-runs the check.
  Details are also written to the launcher log.

Files (Simplified Chinese = Windows system language in these captures):

- `v3-library-zh.png` — Library, zh-Hans: centered tabs, one 导入 button, game cards
  below, green readiness light.
- `v3-library-en.png` — Library, English (language override).
- `v3-settings-zh.png` — Settings, zh-Hans: no automatic block, no manual self-test;
  About lists every component as 就绪 (ready).
- `v3-settings-en.png` — Settings, English.
- `v3-library-en-red.png` — not-ready state: a headless Linux/Xvfb render of the same
  v3 UI with no bundled payload, so every component is missing and the status light is
  red with `Not ready` (the same automatic self-check drives both states).
- `v3-deploy-en.png` — Deploy, English: per-game selection, one deploy action and the
  five visible steps (compile → compose app IPA → sign/install → push ROM data → verify).

The green state needs the packaged payload (LLVM/3dsrecomp/Impactor/shell are Windows
binaries), so a headless Linux/Xvfb development render is used for the red state; both
states come from the same automatic self-check and the per-component details are also
written to the launcher log and shown in the status-light tooltip.

## v2 (2026-11-16, superseded)

Screenshots rendered by the Avalonia launcher itself through the developer-only
`--ui-smoke` mode on Xvfb (no mockups):

- `v2-library.png` — Library: import card and empty state; no build/install/push buttons.
- `v2-deploy.png` — Deploy: readiness, per-game selection, one 一键部署 action and the
  five visible steps (compile → compose → sign/install → push → verify).
- `v2-settings.png` — minimal Settings (Apple ID/Impactor, device, language, logs, about).

Build and render (Linux/Xvfb development renders):

    cd launcher/windows
    dotnet build Launcher.slnx
    THREEDS2APPLE_UI_SMOKE_SHOT=/tmp/v3-deploy.png THREEDS2APPLE_UI_SMOKE_VIEW=deploy \
      xvfb-run -a dotnet src/Launcher.Desktop/bin/Debug/net10.0/3ds2apple-launcher.dll --ui-smoke

These are development renders; real Windows/GUI/device acceptance is in
`docs/windows-launcher.md`.
