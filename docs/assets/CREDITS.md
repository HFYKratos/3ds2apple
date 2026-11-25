# Media credits and provenance

All images on this site, in the press kit and in the READMEs are **project-owned synthetic
media**. No commercial game screenshots, logos, box art, ROM data, save data or game assets
appear anywhere, and no commercial game name is used in any filename, caption or alt text.

These assets are the 0.2.1 refresh: every app screenshot and launcher screenshot was captured
from the 0.2.1 build, and the hero, Open Graph card, social preview and demo GIF were rebuilt
from those captures. Old 0.1.5/0.2.0 screenshots were removed.

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
| docs/assets/screenshots/*.png | 0.2.1 app screenshots from out/sim-shots/20261125-0.2.1-final/ and launcher screenshots from the Windows (1120x820) and macOS (2360x...) 0.2.1 UI smoke runs |
| docs/assets/readme-icon.png | original 3ds2apple app icon (project-owned, 1024x1024) |
| docs/assets/logo-*.png, favicon*, apple-touch-icon.png | project-owned app icon variants |

App screenshots in docs/assets/screenshots/ come from the 20261125-0.2.1-final run:

- 03-settings-main -> settings.png
- 04-settings-performance-overlay -> performance-overlay.png
- 05-settings-layout -> display-settings.png
- 06-settings-overlay-position -> overlay-position.png
- 07-menu-portrait -> pause-virtual-controls.png
- 09-preview-portrait-controls-hidden -> controls-hidden.png
- 14b-menu-toggle-controls-scrolled -> controls-visibility.png
- 15b-menu-adjust-size-scrolled -> controls-size.png
- 11-landscape-large, 12-landscape-side, 13-landscape-hybrid -> layout-large/side/hybrid.png

Launcher screenshots:

- Windows 0.2.1 UI smoke (/tmp/win201): library-en/zh, deploy-en, settings-en (1120x820), copied to docs/assets/screenshots/launcher-windows-*.png and launcher/windows/docs/ui/v4-*.png;
- macOS 0.2.1 UI smoke (/tmp/mac201/screenshots): launcher-library-empty-dark-en and launcher-settings-dark-en -> launcher-macos-empty/settings.png; the full 18-shot set overwrote launcher/macos/screenshots/.

## Why the screenshots are synthetic

The iOS screenshots are Simulator captures of the app's preview test harness, not a game: the two
"screens" are flat blue and purple grids labelled **TOP 400x240** and **BOTTOM 320x240**, with the
real 0.2.1 control overlay, in-game menu and Settings UI. No ROM is loaded and no game data is
rendered. The Windows/macOS launcher screenshots show the launchers' built-in synthetic demo
entries or an empty library, never a real game.

## How the media was produced

- Pillow (Python) composition, Lanczos resizing, rounded cards, shadows, captions and Open
  Graph artwork.
- demo.gif: 960x640, 4 slides, per-slide captions, adaptive 96-colour palette, ~5 s loop,
  under 200 KB.
- PNG screenshots are palette-quantised to keep the committed media set small; hero, OG,
  social preview and the two large previews stay full RGB.
- No CDN, no external font, no tracker: system fonts only for the site.

## Licence and press use

The app icon and these composite images are (c) 2026 3ds2apple contributors and covered by the
repository's Apache-2.0 licence. Press and reviewers may reuse them unmodified with credit to
"3ds2apple (HFYKratos)" and must not imply endorsement by the project or by Nintendo.

## Not included

No Nintendo ROMs, decryption keys, BIOS, system files, fonts or game assets; no gameplay
screenshots; no generated C; no signed IPA; no commercial game names. 3ds2apple is not
affiliated with, endorsed by or sponsored by Nintendo.
