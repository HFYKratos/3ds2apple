# Launcher flow v2 (2026-11-16)

User-visible failure to fix: Windows installed the IPA but no game appeared / no ROM was pushed.
Root causes to verify: bare shell installed without packs, install/push not chained, push using the wrong bundle id,
and no single batch action. The new flow must make the successful path obvious and hard to miss.

## Navigation (minimal)
1. **游戏库 / Library**: import/add decrypted .3ds/.cci, list added games, remove/rename. No build/install/push buttons here.
2. **导入手机 / Deploy** (the second main tab): list the added library games with checkboxes; user selects one or several
   and presses **一键部署 / Deploy selected**. The app performs, in order: batch compile (local by default) -> compose one
   ROM-free IPA containing all selected built packs + GameCatalog -> sign/install with Impactor/plumesign -> push each
   selected GameRom + GameInfo -> verify -> show a clear Done state ("可以打开手机 App 游玩").
3. **Settings** (gear): only language, Apple ID/login (open Impactor), device connection status, logs, about/version.
   Remove build-mode/tool-path/UDID/bundle-id/tool-override controls from the normal UI; auto-detect bundled tools.

## Windows local build default
- Local LLVM/3dsrecomp build must be the default path, not a hidden experimental flag.
- Bundle/auto-locate the required tools; no file picker/path settings in the first version. If a bundled component is
  missing, show one actionable error on the Deploy page and still allow retry after fixing.
- Do not silently fall back to Preview; the macOS Build Agent stack was deleted on 2026-11-16 (the v2 launcher builds locally), so it is not part of the flow.

## Install/push correctness
- Never install the bare shell when games are selected: build first, compose with the selected real packs, verify the
  composed IPA contains Frameworks/GamePack-<TITLEID>.dylib and a non-empty schema-2 GameCatalog.json, then sign/install.
- Push must use the actual installed bundle id (shell install result / persisted InstalledBundleId), not just the template
  manifest value. Push all selected ROMs after install; verify files (size/sha) before marking done.
- Show per-step state and logs on the Deploy page; on failure, leave a retry button and explain which step failed.

## Packaging / repo layout
- Final user-facing artifact: one ZIP placed under the project's own `out/launchers/` (gitignored), never temp_transfer.
- Windows ZIP contains exactly one executable (single-file exe); macOS ZIP contains only the .app.
- Move/clean previous temp_transfer/dist artifacts out of the project workflow; keep source repo tidy.
