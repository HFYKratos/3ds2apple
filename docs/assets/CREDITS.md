# Media credits and provenance

All images on this site and in the press kit are **project-owned synthetic media**. No
commercial game screenshots, logos, box art, ROM data, save data or game assets appear
anywhere, and no commercial game name is used in any filename, caption or alt text.

The images are unchanged from the synthetic 0.1.5 preview archive and are reused for the
0.2.0 media kit; no new screenshots were added. The 0.1.6 and 0.2.0 UI changes are described
in the text files (and on the site) rather than in new media.

## Sources

| Committed file | Built from |
|---|---|
| docs/assets/portrait.png | out/archive/0.1.5/sim-shots-all.tar.gz → 20261120-r7/01-portrait-controls-final.png (iOS Simulator, 1290×2796) |
| docs/assets/landscape.png | same archive → 20261120-r7/02-landscape-controls-final.png |
| docs/assets/hero.png | generated composite of the two previews above (1600×900) |
| docs/assets/og.png | generated Open Graph / Twitter card (1200×630) |
| docs/assets/demo.gif | 4-slide slideshow: portrait controls → landscape controls → pause menu Virtual controls → display/screen-layout settings (see below) |
| docs/assets/* | copies of the five files above, plus project icon variants and the social preview |
| docs/assets/screenshots/* | app previews from the same archive (see list) and launcher screenshots from the repository |
| docs/assets/readme-icon.png | original 3ds2apple app icon (project-owned, 1024×1024), moved here by the README media consolidation |
| docs/assets/social-preview.png | repository social preview artwork (1280×640) |

App previews in docs/assets/screenshots/ come from:

- 20261120-r2/landscape-{large,single,side,hybrid,original,custom}.png, portrait-{default,original,custom}.png, settings-en.png, custom-values-landscape-en.png;
- 20261120-r3/hybrid-preview.png;
- 20261120-r4/1080w/{01-pause-portrait,02-controls-visibility,03-controls-size,05-control-edit-portrait,07-screen-editor,08-display-settings}.png.

Launcher screenshots in this directory come from the repository:

- launcher/windows/docs/ui/v4-library-en.png and v4-library-zh.png;
- launcher/macos/screenshots/launcher-library-empty-dark-en.png.

## Why the screenshots are synthetic

The iOS screenshots are Simulator captures of the app's -previewGameView test harness,
not a game: the two "screens" are flat blue and purple grids labelled **TOP 400×240** and
**BOTTOM 320×240**, with the real control overlay on top. The pause menu, settings,
control editor and screen-layout screens are the app's real UI. No ROM is loaded and no game
data is rendered. The Windows/macOS launcher screenshots show the launchers' built-in
synthetic demo entries (Synthetic Demo Game, Synthetic No-Icon Game, publisher
Synthetic Studio), not real games.

The source archive (out/archive/0.1.5/sim-shots-all.tar.gz) is a local, git-ignored
build artifact. Every extracted preview was reviewed before use: they are grids, labels and
app chrome only.

## How the media was produced

- Pillow (Python) composition, resizing (Lanczos), rounded cards, shadows, captions and
  Open Graph artwork.
- demo.gif: 960×640, 4 slides, per-slide captions, shared 128-colour palette with
  Floyd–Steinberg dithering, ~11 s loop, under 1 MB.
- PNGs are palette-quantised (128 colours for screenshots and the GIF, 256 for the two
  large previews) to keep the whole committed media set well under the ~12 MB budget; the
  Open Graph image and hero stay full RGB.
- No CDN, no external font, no tracker: system fonts only for the site, and the only image
  assets are the files in this directory.

## Licence and press use

The app icon and these composite images are © 2026 3ds2apple contributors and covered by the
repository's Apache-2.0 licence. Press and reviewers may reuse them unmodified with credit to
"3ds2apple (HFYKratos)" and must not imply endorsement by the project or by Nintendo.

## Not included

No Nintendo ROMs, decryption keys, BIOS, system files, fonts or game assets; no gameplay
screenshots; no generated C; no signed IPA; no commercial game names. 3ds2apple is not
affiliated with, endorsed by or sponsored by Nintendo.
