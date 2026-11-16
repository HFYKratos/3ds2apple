# Windows launcher UI evidence

> These renders are from the pre-reset 0.2.4 launcher (0.2.x numbering); the
> current product version is 0.1.0 build 1 and ships the same UI.

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
