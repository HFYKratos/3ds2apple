# Rust transitive dependency licences

The end of the repository `THIRD_PARTY.md` carries a generated

    ## Rust transitive dependencies

section: the third-party crates of the two shipped Rust workspaces

- `builder/` — `3ds2apple-pack`, the local ROM/package CLI used by the Windows launcher;
- `tools/devpush/` — the device bridge (AFC / usbmuxd / installation_proxy).

It is generated with [cargo-about](https://github.com/EmbarkStudios/cargo-about)
0.9.3 from the crate graphs pinned in each workspace `Cargo.lock`, so the list
matches the binaries that ship inside the launcher package. The pinned upstream
checkouts under `third_party/` (Zakuro, 3dsrecomp) are handled by the
"Runtime and tooling" table at the top of `THIRD_PARTY.md`; their own Rust
dependency licence texts belong to those upstream projects.

## Regenerate

    cargo install cargo-about --locked      # 0.9.3
    cd builder
    cargo about generate --format json -c ../licenses/rust/about.toml -o /tmp/builder-licenses.json
    cd ../tools/devpush
    cargo about generate --format json -c ../../licenses/rust/about.toml -o /tmp/devpush-licenses.json
    cd ../..
    node licenses/rust/cargo-about-to-markdown.mjs /tmp/builder-licenses.json "builder workspace (3ds2apple-pack)"
    node licenses/rust/cargo-about-to-markdown.mjs /tmp/devpush-licenses.json "tools/devpush (device bridge)"

Then replace the content between the two markers

    <!-- BEGIN RUST-TRANSITIVE-LICENSES -->
    <!-- END RUST-TRANSITIVE-LICENSES -->

in `THIRD_PARTY.md` with the two generated `.md` files (in the order above).
The release gate compares `THIRD_PARTY.md` byte-for-byte between the repository
and all three platform packages (both zips and the Linux tar.gz), so regenerate
and commit it before packaging a release.
