# Windows launcher UI evidence (2026-11-15)

Screenshots rendered by the Avalonia launcher itself (not mockups) through the
developer-only `--ui-smoke` mode on Xvfb:

    cd launcher/windows
    dotnet build Launcher.slnx
    THREEDS2APPLE_UI_SMOKE_SHOT=/tmp/launcher-en.png LANG=en_US.UTF-8 \
      xvfb-run -a dotnet src/Launcher.Desktop/bin/Debug/net10.0/3ds2apple-launcher.dll --ui-smoke
    THREEDS2APPLE_UI_SMOKE_SHOT=/tmp/launcher-zh.png LANG=zh_CN.UTF-8 \
      xvfb-run -a dotnet src/Launcher.Desktop/bin/Debug/net10.0/3ds2apple-launcher.dll --ui-smoke

- `launcher-en.png` — English library empty state (two sections + Settings gear).
- `launcher-zh.png` — 简体中文 library empty state (System language zh-CN).
- `import-en.png` — Import section (file picker, name override, next steps).
- `settings-en.png`, `settings-zh.png` — Settings (gear) in both languages: Apple ID &
  signing, device, build mode, language, tool paths, logs/diagnostics.

Set `THREEDS2APPLE_UI_SMOKE_VIEW=settings` or `=import` to render those screens instead
of the default Library view. All screenshots show the minimal light theme, the single
accent color and the empty/LOGS states of a developer machine (no bundled tools), so
the readiness line lists them as not ready; the shipped exe reports them ready after
extracting the embedded payload. The dev build on Linux has
no bundled tools, so the readiness line lists them as not ready; the shipped exe
reports them ready after extracting the embedded payload.

The Windows GUI itself is verified on a real Windows PC by the manual test plan in
`docs/windows-launcher.md` section 11; these renders prove the XAML loads, the
bindings resolve and both languages render (CJK included).
