# Packaging the Windows Builder

The Windows Builder ships as a **portable folder / ZIP** first: one
`builder-windows.exe` with no runtime dependency (no Rust, no Python, no Node),
next to the licence and README files.

```powershell
# from the repository root, on Windows, with Rust installed
cd builder
cargo build -p builder-windows --release
.\windows\packaging\package.ps1 `
    -ExePath .\target\release\builder-windows.exe `
    -Version 0.1.0 `
    -OutDir .\dist
```

The script prints the path of the ZIP, its SHA256 and the SHA256 of the
executable inside. It also writes `SHA256SUMS` into the folder so a user can
verify a copied executable:

```powershell
Get-FileHash -Algorithm SHA256 .\builder-windows.exe
```

## Status

| Packaging | Status |
|---|---|
| Portable folder + ZIP + `SHA256SUMS` | implemented (`package.ps1`), exercised on Windows 10/11 x86_64 |
| MSI / NSIS installer | not implemented: needs the WiX/NSIS toolchain on Windows; the Tauri GUI shell that would bundle it is not part of this slice |
| Code signing (Authenticode) | not available: the project has no signing certificate. Unsigned executables trigger SmartScreen; the README explains how to verify a download instead of disabling SmartScreen |
| `zkb` CLI in the package | not included here: the CLI is released separately; the frontend is self-contained and shares the same `config.toml` when both are installed |

## Notes

- Build the executable on Windows (or cross-compile with the GNU toolchain);
  the produced binary is a single self-contained `.exe`.
- The release profile sets `strip`/thin LTO in `builder/Cargo.toml`; a release
  build of this frontend is a few MiB.
- Never commit the produced folder/ZIP: `dist/` and `target/` are gitignored, and
  release artifacts belong in GitHub Releases with `SHA256SUMS`.
