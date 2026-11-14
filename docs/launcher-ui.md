# Launcher UI spec (2026-11-15)

Both desktop launchers must match the iOS app: simple, two primary sections plus Settings.

## Top-level navigation
- **游戏库 / Library** (default once games exist): game cards with cover/placeholder, title, status, and one primary action per game (构建 / 安装 / 推送 / 启动说明). Empty state: a single prominent Import button.
- **导入 / Import**: drag-and-drop or file picker for a decrypted .3ds/.cci; after selection show detected titleID/name, then one primary button to import (and build if configured); progress/logs inline on this page only while a job runs.
- **Settings** (gear icon, not a top-level tab): Apple ID / team ID + signing explanation, device/connection state, build mode (macOS Build Agent vs local experimental), tool paths, language override (System / 简体中文 / English), logs/diagnostics, About/licenses.
- Move every other screen (old Device, Install, Push, Activity, Diagnostics) out of top-level navigation; keep the essential install/push actions on a game card or in a small dialog launched from it.

## Language
- Detect the OS UI language: Simplified Chinese -> zh-Hans, otherwise English (fallback). Provide a Settings override (System/English/简体中文) persisted.
- Localize all visible UI: tabs, buttons, empty states, progress, errors, settings, dialogs. Keep log/diagnostic raw output as-is.
- Use the existing iOS shell strings/terminology where reasonable (游戏库, 导入, 设置, 安装, 推送, Apple ID).

## Visual
- Minimal: light/dark adaptation, one accent color, generous spacing, no dense multi-column dashboards.
- Game card: icon/placeholder, name, one status line, one primary button + overflow menu for secondary actions.

## Icon
- Reuse the iOS app icon: ios/app/Assets.xcassets/AppIcon.appiconset/icon-1024.png.
- Windows: generate .ico, set ApplicationIcon and window icon; macOS: generate .icns/app asset and use it for the app bundle/window.

## Windows single-file distribution
- The user-facing zip must contain exactly one executable (e.g. 3ds2apple.exe).
- Use .NET self-contained single-file publish (IncludeNativeLibrariesForSelfExtract) and embed the base shell IPA/manifest, official Impactor/plumesign, Bin CLIs and license texts as embedded resources; extract them once to %LOCALAPPDATA%\3ds2apple on first run and use those paths.
- The exe must pass --self-test from a clean folder, with icon shown in Explorer. Keep a developer-only multi-file mode if needed.
