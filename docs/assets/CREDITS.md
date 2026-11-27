# Media credits and provenance

All images on this site, in the press kit and in the READMEs are **project-owned synthetic
media or headless captures of the project's own launchers**. No commercial game screenshots,
logos, box art, ROM data, save data or game assets appear anywhere, and no commercial game name
is used in any filename, caption or alt text.

The app-preview artwork (hero, Open Graph card, social preview, demo GIF, portrait/landscape
previews and the in-game/layout/overlay screenshots) is the 0.2.1 synthetic refresh. The launcher
screenshots and the iOS Settings captures were refreshed for 0.3.1 (2026-11-28) and are listed
below.

## Sources

| Committed file | Built from |
|---|---|
| docs/assets/portrait.png | out/sim-shots/20261125-0.2.1-final/01-preview-portrait.png (iOS Simulator synthetic preview, 1290x2796 -> 900x1951) |
| docs/assets/landscape.png | out/sim-shots/20261125-0.2.1-final/02-preview-landscape.png (2796x1290 -> 1400x646) |
| docs/assets/hero.png | generated composite of the two previews above (1600x900) |
| docs/assets/og.png | generated Open Graph / Twitter card (1200x630) |
| docs/assets/social-preview.png | generated repository social preview (1280x640) |
| docs/assets/demo-poster.png | first demo slide composite (960x640) |
| docs/assets/demo.gif | 4-slide 0.2.1 slideshow: portrait controls -> landscape controls -> in-game menu -> performance overlay settings (960x640) |
| docs/assets/screenshots/controls-*.png, layout-*.png, overlay-position.png, pause-virtual-controls.png, performance-overlay.png | 0.2.1 synthetic in-game / layout / overlay screenshots from out/sim-shots/20261125-0.2.1-final/ |
| docs/assets/screenshots/ios-settings-root.png, ios-settings-system.png, ios-settings-layout.png | 0.3.1 device captures (iPhone10,3, iOS 16.7.16, 3ds2apple 0.3.1 shell): the app's Settings pages only, Simplified Chinese system UI. Downscaled to 800 px wide and palette-quantised. No game data. |
| docs/assets/screenshots/windows-launcher-library-empty-en.png, -zh.png, windows-launcher-library-en.png | 0.3.1 Windows launcher (official `3ds2apple-0.3.1-windows-x64.zip`) under Wine + Xvfb with the developer `--ui-smoke` mode, light theme, deterministic synthetic fixtures (Example Game / Second Example). Downscaled/quantised; no ROM or game data. |
| docs/assets/screenshots/macos-launcher-library-empty-dark-en.png, -light-en.png, macos-launcher-settings-dark-en.png | 0.3.1 macOS launcher (official `3ds2apple-0.3.1-macos-universal.zip`) headless SwiftUI SnapshotRenderer (`--screenshot-dir ... --mock`), downscaled to 1180 px and palette-quantised. The amber MOCK / DRY RUN badge is part of the headless fixture. Library/Deploy mock frames that embed commercial titles were excluded. |
| docs/assets/screenshots/launcher-linux-library-en.png, -zh.png | 0.3.1 Linux launcher (published Linux `tar.gz`) headless `--ui-smoke` capture under Xvfb, isolated HOME and relative workspace; the bottom 44 px status strip was cropped (headless run has no device/sign-in). Synthetic demo entries only. |
| docs/assets/readme-icon.png | original 3ds2apple app icon (project-owned, 1024x1024) |
| docs/assets/logo-*.png, favicon*, apple-touch-icon.png | project-owned app icon variants |

Captions and alt text state the capture generation (0.2.1 synthetic or 0.3.1 current) and mark
headless mock captures as such.

## Why the images are synthetic

The iOS in-game screenshots are Simulator captures of the app's preview test harness, not a game:
the two "screens" are flat blue and purple grids labelled **TOP 400x240** and **BOTTOM 320x240**,
with the control overlay, in-game menu and Settings UI. No ROM is loaded and no game data is
rendered. The Settings captures are real device screenshots of the Settings pages; the game
library and in-game screens were deliberately not published because they would show the test
game's cover art or picture. The launcher screenshots show the launchers' built-in synthetic demo
entries or an empty library, never a real game.

## How the media was produced

- Pillow (Python) composition, Lanczos resizing, rounded cards, shadows, captions and Open
  Graph artwork for the 0.2.1 media set.
- demo.gif: 960x640, 4 slides, per-slide captions, adaptive 96-colour palette, ~5 s loop,
  under 200 KB.
- New 0.3.1 captures: Windows launcher via Wine/Xvfb `--ui-smoke`; macOS launcher via the
  headless SnapshotRenderer; iOS Settings via device screenshots; Linux launcher via Xvfb
  `--ui-smoke`. They are downscaled and palette-quantised to keep the committed media set small.
- No CDN, no external font, no tracker: system fonts only for the site.

## Licence and press use

The app icon and these composite images are (c) 2026 3ds2apple contributors and covered by the
repository's Apache-2.0 licence. Press and reviewers may reuse them unmodified with credit to
"3ds2apple (HFYKratos)" and must not imply endorsement by the project or by Nintendo.

## Not included

No Nintendo ROMs, decryption keys, BIOS, system files, fonts or game assets; no gameplay
screenshots; no generated C; no signed IPA; no commercial game names. 3ds2apple is not
affiliated with, endorsed by or sponsored by Nintendo.
