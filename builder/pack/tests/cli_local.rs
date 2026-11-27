//! End-to-end CLI tests that run anywhere (Linux/macOS, no Xcode, no ROM).
//!
//! Synthetic NCSD header images (headers + zero bytes only) are written to a
//! temporary directory and driven through the real binary:
//!
//!   rom inspect -> packages add -> build --fake -> packages verify
//!   -> catalog (byte-exact golden fixture) -> pack --execute --fake-shell (preview IPA)
//!
//! A guarded test also runs header detection against the user's local ROMs under
//! /ROM when that gitignored directory exists (no ROM content is copied or
//! logged; only title IDs / product codes).
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::TempDir;

/// The golden multi-game catalogue, shared with the Rust unit tests and
/// scripts/tests/desktop-aot-selfcheck.sh.
const FIXTURE: &str = include_str!("fixtures/catalog-multi.json");

const POKEMON_Y: u64 = 0x0004_0000_0005_5E00;
const ALPHA_SAPPHIRE: u64 = 0x0004_0000_0011_C500;

fn bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_3ds2apple-pack"))
}

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("builder/pack has a repository root")
        .to_path_buf()
}

#[derive(Debug)]
struct Output {
    success: bool,
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

fn run(args: &[String]) -> Output {
    let output = Command::new(bin())
        .args(args)
        .output()
        .expect("3ds2apple-pack runs");
    Output {
        success: output.status.success(),
        code: output.status.code(),
        stdout: String::from_utf8_lossy(&output.stdout).to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).to_string(),
    }
}

fn command_exists(name: &str) -> bool {
    Command::new("sh")
        .args(["-c", &format!("command -v {name} >/dev/null 2>&1")])
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

/// Synthetic NCSD image: 0x200 header at 0, partition 0 at 0x4000, NCCH header
/// at 0x4100. No game data; the detector only reads these headers.
fn synthetic_ncsd(title_id: u64, product_code: &str) -> Vec<u8> {
    let partition_offset = 0x4000_usize;
    let mut bytes = vec![0_u8; partition_offset + 0x200];
    let media_units = (bytes.len() / 512) as u32;
    bytes[0x100..0x104].copy_from_slice(b"NCSD");
    bytes[0x104..0x108].copy_from_slice(&media_units.to_le_bytes());
    bytes[0x108..0x110].copy_from_slice(&title_id.to_le_bytes());
    bytes[0x120..0x124].copy_from_slice(&((partition_offset / 512) as u32).to_le_bytes());
    let ncch = &mut bytes[partition_offset..];
    ncch[0x100..0x104].copy_from_slice(b"NCCH");
    ncch[0x104..0x108].copy_from_slice(&4_u32.to_le_bytes());
    ncch[0x112..0x114].copy_from_slice(&2_u16.to_le_bytes());
    ncch[0x118..0x120].copy_from_slice(&title_id.to_le_bytes());
    let code = product_code.as_bytes();
    ncch[0x150..0x150 + code.len()].copy_from_slice(code);
    bytes
}

/// Synthetic SMDH with neutral test titles and a gradient icon (no game data).
fn synthetic_smdh() -> Vec<u8> {
    let mut bytes = vec![0_u8; 0x36C0];
    bytes[..4].copy_from_slice(b"SMDH");
    let titles: [(usize, &str, &str); 2] = [
        (0, "テストゲーム", "Example Publisher"),
        (1, "Test Game", "Example Publisher"),
    ];
    for (index, short, publisher) in titles {
        let base = 0x8 + index * 0x200;
        put_utf16(&mut bytes, base, 0x80, short);
        put_utf16(&mut bytes, base + 0x180, 0x80, publisher);
    }
    for (index, pixel) in bytes[0x2008..0x3208].chunks_exact_mut(2).enumerate() {
        pixel.copy_from_slice(&(((index * 977) & 0xFFFF) as u16).to_le_bytes());
    }
    // Region lockout: Europe. The application-settings fill above would make
    // this meaningful field noise, so write the explicit test mask.
    bytes[0x2018..0x201C].copy_from_slice(&0x04_u32.to_le_bytes());
    bytes
}

fn put_utf16(bytes: &mut [u8], offset: usize, size: usize, text: &str) {
    let mut units: Vec<u16> = text.encode_utf16().take(size / 2 - 1).collect();
    units.push(0);
    for (index, unit) in units.iter().enumerate() {
        let start = offset + index * 2;
        bytes[start..start + 2].copy_from_slice(&unit.to_le_bytes());
    }
}

/// Synthetic NCSD whose ExeFS carries `smdh` (headers + zero padding only).
fn synthetic_ncsd_with_smdh(title_id: u64, product_code: &str, smdh: &[u8]) -> Vec<u8> {
    let partition_offset = 0x4000_usize;
    let exefs_relative = 0x400_u64;
    let exefs_size = 0x200 + smdh.len();
    let end = partition_offset as u64 + exefs_relative + exefs_size as u64;
    let len = (end.div_ceil(0x200) * 0x200) as usize;
    let mut bytes = vec![0_u8; len];
    let media_units = (len / 512) as u32;
    bytes[0x100..0x104].copy_from_slice(b"NCSD");
    bytes[0x104..0x108].copy_from_slice(&media_units.to_le_bytes());
    bytes[0x108..0x110].copy_from_slice(&title_id.to_le_bytes());
    bytes[0x120..0x124].copy_from_slice(&((partition_offset / 512) as u32).to_le_bytes());
    let ncch = &mut bytes[partition_offset..];
    ncch[0x100..0x104].copy_from_slice(b"NCCH");
    ncch[0x104..0x108].copy_from_slice(&4_u32.to_le_bytes());
    ncch[0x112..0x114].copy_from_slice(&2_u16.to_le_bytes());
    ncch[0x118..0x120].copy_from_slice(&title_id.to_le_bytes());
    let code = product_code.as_bytes();
    ncch[0x150..0x150 + code.len()].copy_from_slice(code);
    ncch[0x1A0..0x1A4].copy_from_slice(&((exefs_relative / 512) as u32).to_le_bytes());
    ncch[0x1A4..0x1A8].copy_from_slice(&((exefs_size as u64).div_ceil(0x200) as u32).to_le_bytes());
    let exefs = partition_offset + exefs_relative as usize;
    bytes[exefs..exefs + 4].copy_from_slice(b"icon");
    bytes[exefs + 12..exefs + 16].copy_from_slice(&(smdh.len() as u32).to_le_bytes());
    bytes[exefs + 0x200..exefs + 0x200 + smdh.len()].copy_from_slice(smdh);
    bytes
}

fn write_roms(dir: &Path) -> Vec<PathBuf> {
    let pokemon_y = dir.join("Pokémon Y.cci");
    std::fs::write(&pokemon_y, synthetic_ncsd(POKEMON_Y, "CTR-P-EK2A")).unwrap();
    let alpha = dir.join("Pokémon Alpha Sapphire.cci");
    std::fs::write(&alpha, synthetic_ncsd(ALPHA_SAPPHIRE, "CTR-P-ECLA")).unwrap();
    vec![pokemon_y, alpha]
}

#[test]
fn full_flow_is_deterministic_and_packs_a_preview_ipa() {
    let temp = TempDir::new().unwrap();
    let out = temp.path().join("out");
    let ipa_dir = temp.path().join("IPA");
    let roms = write_roms(temp.path());
    let out_arg = out.display().to_string();
    let out_args = vec!["--out".to_string(), out_arg.clone()];

    // 1. Header detection.
    let mut inspect_args = vec![
        "--json".to_string(),
        "rom".to_string(),
        "inspect".to_string(),
    ];
    inspect_args.extend(roms.iter().map(|rom| rom.display().to_string()));
    let inspect = run(&inspect_args);
    assert!(inspect.success, "rom inspect failed: {}", inspect.stderr);
    let inspected: serde_json::Value = serde_json::from_str(&inspect.stdout).unwrap();
    let detected = inspected["roms"].as_array().expect("roms array");
    assert_eq!(detected.len(), 2);
    assert_eq!(detected[0]["titleID"], "0004000000055E00");
    assert_eq!(detected[0]["productCode"], "CTR-P-EK2A");
    assert_eq!(detected[0]["displayName"], "Pokémon Y");
    assert_eq!(detected[1]["titleID"], "000400000011C500");
    assert_eq!(detected[1]["productCode"], "CTR-P-ECLA");

    // 2. Import + queue.
    let mut add_args = out_args.clone();
    add_args.extend(["packages".to_string(), "add".to_string()]);
    add_args.push("--roms".to_string());
    add_args.extend(roms.iter().map(|rom| rom.display().to_string()));
    let add = run(&add_args);
    assert!(add.success, "packages add failed: {}", add.stderr);

    // 3. Listing shows two queued packages.
    let mut list_args = out_args.clone();
    list_args.extend([
        "--json".to_string(),
        "packages".to_string(),
        "list".to_string(),
    ]);
    let list = run(&list_args);
    assert!(list.success, "packages list failed: {}", list.stderr);
    let listed: serde_json::Value = serde_json::from_str(&list.stdout).unwrap();
    assert_eq!(listed["packages"].as_array().unwrap().len(), 2);
    assert_eq!(listed["packages"][0]["state"], "queued");

    // 4. Fake AOT build (deterministic placeholder packs).
    let mut build_args = out_args.clone();
    build_args.extend([
        "build".to_string(),
        "--queued".to_string(),
        "--fake".to_string(),
    ]);
    let build = run(&build_args);
    assert!(build.success, "build --fake failed: {}", build.stderr);
    let package_y = out.join("packages/0004000000055E00/GamePack.dylib");
    assert!(package_y.is_file());
    assert!(std::fs::read(&package_y)
        .unwrap()
        .starts_with(b"3ds2apple-placeholder-gamepack"));

    // 5. Verification passes but flags the placeholders.
    let mut verify_args = out_args.clone();
    verify_args.extend([
        "--json".to_string(),
        "packages".to_string(),
        "verify".to_string(),
    ]);
    let verify = run(&verify_args);
    assert!(verify.success, "packages verify failed: {}", verify.stderr);
    let verified: serde_json::Value = serde_json::from_str(&verify.stdout).unwrap();
    for package in verified["packages"].as_array().unwrap() {
        assert_eq!(package["ok"], true);
        assert!(package["issues"]
            .as_array()
            .unwrap()
            .iter()
            .any(|issue| issue.as_str().unwrap_or_default().contains("placeholder")));
    }

    // 6. Catalogue is byte-exact and deterministic.
    let mut catalog_args = out_args.clone();
    catalog_args.extend(["catalog".to_string()]);
    let catalog = run(&catalog_args);
    assert!(catalog.success, "catalog failed: {}", catalog.stderr);
    let catalog_path = out.join("packages/GameCatalog.json");
    let first = std::fs::read_to_string(&catalog_path).unwrap();
    assert_eq!(first, FIXTURE);
    let catalog_again = run(&catalog_args);
    assert!(catalog_again.success);
    assert_eq!(std::fs::read_to_string(&catalog_path).unwrap(), first);

    // 7. pack without --execute prints the script command.
    let mut plan_args = out_args.clone();
    plan_args.extend([
        "pack".to_string(),
        "--all".to_string(),
        "--fake-shell".to_string(),
        "--ipa-out".to_string(),
        ipa_dir.display().to_string(),
    ]);
    let plan = run(&plan_args);
    assert!(plan.success, "pack plan failed: {}", plan.stderr);
    assert!(plan.stdout.contains("scripts/build-multi-game-ipa.sh"));
    assert!(plan.stdout.contains("--allow-placeholder-dylibs"));

    // 8. pack --execute --fake-shell produces a layout-preview IPA.
    let script = repo_root().join("scripts/build-multi-game-ipa.sh");
    let prerequisites = ["bash", "python3", "zip", "unzip"];
    if !script.is_file() || !prerequisites.iter().all(|name| command_exists(name)) {
        eprintln!("skipping preview-IPA staging: script or prerequisites unavailable");
        return;
    }
    let mut execute_args = out_args.clone();
    execute_args.extend([
        "pack".to_string(),
        "--all".to_string(),
        "--execute".to_string(),
        "--fake-shell".to_string(),
        "--ipa-out".to_string(),
        ipa_dir.display().to_string(),
    ]);
    let execute = run(&execute_args);
    assert!(execute.success, "pack --execute failed: {}", execute.stderr);
    let mut ipas: Vec<PathBuf> = std::fs::read_dir(&ipa_dir)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("ipa"))
        .collect();
    assert_eq!(ipas.len(), 1, "expected exactly one IPA, got {ipas:?}");
    let ipa = ipas.remove(0);
    let listing = Command::new("unzip")
        .args(["-l", ipa.to_str().unwrap()])
        .output()
        .expect("unzip runs");
    let listing = String::from_utf8_lossy(&listing.stdout);
    assert!(listing.contains("Payload/3ds2apple.app/GameCatalog.json"));
    assert!(listing.contains("Frameworks/GamePack-0004000000055E00.dylib"));
    assert!(listing.contains("Frameworks/GamePack-000400000011C500.dylib"));
    let embedded = Command::new("unzip")
        .args([
            "-p",
            ipa.to_str().unwrap(),
            "Payload/3ds2apple.app/GameCatalog.json",
        ])
        .output()
        .expect("unzip -p runs");
    assert_eq!(String::from_utf8_lossy(&embedded.stdout), FIXTURE);
}

#[test]
fn rejects_files_without_3ds_headers() {
    let temp = TempDir::new().unwrap();
    let bogus = temp.path().join("not-a-rom.3ds");
    std::fs::write(&bogus, vec![0_u8; 0x400]).unwrap();
    let output = run(&[
        "rom".to_string(),
        "inspect".to_string(),
        bogus.display().to_string(),
    ]);
    assert!(!output.success);
    assert!(
        output.stderr.contains("not a decrypted 3DS ROM"),
        "unexpected error: {}",
        output.stderr
    );
}

#[test]
fn empty_build_reports_a_clear_error() {
    let temp = TempDir::new().unwrap();
    let out = temp.path().join("out");
    let output = run(&[
        "--out".to_string(),
        out.display().to_string(),
        "build".to_string(),
        "--queued".to_string(),
        "--fake".to_string(),
    ]);
    assert!(!output.success);
    assert!(
        output.stderr.contains("no unbuilt packages"),
        "unexpected error: {}",
        output.stderr
    );
}

/// Header detection against the user's local (gitignored) ROM directory when it
/// exists. Reads only the first KiB of each ROM; nothing is copied or logged
/// beyond the public title ID / product code metadata.
#[test]
fn detects_local_roms_when_present() {
    let rom_dir = repo_root().join("ROM");
    if !rom_dir.is_dir() {
        eprintln!(
            "skipping: {} does not exist (local ROMs are gitignored)",
            rom_dir.display()
        );
        return;
    }
    let mut roms: Vec<PathBuf> = std::fs::read_dir(&rom_dir)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.is_file()
                && path
                    .extension()
                    .and_then(|ext| ext.to_str())
                    .map(|ext| matches!(ext.to_ascii_lowercase().as_str(), "cci" | "3ds"))
                    .unwrap_or(false)
        })
        .collect();
    roms.sort();
    if roms.is_empty() {
        eprintln!("skipping: no .cci/.3ds ROMs in {}", rom_dir.display());
        return;
    }
    for rom in roms.iter().take(4) {
        let output = run(&[
            "--json".to_string(),
            "rom".to_string(),
            "inspect".to_string(),
            rom.display().to_string(),
        ]);
        assert!(
            output.success,
            "{} failed: {}",
            rom.display(),
            output.stderr
        );
        let inspected: serde_json::Value = serde_json::from_str(&output.stdout).unwrap();
        let info = &inspected["roms"][0];
        let title_id = info["titleID"].as_str().expect("titleID");
        assert_eq!(title_id.len(), 16);
        assert!(title_id
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_lowercase()));
        assert!(info["productCode"]
            .as_str()
            .is_none_or(|code| code.starts_with("CTR-")));
        if rom.file_name().and_then(|name| name.to_str()) == Some("Pokemon Y.cci") {
            assert_eq!(title_id, "0004000000055E00");
            assert_eq!(info["productCode"], "CTR-P-EK2A");
            // SMDH metadata from the local ROM; no ROM content is logged.
            assert_eq!(info["displayName"], "Pokémon Y");
            assert_eq!(info["displayNames"]["en"], "Pokémon Y");
            assert_eq!(info["publisher"], "Nintendo");
        }
    }
}

#[test]
fn build_with_one_rejected_rom_exits_nonzero_but_builds_the_valid_one() {
    // S2: a rejected ROM is reported, accepted ROMs are still built, and the
    // command exits 1 so scripts/automation see the partial failure.
    let temp = TempDir::new().unwrap();
    let out = temp.path().join("out");
    let roms = write_roms(temp.path());
    let bogus = temp.path().join("not-a-rom.3ds");
    std::fs::write(&bogus, vec![0_u8; 0x400]).unwrap();

    let output = run(&[
        "--out".to_string(),
        out.display().to_string(),
        "build".to_string(),
        "--roms".to_string(),
        roms[0].display().to_string(),
        bogus.display().to_string(),
        "--fake".to_string(),
    ]);
    assert_eq!(output.code, Some(1), "stderr: {}", output.stderr);
    assert!(
        output.stderr.contains("not a decrypted 3DS ROM"),
        "stderr: {}",
        output.stderr
    );
    // The valid ROM was imported and fake-built.
    assert!(out
        .join("packages/0004000000055E00/GamePack.dylib")
        .is_file());
    let queue = std::fs::read_to_string(out.join("aot-queue.json")).unwrap();
    assert!(queue.contains("0004000000055E00"));
    assert!(!queue.contains("not-a-rom"));
}

#[test]
fn fake_and_execute_are_mutually_exclusive() {
    // S3: --fake must never silently swallow --execute.
    let temp = TempDir::new().unwrap();
    let out = temp.path().join("out");
    let output = run(&[
        "--out".to_string(),
        out.display().to_string(),
        "build".to_string(),
        "--queued".to_string(),
        "--fake".to_string(),
        "--execute".to_string(),
    ]);
    assert_eq!(output.code, Some(2), "stderr: {}", output.stderr);
    assert!(
        output.stderr.contains("cannot be used with"),
        "stderr: {}",
        output.stderr
    );
}

#[test]
fn queued_force_rebuilds_already_built_packages() {
    // S4: --force help says rebuild existing packs, and --queued --force
    // actually does it; without --force the queue has nothing unbuilt.
    let temp = TempDir::new().unwrap();
    let out = temp.path().join("out");
    let roms = write_roms(temp.path());
    let add = run(&[
        "--out".to_string(),
        out.display().to_string(),
        "packages".to_string(),
        "add".to_string(),
        "--roms".to_string(),
        roms[0].display().to_string(),
    ]);
    assert!(add.success, "{}", add.stderr);
    let build = run(&[
        "--out".to_string(),
        out.display().to_string(),
        "build".to_string(),
        "--queued".to_string(),
        "--fake".to_string(),
    ]);
    assert!(build.success, "{}", build.stderr);

    let without_force = run(&[
        "--out".to_string(),
        out.display().to_string(),
        "build".to_string(),
        "--queued".to_string(),
        "--fake".to_string(),
    ]);
    assert_eq!(without_force.code, Some(1));
    assert!(
        without_force.stderr.contains("pass --force"),
        "stderr: {}",
        without_force.stderr
    );

    let forced = run(&[
        "--out".to_string(),
        out.display().to_string(),
        "build".to_string(),
        "--queued".to_string(),
        "--force".to_string(),
        "--fake".to_string(),
    ]);
    assert!(forced.success, "stderr: {}", forced.stderr);
    assert!(forced.stdout.contains("built (fake)"));
}

#[test]
fn remove_with_a_missing_title_keeps_state_consistent() {
    // S1 CLI repro: a partial failure must not delete packages or leave a stale
    // queue entry behind.
    let temp = TempDir::new().unwrap();
    let out = temp.path().join("out");
    let roms = write_roms(temp.path());
    let mut add = vec![
        "--out".to_string(),
        out.display().to_string(),
        "packages".to_string(),
        "add".to_string(),
        "--roms".to_string(),
    ];
    add.extend(roms.iter().map(|rom| rom.display().to_string()));
    assert!(run(&add).success);
    assert!(
        run(&[
            "--out".to_string(),
            out.display().to_string(),
            "build".to_string(),
            "--queued".to_string(),
            "--fake".to_string(),
        ])
        .success
    );

    let remove = run(&[
        "--out".to_string(),
        out.display().to_string(),
        "packages".to_string(),
        "remove".to_string(),
        "0004000000055E00".to_string(),
        "0004000000000001".to_string(),
    ]);
    assert_eq!(remove.code, Some(1), "stderr: {}", remove.stderr);
    assert!(
        remove.stderr.contains("nothing was removed"),
        "stderr: {}",
        remove.stderr
    );
    assert!(out
        .join("packages/0004000000055E00/GameInfo.json")
        .is_file());
    assert!(out
        .join("packages/000400000011C500/GameInfo.json")
        .is_file());

    // The queue is still usable: --force rebuild succeeds after the refusal.
    let rebuild = run(&[
        "--out".to_string(),
        out.display().to_string(),
        "build".to_string(),
        "--queued".to_string(),
        "--force".to_string(),
        "--fake".to_string(),
    ]);
    assert!(rebuild.success, "stderr: {}", rebuild.stderr);
}

#[test]
fn pack_all_with_no_packages_errors_cleanly() {
    // N6: do not write an empty catalogue and fail later inside the script.
    let temp = TempDir::new().unwrap();
    let out = temp.path().join("out");
    let output = run(&[
        "--out".to_string(),
        out.display().to_string(),
        "pack".to_string(),
        "--all".to_string(),
        "--fake-shell".to_string(),
    ]);
    assert_eq!(output.code, Some(1), "stderr: {}", output.stderr);
    assert!(
        output.stderr.contains("no built packages"),
        "stderr: {}",
        output.stderr
    );
    assert!(!out.join("packages/GameCatalog.json").exists());
}

#[test]
fn include_rom_copies_the_rom_and_is_deterministic() {
    // S2: --include-rom must actually bundle the user ROM, record it in the
    // manifest/catalogue and produce byte-identical metadata on a re-import.
    let temp = TempDir::new().unwrap();
    let out = temp.path().join("out");
    let roms = write_roms(temp.path());
    let out_arg = out.display().to_string();
    let package_dir = out.join("packages/0004000000055E00");
    let bundled = package_dir.join("GameRom.cci");

    let add = |force: bool| {
        let mut args = vec![
            "--out".to_string(),
            out_arg.clone(),
            "packages".to_string(),
            "add".to_string(),
            "--roms".to_string(),
            roms[0].display().to_string(),
            "--include-rom".to_string(),
        ];
        if force {
            args.push("--force".to_string());
        }
        run(&args)
    };
    let first = add(false);
    assert!(first.success, "stderr: {}", first.stderr);
    assert!(bundled.is_file(), "the ROM copy must be in the package");
    let first_manifest = std::fs::read(package_dir.join("GameInfo.json")).unwrap();
    let manifest: serde_json::Value = serde_json::from_slice(&first_manifest).unwrap();
    assert_eq!(manifest["romFile"], "GameRom.cci");
    assert_eq!(manifest["romBytes"], 16_896);
    assert!(manifest["romSha256"]
        .as_str()
        .is_some_and(|sha| sha.len() == 64));

    let second = add(true);
    assert!(second.success, "stderr: {}", second.stderr);
    assert_eq!(
        std::fs::read(package_dir.join("GameInfo.json")).unwrap(),
        first_manifest,
        "re-import with --include-rom must be deterministic"
    );

    // Fake-build so the catalogue can be generated, then verify the ROM too.
    let build = run(&[
        "--out".to_string(),
        out_arg.clone(),
        "build".to_string(),
        "--queued".to_string(),
        "--fake".to_string(),
    ]);
    assert!(build.success, "stderr: {}", build.stderr);
    let verify = run(&[
        "--out".to_string(),
        out_arg.clone(),
        "packages".to_string(),
        "verify".to_string(),
    ]);
    assert!(verify.success, "stderr: {}", verify.stderr);
    assert!(verify.stdout.contains("ok"), "stdout: {}", verify.stdout);

    let catalog_cmd = run(&["--out".to_string(), out_arg, "catalog".to_string()]);
    assert!(catalog_cmd.success, "stderr: {}", catalog_cmd.stderr);
    let catalog = std::fs::read_to_string(out.join("packages/GameCatalog.json")).unwrap();
    assert!(
        catalog.contains("\"romFile\":\"Roms/0004000000055E00.cci\""),
        "{catalog}"
    );

    // Without --include-rom no ROM copy is added.
    let plain_out = temp.path().join("plain-out");
    let plain = run(&[
        "--out".to_string(),
        plain_out.display().to_string(),
        "packages".to_string(),
        "add".to_string(),
        "--roms".to_string(),
        roms[0].display().to_string(),
    ]);
    assert!(plain.success, "stderr: {}", plain.stderr);
    assert!(!plain_out
        .join("packages/0004000000055E00/GameRom.cci")
        .exists());
}

/// The launcher contract: package dir cover.png + JSON displayNames/publisher/
/// coverPath on packages add/list, with displayName kept as the English title.
#[test]
fn smdh_metadata_and_cover_flow_through_cli_json() {
    let temp = TempDir::new().unwrap();
    let out = temp.path().join("out");
    let out_arg = out.display().to_string();
    // The file name deliberately differs from the SMDH title.
    let rom = temp.path().join("local-dump.cci");
    std::fs::write(
        &rom,
        synthetic_ncsd_with_smdh(POKEMON_Y, "CTR-P-EK2A", &synthetic_smdh()),
    )
    .unwrap();

    // rom inspect exposes the SMDH metadata too.
    let inspect = run(&[
        "--json".to_string(),
        "rom".to_string(),
        "inspect".to_string(),
        rom.display().to_string(),
    ]);
    assert!(inspect.success, "stderr: {}", inspect.stderr);
    let inspected: serde_json::Value = serde_json::from_str(&inspect.stdout).unwrap();
    assert_eq!(inspected["roms"][0]["displayName"], "Test Game");
    assert_eq!(inspected["roms"][0]["displayNames"]["en"], "Test Game");
    assert_eq!(inspected["roms"][0]["displayNames"]["ja"], "テストゲーム");
    assert_eq!(inspected["roms"][0]["publisher"], "Example Publisher");
    assert_eq!(inspected["roms"][0]["region"], "EU");

    // packages add --json: displayNames/publisher/coverPath (absolute).
    let add = run(&[
        "--json".to_string(),
        "--out".to_string(),
        out_arg.clone(),
        "packages".to_string(),
        "add".to_string(),
        "--roms".to_string(),
        rom.display().to_string(),
    ]);
    assert!(add.success, "stderr: {}", add.stderr);
    let added: serde_json::Value = serde_json::from_str(&add.stdout).unwrap();
    let package = &added["packages"][0];
    assert_eq!(package["titleID"], "0004000000055E00");
    assert_eq!(package["displayName"], "Test Game");
    assert_eq!(package["displayNames"]["en"], "Test Game");
    assert_eq!(package["displayNames"]["ja"], "テストゲーム");
    assert_eq!(package["publisher"], "Example Publisher");
    assert_eq!(package["region"], "EU");
    let cover = Path::new(package["coverPath"].as_str().expect("coverPath"));
    assert!(
        cover.is_absolute(),
        "coverPath is absolute: {}",
        cover.display()
    );
    assert!(cover.is_file());
    assert!(cover.starts_with(&out), "cover stays in the output tree");
    let png = std::fs::read(cover).unwrap();
    assert!(png.starts_with(b"\x89PNG\r\n\x1a\n"), "cover is a PNG");
    assert!(png.len() < 64 * 1024, "48x48 cover stays small");

    // GameInfo.json records the additive metadata and the package-relative cover.
    let manifest: serde_json::Value = serde_json::from_slice(
        &std::fs::read(out.join("packages/0004000000055E00/GameInfo.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(manifest["displayName"], "Test Game");
    assert_eq!(manifest["displayNames"]["en"], "Test Game");
    assert_eq!(manifest["publisher"], "Example Publisher");
    assert_eq!(manifest["region"], "EU");
    assert_eq!(manifest["coverPath"], "cover.png");

    // packages list --json exposes the same contract for launchers.
    let list = run(&[
        "--json".to_string(),
        "--out".to_string(),
        out_arg,
        "packages".to_string(),
        "list".to_string(),
    ]);
    assert!(list.success, "stderr: {}", list.stderr);
    let listed: serde_json::Value = serde_json::from_str(&list.stdout).unwrap();
    let package = &listed["packages"][0];
    assert_eq!(package["displayName"], "Test Game");
    assert_eq!(package["displayNames"]["ja"], "テストゲーム");
    assert_eq!(package["publisher"], "Example Publisher");
    assert_eq!(package["region"], "EU");
    assert!(package["coverPath"]
        .as_str()
        .expect("coverPath")
        .ends_with("cover.png"));
}

#[test]
fn rom_without_smdh_keeps_the_file_stem_and_no_cover() {
    let temp = TempDir::new().unwrap();
    let out = temp.path().join("out");
    let rom = temp.path().join("Plain Game.cci");
    std::fs::write(&rom, synthetic_ncsd(POKEMON_Y, "CTR-P-EK2A")).unwrap();
    let add = run(&[
        "--json".to_string(),
        "--out".to_string(),
        out.display().to_string(),
        "packages".to_string(),
        "add".to_string(),
        "--roms".to_string(),
        rom.display().to_string(),
    ]);
    assert!(add.success, "stderr: {}", add.stderr);
    let added: serde_json::Value = serde_json::from_str(&add.stdout).unwrap();
    let package = &added["packages"][0];
    assert_eq!(package["displayName"], "Plain Game");
    assert_eq!(package["displayNames"], serde_json::json!({}));
    assert_eq!(package["publisher"], "");
    assert!(package["coverPath"].is_null());
    assert!(!out.join("packages/0004000000055E00/cover.png").exists());
    let manifest =
        std::fs::read_to_string(out.join("packages/0004000000055E00/GameInfo.json")).unwrap();
    assert!(!manifest.contains("displayNames"), "{manifest}");
    assert!(!manifest.contains("coverPath"), "{manifest}");
}

#[test]
fn truncated_smdh_rom_falls_back_without_error() {
    let temp = TempDir::new().unwrap();
    let out = temp.path().join("out");
    let rom = temp.path().join("Truncated.cci");
    let mut bytes = synthetic_ncsd_with_smdh(POKEMON_Y, "CTR-P-EK2A", &synthetic_smdh());
    bytes.truncate(bytes.len() - 0x400);
    std::fs::write(&rom, bytes).unwrap();
    let add = run(&[
        "--json".to_string(),
        "--out".to_string(),
        out.display().to_string(),
        "packages".to_string(),
        "add".to_string(),
        "--roms".to_string(),
        rom.display().to_string(),
    ]);
    assert!(add.success, "stderr: {}", add.stderr);
    let added: serde_json::Value = serde_json::from_str(&add.stdout).unwrap();
    let package = &added["packages"][0];
    assert_eq!(package["displayName"], "Truncated");
    assert!(package["coverPath"].is_null());
}

/// End-to-end SMDH extraction against the user's local (gitignored) ROM. The
/// icon is written only into a temporary package tree, never into the repo.
#[test]
fn imports_local_rom_metadata_into_a_temp_package() {
    let rom = repo_root().join("ROM").join("Pokemon Y.cci");
    if !rom.is_file() {
        eprintln!("skipping: {} is not present", rom.display());
        return;
    }
    let temp = TempDir::new().unwrap();
    let out = temp.path().join("out");
    let add = run(&[
        "--json".to_string(),
        "--out".to_string(),
        out.display().to_string(),
        "packages".to_string(),
        "add".to_string(),
        "--roms".to_string(),
        rom.display().to_string(),
    ]);
    assert!(add.success, "stderr: {}", add.stderr);
    let added: serde_json::Value = serde_json::from_str(&add.stdout).unwrap();
    let package = &added["packages"][0];
    assert_eq!(package["titleID"], "0004000000055E00");
    assert_eq!(package["displayName"], "Pokémon Y");
    assert_eq!(package["displayNames"]["en"], "Pokémon Y");
    assert_eq!(package["displayNames"]["ja"], "ポケットモンスター Ｙ");
    assert_eq!(package["publisher"], "Nintendo");
    let cover = Path::new(package["coverPath"].as_str().expect("coverPath"));
    assert!(cover.starts_with(&out), "cover stays in the temp tree");
    let png = std::fs::read(cover).unwrap();
    assert!(png.starts_with(b"\x89PNG\r\n\x1a\n"));
    assert!(png.len() < 64 * 1024, "48x48 cover is {} bytes", png.len());
    // The temp tree holds only the package output: nothing leaked into the repo.
    assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 1);
}

/// Portable .32a build packages: export -> list -> import -> replace through the
/// real binary (a synthetic ROM header and a fake Mach-O-magic pack; no game data).
#[test]
fn builds_export_list_and_import_round_trip() {
    let temp = TempDir::new().unwrap();
    let root = temp.path().join("root");
    let root2 = temp.path().join("root2");
    let title = format!("{:016X}", POKEMON_Y);
    let rom = temp.path().join("Example Game.cci");
    std::fs::write(&rom, synthetic_ncsd(POKEMON_Y, "CTR-P-EK2A")).unwrap();
    let root_arg = root.display().to_string();
    let base = || vec!["--out".to_string(), root_arg.clone()];

    let mut add = base();
    add.extend([
        "packages".to_string(),
        "add".to_string(),
        "--roms".to_string(),
        rom.display().to_string(),
    ]);
    let added = run(&add);
    assert!(added.success, "packages add failed: {}", added.stderr);

    let mut fake = vec![0_u8; 4096];
    fake[..4].copy_from_slice(&[0xCF, 0xFA, 0xED, 0xFE]);
    let pack = temp.path().join("fake-GamePack.dylib");
    std::fs::write(&pack, &fake).unwrap();
    let mut record = base();
    record.extend([
        "packages".to_string(),
        "record".to_string(),
        "--title-id".to_string(),
        title.clone(),
        "--pack".to_string(),
        pack.display().to_string(),
    ]);
    let recorded = run(&record);
    assert!(recorded.success, "packages record failed: {}", recorded.stderr);

    let mut export = base();
    export.extend([
        "--json".to_string(),
        "builds".to_string(),
        "export".to_string(),
        "--title-id".to_string(),
        title.clone(),
        "--app-version".to_string(),
        "9.9.9".to_string(),
    ]);
    let exported = run(&export);
    assert!(
        exported.success,
        "builds export failed: {}\n{}",
        exported.stdout, exported.stderr
    );
    let exported_json: serde_json::Value = serde_json::from_str(&exported.stdout).unwrap();
    assert_eq!(exported_json["errors"].as_array().unwrap().len(), 0);
    let build = &exported_json["builds"][0];
    assert_eq!(build["titleID"], title.as_str());
    assert_eq!(build["romIncluded"], true);
    let package_path = PathBuf::from(build["path"].as_str().unwrap());
    assert!(package_path.is_file());
    assert!(package_path
        .file_name()
        .unwrap()
        .to_string_lossy()
        .ends_with(".32a"));

    let mut list = base();
    list.extend(["--json".to_string(), "builds".to_string(), "list".to_string()]);
    let listed = run(&list);
    assert!(listed.success, "builds list failed: {}", listed.stderr);
    let listed_json: serde_json::Value = serde_json::from_str(&listed.stdout).unwrap();
    assert_eq!(listed_json["builds"].as_array().unwrap().len(), 1);
    assert_eq!(listed_json["builds"][0]["titleID"], title.as_str());

    let root2_arg = root2.display().to_string();
    let import_args = || {
        let mut args = vec!["--out".to_string(), root2_arg.clone()];
        args.extend([
            "--json".to_string(),
            "builds".to_string(),
            "import".to_string(),
            package_path.display().to_string(),
        ]);
        args
    };
    let imported = run(&import_args());
    assert!(
        imported.success,
        "builds import failed: {}\n{}",
        imported.stdout, imported.stderr
    );
    let imported_json: serde_json::Value = serde_json::from_str(&imported.stdout).unwrap();
    assert_eq!(imported_json["imported"]["titleID"], title.as_str());
    assert_eq!(imported_json["imported"]["romIncluded"], true);

    // The imported .32a keeps the embedded GameRom provenance in GameInfo.json
    // (the pack CLI then derives a catalogue romFile from it). The launcher-first
    // compose step must drop that romFile from the shell GameCatalog: the data is
    // pushed to Documents/Games, and iOS would treat a catalogue romFile as a
    // bundled Roms/<TITLE_ID>.<ext> and refuse to launch the game.
    let imported_info: serde_json::Value = serde_json::from_slice(
        &std::fs::read(root2.join("packages").join(&title).join("GameInfo.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(imported_info["romFile"], "GameRom.cci", "{imported_info}");
    assert!(
        imported_info["romSha256"]
            .as_str()
            .is_some_and(|sha| sha.len() == 64),
        "{imported_info}"
    );
    assert!(
        imported_info["romBytes"].as_u64().is_some_and(|bytes| bytes > 0),
        "{imported_info}"
    );

    let verify = run(&[
        "--out".to_string(),
        root2.display().to_string(),
        "packages".to_string(),
        "verify".to_string(),
    ]);
    assert!(verify.success, "verify failed: {}\n{}", verify.stdout, verify.stderr);

    let refused = run(&import_args());
    assert!(!refused.success, "a conflicting import must be refused");

    let mut replace = import_args();
    replace.push("--replace".to_string());
    let replaced = run(&replace);
    assert!(
        replaced.success,
        "replace import failed: {}\n{}",
        replaced.stdout, replaced.stderr
    );
    let replaced_json: serde_json::Value = serde_json::from_str(&replaced.stdout).unwrap();
    assert_eq!(replaced_json["imported"]["replaced"], true);
}

/// Advanced build settings: the CLI accepts --opt-level/--lto/--fast-math and
/// prints the THREEDS2APPLE_AOT_* environment for the scripts; an unknown level
/// is rejected before anything runs.
#[test]
fn build_plan_reports_the_codegen_options() {
    let temp = TempDir::new().unwrap();
    let out = temp.path().join("out");
    let rom = temp.path().join("Example Game.cci");
    std::fs::write(&rom, synthetic_ncsd(POKEMON_Y, "CTR-P-EK2A")).unwrap();
    let out_arg = out.display().to_string();
    let base = |extra: &[&str]| {
        let mut args = vec!["--out".to_string(), out_arg.clone()];
        args.extend(extra.iter().map(|value| value.to_string()));
        args
    };
    let add = run(&base(&[
        "packages", "add", "--roms", rom.to_str().unwrap(),
    ]));
    assert!(add.success, "packages add failed: {}", add.stderr);

    let plan = run(&base(&[
        "build", "--queued", "--opt-level", "O3", "--lto", "--fast-math",
    ]));
    assert!(plan.success, "plan failed: {}\n{}", plan.stdout, plan.stderr);
    assert!(plan.stdout.contains("THREEDS2APPLE_AOT_OPT=O3"), "{}", plan.stdout);
    assert!(plan.stdout.contains("THREEDS2APPLE_AOT_LTO=1"), "{}", plan.stdout);
    assert!(plan.stdout.contains("THREEDS2APPLE_AOT_FAST_MATH=1"), "{}", plan.stdout);
    assert!(plan.stdout.contains("--fast-math changes guest float results"), "{}", plan.stdout);

    let json = run(&base(&[
        "--json", "build", "--queued", "--opt-level", "Oz",
    ]));
    assert!(json.success, "json plan failed: {}", json.stderr);
    let value: serde_json::Value = serde_json::from_str(&json.stdout).unwrap();
    assert_eq!(value["buildOptions"]["optLevel"], "Oz");
    assert_eq!(value["cacheMarker"], "opt=Oz;lto=0;fastmath=0");
    assert_eq!(
        value["commands"][0]["env"]["THREEDS2APPLE_AOT_OPT"].as_str(),
        Some("Oz")
    );

    let invalid = run(&base(&["build", "--queued", "--opt-level", "O9"]));
    assert!(!invalid.success, "O9 must be rejected");
    assert!(invalid.stderr.contains("opt-level"), "{}", invalid.stderr);
}
