# Packaging the Linux Builder frontend

The frontend is two small Rust binaries with no runtime dependency beyond the
system OpenSSH client and a glibc-based Linux:

| File | Role |
|---|---|
| `zkb` | Shared cross-platform Builder client (protocol, upload, logs, download) |
| `3ds2apple-builder` | Linux frontend: VM discovery, host pairing, build wrapper, install guide |

The repository uses `.gitignore` for build outputs, so release artifacts are
never committed here. This directory contains the packaging recipes only.

## Arch / CachyOS (recommended for this project)

`PKGBUILD` builds both binaries from a git checkout of this repository and
installs the man page and desktop entry:

```bash
mkdir -p ~/build && cd ~/build
curl -LO https://raw.githubusercontent.com/HFYKratos/3ds2apple/main/builder/linux/packaging/PKGBUILD
makepkg -si
```

The package is named `3ds2apple-builder-git` and depends on `openssh`. It
installs:

```text
/usr/bin/zkb
/usr/bin/3ds2apple-builder
/usr/share/applications/3ds2apple-builder.desktop
/usr/share/man/man1/3ds2apple-builder.1
/usr/share/doc/3ds2apple-builder/README.md
/usr/share/licenses/3ds2apple-builder/{LICENSE,NOTICE}
```

Uninstall: `sudo pacman -R 3ds2apple-builder-git`

## Debian / Ubuntu

From the repository root:

```bash
# builds release binaries with cargo, then a portable tarball and a .deb
builder/linux/packaging/build-deb.sh --version 0.1.0 --arch amd64 --out dist

sudo apt install ./dist/3ds2apple-builder_0.1.0_amd64.deb
```

The script needs `cargo`, `rustc` and `dpkg-deb`; the tarball is produced even
when `dpkg-deb` is missing. Output goes to `dist/` (gitignored) together with a
`SHA256SUMS` file.

## Portable single-file binaries

The CLI binaries are ordinary dynamically linked ELF files (~4–6 MB each with
the release profile's `strip` and `lto = "thin"`). For a purely portable build
that works across distributions, compile against musl:

```bash
rustup target add x86_64-unknown-linux-musl
cd builder
cargo build --release --locked --target x86_64-unknown-linux-musl \
  -p builder-cli -p builder-linux
# -> target/x86_64-unknown-linux-musl/release/{zkb,3ds2apple-builder}

tar -C target/x86_64-unknown-linux-musl/release -czf \
  3ds2apple-builder-0.1.0-linux-x86_64-musl.tar.gz zkb 3ds2apple-builder
sha256sum 3ds2apple-builder-0.1.0-linux-x86_64-musl.tar.gz
```

Both binaries must be shipped together (or `zkb` must be on `PATH`) because the
frontend calls the shared client for protocol work. `--zkb PATH` and
`$ZKB_BIN` override the lookup.

## AppImage / GUI note

The CLI does not need an AppImage: a static (musl) binary or a `.deb`/package
is simpler and smaller. The planned Tauri GUI shell (`builder/ui` shared UI +
`builder/linux` Tauri wrapper) would be packaged as AppImage/deb/rpm with
`cargo tauri build`; on CachyOS/Arch the build host needs:

```bash
sudo pacman -S --needed base-devel webkit2gtk-4.1 libappindicator-gtk3 \
  librsvg nodejs npm rust cargo
```

That path is not part of this release: Tauri 2's crates and the WebKitGTK
development packages are unavailable in the environment where this slice was
built and verified, so the GUI remains design-only (see
[`../README.md`](../README.md) §GUI). The CLI is complete and is the supported
Linux frontend.

## Release checklist

1. `cd builder && cargo fmt --all -- --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace`.
2. Build the package(s) above on the oldest supported glibc (or with musl).
3. Record `sha256sum` of every artifact in `SHA256SUMS`; publish binaries and
   checksums in a GitHub Release. Binaries are unsigned; no Apple Developer ID
   or Authenticode certificate is involved (this is not a macOS/iOS project
   artifact).
4. Never attach a ROM, generated C, static library, IPA or key to a release.
   A game-specific IPA is built by the user on the user's own machines and is
   not distributable.
