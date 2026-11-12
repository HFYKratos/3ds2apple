//! Build glue for the `linked` feature.
//!
//! A `linked` build carries one game's recompiled code, and `Linked` needs that
//! game's title ID at load time: 3dsrecomp's generated tables hold the code but
//! not the title it came from (a `3dsrecomp port` program bakes it into its
//! `main.rs` the same way).
//!
//! `ZAKURO_LINKED_PROGRAM_ID` is the 16 hex digit 3DS title ID of the ROM that
//! was recompiled, for example `0004000000055D00` for Pokémon Y. The default,
//! interpreter-only build needs nothing and ignores it.
//!
//! See `RECOMP.md` next to this file for the whole pipeline.

use std::env;

fn main() {
    println!("cargo:rerun-if-env-changed=ZAKURO_LINKED_PROGRAM_ID");
    if env::var_os("CARGO_FEATURE_LINKED").is_none() {
        return;
    }

    let value = env::var("ZAKURO_LINKED_PROGRAM_ID").unwrap_or_else(|_| {
        panic!(
            "the `linked` feature needs ZAKURO_LINKED_PROGRAM_ID, the 16 hex digit title ID \
             of the ROM passed to 3dsrecomp port (for example 0004000000055D00). See \
             ios/zakuro-ios/RECOMP.md"
        )
    });
    let value = value.trim();
    let digits = value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
        .unwrap_or(value);
    if digits.len() != 16 || !digits.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        panic!(
            "ZAKURO_LINKED_PROGRAM_ID must be the 16 hex digit 3DS title ID, \
             for example 0004000000055D00, got `{value}`. See ios/zakuro-ios/RECOMP.md"
        );
    }

    // The crate reads this back with `option_env!`; keep the canonical digits.
    println!("cargo:rustc-env=ZAKURO_LINKED_PROGRAM_ID={digits}");
}
