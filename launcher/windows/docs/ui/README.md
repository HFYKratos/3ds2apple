# Windows launcher UI evidence

## v4 polish (task-39, 2026-11-16)

Local Linux/Xvfb renders of the 0.2.4 launcher (Avalonia 12, x64). **The games,
cover icons, titles and publisher in these captures are synthetic fixtures** created for
the screenshot run — no ROM, game icon or game title from a real ROM is stored in this
repository. Each render starts the launcher's developer-only `--ui-smoke` mode with a
temporary `state.json` (two fake library entries: one with a 48x48 synthetic `cover.png`,
one without an icon) so the new ROM-metadata UI can be reviewed without a ROM.

What changed in v4 (user feedback):

- **No editable name box.** The card title is read-only; it is chosen from the ROM's
  SMDH `displayNames` map for the current UI language (zh-Hans → `zh-Hans`, otherwise
  English, then the English/default name). The English and Chinese captures of the same
  library entry prove the language switch.
- **ROM icon on the card**: the package `cover.png` extracted from the ROM's SMDH is
  shown (52x52); a ROM without an icon keeps the placeholder. Publisher (SMDH) is shown
  as a caption when present.
- **Deploy compile line**: `Hardware: 16 logical / 8 physical cores · 15.6 GB RAM …
  · 3dsrecomp auto-parallelizes, no jobs setting` — the launcher reports the detected
  hardware; 3dsrecomp itself sizes its worker pool from the logical core count and
  throttles clang by available memory (see `third_party/3dsrecomp/src/compile.rs`).
- **Portable data folder**: Settings shows `Games/state folder: <exe-dir>\3ds2apple-data\
  workspace · portable beside the launcher (writable folder)` and the same reason for the
  extracted tools folder. The explicit-override render shows the override reason instead.
  A one-time migration of the old `%LOCALAPPDATA%\3ds2apple\launcher` workspace is
  covered by the launcher self-test (state.json + package data copied, old folder kept).

Files:

- `v4-library-en.png` — Library, English: cover icon + read-only name + publisher on the
  synthetic game; placeholder for the game without an icon; no name TextBox.
- `v4-library-zh.png` — Library, zh-Hans: same entries, titles from `displayNames`
  (`合成演示游戏`), UI strings in Chinese, publisher caption.
- `v4-library-portable-en.png` — same library with the default portable workspace
  (no env override), captured from the development binary's `3ds2apple-data` folder.
- `v4-deploy-en.png` — Deploy, English: the new hardware line + game selection.
- `v4-deploy-zh.png` — Deploy, zh-Hans.
- `v4-settings-en.png` — Settings, English, explicit-workspace override render.
- `v4-settings-portable-en.png` — Settings, English: portable folder reasons for both
  the games/state folder and the bundled tools folder.
- `v4-library-migrated-en.png` — first-run migration: the packaged build was started with
  an old-style `$LOCALAPPDATA/3ds2apple/launcher` workspace containing one synthetic game;
  the portable `<exe-dir>/3ds2apple-data/workspace` was created, `state.json` + package data
  were copied (`migration.json` marker), the old folder was left untouched, and the
  migrated game renders immediately.

End-to-end fallback evidence (packaged 0.2.4 Linux build, same embedded payload):

- read-only install folder (`chmod 555` around the executable): the launcher extracts the
  payload and keeps the workspace under `$LOCALAPPDATA/3ds2apple`, prints the reason in
  Settings/Diagnostics, and `--self-test` still ends with `SELF-TEST OK`
  (`out/launchers/3ds2apple-windows-single-0.2.4-readonly-install-self-test.log`);
- writable install folder: payload and workspace live beside the exe
  (`out/launchers/3ds2apple-windows-single-0.2.4-self-test.log`).

Render command (Linux/Xvfb, synthetic fixture; `THREEDS2APPLE_WORKSPACE` or the default
portable workspace supplies the fake library):

    cd launcher/windows
    export DOTNET_ROOT=$HOME/.dotnet10
    dotnet build src/Launcher.Desktop/ThreeDsTwoApple.Launcher.Desktop.csproj -c Release
    THREEDS2APPLE_UI_SMOKE_VIEW=library \
    THREEDS2APPLE_UI_SMOKE_SHOT=/tmp/v4-library.png \
      xvfb-run -a src/Launcher.Desktop/bin/Release/net10.0/3ds2apple-launcher --ui-smoke

These are development renders; the real Windows 11 run of the 0.2.4 exe and device
acceptance still need a Windows PC + iPhone/iPad (see `docs/windows-launcher.md`).

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
