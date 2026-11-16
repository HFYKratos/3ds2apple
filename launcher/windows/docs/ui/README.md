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

## v2 two-section flow (2026-11-16, task-30)

Launcher v2 has exactly two sections (Library, Deploy) plus the Settings gear. Rendered the
same way (`THREEDS2APPLE_UI_SMOKE_VIEW=library|deploy|settings`):

- `v2-library.png` — Library: import card + empty state, no build/install/push buttons.
- `v2-deploy.png` — Deploy: toolchain/device readiness, per-game checkboxes, one **一键部署 /
  Deploy selected** action, the five visible steps (compile → compose → sign/install → push →
  verify), idle/done/failed banners and the deploy-log toggle.
- `v2-settings.png` — minimal Settings: Apple ID/Open Impactor, device, language, logs
  (self-test/open/export) and about; build-mode/tool-path/UDID/bundle-id controls are gone.

The screenshots show a developer machine without the LLVM payload: Deploy honestly lists the
missing local-toolchain files and its one actionable fix instead of any silent fallback.
