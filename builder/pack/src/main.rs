//! `3ds2apple-pack`: the desktop AOT-first command line.
//!
//! Flow (see docs/desktop-aot.md):
//!
//! ```text
//! # 1. import the user's own decrypted ROMs (headers only, no copy/hash)
//! 3ds2apple-pack packages add --roms "ROM/Pokémon Y.cci" "ROM/Pokémon Alpha Sapphire.cci"
//!
//! # 2. build AOT packs: fake preview here, real build on macOS via the scripts
//! 3ds2apple-pack build --queued --fake        # Linux/Windows preview
//! 3ds2apple-pack build --queued --execute     # macOS: recomp -> link -> pack
//!
//! # 3. allocate the selected packages into one shell IPA catalogue
//! 3ds2apple-pack catalog --all
//! 3ds2apple-pack pack --all --execute --fake-shell   # Linux preview IPA
//! 3ds2apple-pack pack --all --execute --base-app ios/app/build/Release-iphoneos/3ds2apple.app
//! ```
//!
//! The command never signs or installs anything, never copies game data and
//! never contacts a project server: the real compile runs on the user's own
//! macOS host through the existing `scripts/`.

use std::path::{Path, PathBuf};

use clap::{Args, Parser, Subcommand};
use serde_json::{json, Value};

use builder_pack::error::PackError;
use builder_pack::gameinfo::{self, PackageSummary};
use builder_pack::ops::{self, ImportOptions, ImportStatus, RecordOptions};
use builder_pack::plan;
use builder_pack::queue::{Queue, QueueEntry};
use builder_pack::rom;
use builder_pack::Result;

#[derive(Debug, Parser)]
#[command(
    name = "3ds2apple-pack",
    version,
    about = "Desktop AOT-first desktop flow: import ROMs, queue AOT builds, allocate per-game packages into one shell IPA",
    long_about = "Desktop side of the 3ds2apple AOT-first model. Import your own decrypted ROMs, detect title IDs, queue AOT builds, keep one deterministic package directory per game, and generate the GameCatalog.json that a single shell IPA can carry for several games. The real AOT compile/link runs on macOS through the existing scripts; --fake builds labelled placeholder packs for previews on Linux/Windows."
)]
struct Cli {
    /// Output root; packages live in <out>/packages/<TITLE_ID>/ (gitignored).
    #[arg(long, global = true, value_name = "DIR", default_value = "out")]
    out: PathBuf,
    /// Print machine-readable JSON on stdout.
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Inspect ROM headers without copying or hashing the ROM.
    Rom {
        #[command(subcommand)]
        command: RomCommand,
    },
    /// Manage the per-game package queue and directories.
    Packages {
        #[command(subcommand)]
        command: PackagesCommand,
    },
    /// Import ROMs, queue AOT builds and build them (fake preview or real macOS).
    Build(BuildArgs),
    /// Generate GameCatalog.json from built packages.
    Catalog(CatalogArgs),
    /// Allocate built packages into one shell IPA (delegates app staging to scripts/).
    Pack(PackArgs),
}

#[derive(Debug, Subcommand)]
enum RomCommand {
    /// Detect title ID, product code and sizes from one or more ROMs.
    Inspect {
        /// ROM files (.3ds/.cci/.ncch/.cxi/.app, decrypted).
        #[arg(value_name = "ROM", required = true)]
        roms: Vec<PathBuf>,
    },
}

#[derive(Debug, Subcommand)]
enum PackagesCommand {
    /// Detect ROMs, create package directories and queue their AOT builds.
    Add(PackagesAddArgs),
    /// List queued/built packages.
    List,
    /// Remove packages and their queue entries.
    Remove {
        /// Title IDs to remove.
        #[arg(value_name = "TITLE_ID", required = true)]
        title_ids: Vec<String>,
    },
    /// Verify package manifests and pack files (hashes every pack).
    Verify,
    /// Record a built GamePack.dylib (called by scripts/build-game-pack.sh).
    Record(RecordArgs),
}

#[derive(Debug, Args)]
struct PackagesAddArgs {
    /// ROM files to import (one or many).
    #[arg(long = "roms", value_name = "ROM", required = true, num_args = 1..)]
    roms: Vec<PathBuf>,
    /// Override the display name (single-ROM imports only).
    #[arg(long, value_name = "NAME")]
    display_name: Option<String>,
    /// AOT pack version to record (default 1).
    #[arg(long, default_value_t = 1, value_name = "N")]
    aot_version: u32,
    /// Re-import already built packages (keeps their pack).
    #[arg(long)]
    force: bool,
    /// Copy each ROM into its package (GameRom.<ext>) and record
    /// romFile/romSha256/romBytes, so the package is self-contained and the
    /// phone never imports game data.
    #[arg(long)]
    include_rom: bool,
}

#[derive(Debug, Args)]
struct RecordArgs {
    /// Title ID of the package.
    #[arg(long, value_name = "TITLE_ID")]
    title_id: String,
    /// Built GamePack.dylib to adopt (must be a Mach-O dylib).
    #[arg(long, value_name = "FILE")]
    pack: Option<PathBuf>,
    /// Record a deterministic fake placeholder instead of a real pack.
    #[arg(long, conflicts_with = "pack")]
    fake_placeholder: bool,
    /// ROM to record as provenance (title ID must match).
    #[arg(long, value_name = "ROM")]
    rom: Option<PathBuf>,
    /// Copy the ROM into the package (requires --rom), making the package
    /// self-contained: the shell then boots the bundled ROM.
    #[arg(long)]
    include_rom: bool,
    /// Display name (required when the package was not imported first).
    #[arg(long, value_name = "NAME")]
    display_name: Option<String>,
    /// Product code override.
    #[arg(long, value_name = "CODE")]
    product_code: Option<String>,
    /// AOT version override.
    #[arg(long, value_name = "N")]
    aot_version: Option<u32>,
}

#[derive(Debug, Args)]
struct BuildArgs {
    /// ROM files to import and build (one or many). ROMs that cannot be
    /// imported are reported and skipped; the command exits 1 if any requested
    /// ROM was rejected, while still building the accepted ones.
    #[arg(long = "roms", value_name = "ROM", num_args = 1.., conflicts_with = "queued")]
    roms: Vec<PathBuf>,
    /// Build queued packages (imported but not built yet). With --force, also
    /// rebuild packages that already have a pack.
    #[arg(long)]
    queued: bool,
    /// Write deterministic placeholder packs locally (Linux/Windows preview;
    /// not installable; cannot be combined with --execute).
    #[arg(long, conflicts_with = "execute")]
    fake: bool,
    /// Run the macOS build scripts (requires macOS, Xcode and the scripts/ tree).
    #[arg(long)]
    execute: bool,
    /// With --roms: re-import already built packages (keeps their pack).
    /// With --queued: rebuild packages that already have a pack.
    #[arg(long)]
    force: bool,
    /// Display name override for a single-ROM import.
    #[arg(long, value_name = "NAME")]
    display_name: Option<String>,
    /// AOT version for imported packages (default 1).
    #[arg(long, default_value_t = 1, value_name = "N")]
    aot_version: u32,
    /// With --roms: copy each ROM into its package (GameRom.<ext>), so the
    /// resulting package is self-contained.
    #[arg(long)]
    include_rom: bool,
}

#[derive(Debug, Args)]
struct CatalogArgs {
    /// Titles to include (repeatable); default: every built package.
    #[arg(long = "title-id", value_name = "TITLE_ID")]
    title_ids: Vec<String>,
    /// Explicit package directories (used by scripts/build-multi-game-ipa.sh).
    #[arg(long = "package-dir", value_name = "DIR")]
    package_dirs: Vec<PathBuf>,
    /// Write the catalogue here (default: <out>/packages/GameCatalog.json).
    #[arg(long, value_name = "FILE")]
    catalog_out: Option<PathBuf>,
}

#[derive(Debug, Args)]
struct PackArgs {
    /// Include every built package.
    #[arg(long, conflicts_with = "title_ids")]
    all: bool,
    /// Titles to include (repeatable).
    #[arg(long = "title-id", value_name = "TITLE_ID")]
    title_ids: Vec<String>,
    /// Built shell .app to extend (macOS real mode; staged and re-packaged by the script).
    #[arg(long, value_name = "APP")]
    base_app: Option<PathBuf>,
    /// Stage a minimal fake shell app (Linux preview IPA; not installable).
    #[arg(long)]
    fake_shell: bool,
    /// IPA output directory passed to the packaging script (default: IPA).
    #[arg(long, value_name = "DIR")]
    ipa_out: Option<PathBuf>,
    /// IPA base name without .ipa.
    #[arg(long, value_name = "NAME")]
    ipa_name: Option<String>,
    /// Accept --fake placeholder packs (does not make them installable).
    #[arg(long)]
    allow_placeholder: bool,
    /// Run scripts/build-multi-game-ipa.sh instead of printing its command.
    #[arg(long)]
    execute: bool,
}

/// Entry point.
fn main() {
    let cli = Cli::parse();
    match run(cli) {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("3ds2apple-pack: {error}");
            std::process::exit(1);
        }
    }
}

fn run(cli: Cli) -> Result<i32> {
    let json = cli.json;
    let out = &cli.out;
    match cli.command {
        Command::Rom { command } => match command {
            RomCommand::Inspect { roms } => cmd_rom_inspect(&roms, json),
        },
        Command::Packages { command } => match command {
            PackagesCommand::Add(args) => cmd_packages_add(out, args, json),
            PackagesCommand::List => cmd_packages_list(out, json),
            PackagesCommand::Remove { title_ids } => cmd_packages_remove(out, &title_ids, json),
            PackagesCommand::Verify => cmd_packages_verify(out, json),
            PackagesCommand::Record(args) => cmd_packages_record(out, args, json),
        },
        Command::Build(args) => cmd_build(out, args, json),
        Command::Catalog(args) => cmd_catalog(out, args, json),
        Command::Pack(args) => cmd_pack(out, args, json),
    }
}

// --- rom inspect -----------------------------------------------------------

fn cmd_rom_inspect(roms: &[PathBuf], json: bool) -> Result<i32> {
    let mut detected = Vec::new();
    let mut errors: Vec<Value> = Vec::new();
    for path in roms {
        match rom::detect_rom(path) {
            Ok(info) => {
                if json {
                    detected.push(serde_json::to_value(&info)?);
                } else {
                    println!(
                        "{}  titleID={}  productCode={}  container={:?}  bytes={}  content={}",
                        info.path.display(),
                        info.title_id,
                        info.product_code.as_deref().unwrap_or("-"),
                        info.container,
                        info.bytes,
                        info.content_bytes
                            .map(format_bytes)
                            .unwrap_or_else(|| "?".to_string())
                    );
                    println!("  displayName: {}", info.display_name);
                }
            }
            Err(error) => {
                errors.push(json!({"path": path.display().to_string(), "error": error.to_string()}))
            }
        }
    }
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"roms": detected, "errors": errors}))?
        );
    } else {
        for error in &errors {
            eprintln!(
                "error: {}",
                error["error"].as_str().unwrap_or("unknown error")
            );
        }
    }
    Ok(if errors.is_empty() { 0 } else { 1 })
}

// --- packages --------------------------------------------------------------

fn cmd_packages_add(out: &Path, args: PackagesAddArgs, json: bool) -> Result<i32> {
    if args.display_name.is_some() && args.roms.len() > 1 {
        return Err(PackError::invalid(
            "--display-name applies to a single ROM; import one ROM at a time to rename",
        ));
    }
    let options = ImportOptions {
        force: args.force,
        display_name: args.display_name.clone(),
        aot_version: args.aot_version,
        include_rom: args.include_rom,
    };
    let mut packages: Vec<Value> = Vec::new();
    let mut errors: Vec<Value> = Vec::new();
    for path in &args.roms {
        match ops::import_rom(out, path, &options) {
            Ok(result) => {
                if json {
                    packages.push(json!({
                        "titleID": result.game_info.title_id,
                        "displayName": result.game_info.display_name,
                        "productCode": result.game_info.product_code,
                        "packageDir": result.package_dir.display().to_string(),
                        "romPath": result.rom.path.display().to_string(),
                        "status": import_status(&result.status),
                    }));
                } else {
                    println!(
                        "queued {}  {}  {}  -> {}",
                        result.game_info.title_id,
                        result.game_info.display_name,
                        import_status(&result.status),
                        result.package_dir.display()
                    );
                }
            }
            Err(error) => {
                if !json {
                    eprintln!("error: {error}");
                }
                errors
                    .push(json!({"path": path.display().to_string(), "error": error.to_string()}));
            }
        }
    }
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"packages": packages, "errors": errors}))?
        );
    } else if !packages.is_empty() {
        println!("{} package(s) queued; run 'build --queued --fake' for a preview or 'build --queued --execute' on macOS", packages.len());
    }
    Ok(if errors.is_empty() { 0 } else { 1 })
}

fn import_status(status: &ImportStatus) -> &'static str {
    match status {
        ImportStatus::Imported => "imported",
        ImportStatus::Refreshed => "refreshed",
        ImportStatus::AlreadyBuilt => "already_built",
    }
}

fn cmd_packages_list(out: &Path, json: bool) -> Result<i32> {
    let report = ops::scan(out)?;
    if json {
        let packages: Vec<Value> = report
            .packages
            .iter()
            .map(package_json)
            .collect::<Result<_>>()?;
        let errors: Vec<Value> = report
            .errors
            .iter()
            .map(|(path, error)| json!({"path": path.display().to_string(), "error": error}))
            .collect();
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"packages": packages, "errors": errors}))?
        );
        return Ok(0);
    }
    if report.packages.is_empty() && report.errors.is_empty() {
        println!(
            "no packages in {}; import a ROM with 'packages add --roms ROM'",
            gameinfo::packages_root(out).display()
        );
        return Ok(0);
    }
    for package in &report.packages {
        print_package_line(package);
    }
    for (path, error) in &report.errors {
        eprintln!("warning: {}: {error}", path.display());
    }
    Ok(0)
}

fn print_package_line(package: &PackageSummary) {
    let pack = package
        .pack
        .as_ref()
        .map(|pack| {
            format!(
                "{} {} {}",
                format_bytes(pack.bytes),
                pack_format(&pack.format),
                &pack.sha256[..16]
            )
        })
        .unwrap_or_else(|| "not built".to_string());
    println!(
        "{}  {:<8}  {:<32}  {:<14}  {}",
        package.title_id,
        package_state(&package.state),
        truncate(&package.display_name, 32),
        package.product_code,
        pack
    );
    for issue in &package.issues {
        println!("  ! {issue}");
    }
}

fn package_state(state: &gameinfo::PackageState) -> &'static str {
    match state {
        gameinfo::PackageState::Queued => "queued",
        gameinfo::PackageState::Built => "built",
        gameinfo::PackageState::Broken => "broken",
    }
}

fn pack_format(format: &gameinfo::PackFormat) -> &'static str {
    match format {
        gameinfo::PackFormat::Macho => "macho",
        gameinfo::PackFormat::Placeholder => "fake",
    }
}

fn package_json(package: &PackageSummary) -> Result<Value> {
    Ok(json!({
        "titleID": package.title_id,
        "displayName": package.display_name,
        "productCode": package.product_code,
        "aotVersion": package.aot_version,
        "state": package_state(&package.state),
        "pack": match &package.pack {
            None => Value::Null,
            Some(pack) => json!({
                "sha256": pack.sha256,
                "bytes": pack.bytes,
                "format": pack_format(&pack.format),
            }),
        },
        "issues": package.issues,
    }))
}

fn cmd_packages_remove(out: &Path, title_ids: &[String], json: bool) -> Result<i32> {
    let removed = ops::remove(out, title_ids)?;
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"removed": removed}))?
        );
    } else {
        for title in &removed {
            println!("removed {title}");
        }
        println!("{} package(s) removed", removed.len());
    }
    Ok(0)
}

fn cmd_packages_verify(out: &Path, json: bool) -> Result<i32> {
    let (reports, errors) = ops::verify(out)?;
    let mut failed = !errors.is_empty();
    if json {
        let packages: Vec<Value> = reports
            .iter()
            .map(|report| {
                json!({
                    "titleID": report.title_id,
                    "displayName": report.display_name,
                    "state": package_state(&report.state),
                    "ok": report.ok,
                    "issues": report.issues,
                    "actualSha256": report.actual_sha256,
                })
            })
            .collect();
        let error_values: Vec<Value> = errors
            .iter()
            .map(|(path, error)| json!({"path": path.display().to_string(), "error": error}))
            .collect();
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"packages": packages, "errors": error_values}))?
        );
        return Ok(if failed { 1 } else { 0 });
    }
    for report in &reports {
        if report.ok {
            println!("ok    {}  {}", report.title_id, report.display_name);
        } else {
            failed = true;
            println!("FAIL  {}  {}", report.title_id, report.display_name);
        }
        for issue in &report.issues {
            println!("  - {issue}");
        }
    }
    for (path, error) in &errors {
        failed = true;
        eprintln!("FAIL  {}: {error}", path.display());
    }
    if reports.is_empty() && errors.is_empty() {
        println!(
            "no packages to verify in {}",
            gameinfo::packages_root(out).display()
        );
    }
    Ok(if failed { 1 } else { 0 })
}

fn cmd_packages_record(out: &Path, args: RecordArgs, json: bool) -> Result<i32> {
    if args.pack.is_none() && !args.fake_placeholder {
        return Err(PackError::invalid(
            "packages record needs --pack FILE or --fake-placeholder",
        ));
    }
    if args.include_rom && args.rom.is_none() {
        return Err(PackError::invalid(
            "packages record --include-rom needs --rom FILE (the ROM to copy into the package)",
        ));
    }
    let options = RecordOptions {
        title_id: args.title_id.clone(),
        pack: args.pack.clone(),
        fake_placeholder: args.fake_placeholder,
        rom: args.rom.clone(),
        include_rom: args.include_rom,
        display_name: args.display_name.clone(),
        product_code: args.product_code.clone(),
        aot_version: args.aot_version,
    };
    let info = ops::record_pack(out, &options)?;
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"package": serde_json::to_value(&info)?}))?
        );
    } else {
        let pack = info.pack.as_ref().expect("record always writes a pack");
        println!(
            "recorded {}  {}  {}  sha256={}",
            info.title_id,
            info.display_name,
            pack_format(&pack.format),
            pack.sha256
        );
    }
    Ok(0)
}

// --- build -----------------------------------------------------------------

fn cmd_build(out: &Path, args: BuildArgs, json: bool) -> Result<i32> {
    if args.roms.is_empty() && !args.queued {
        return Err(PackError::invalid("build needs --roms ROM... or --queued"));
    }
    if args.roms.len() > 1 && args.display_name.is_some() {
        return Err(PackError::invalid(
            "--display-name applies to a single ROM; import one ROM at a time to rename",
        ));
    }
    let mut errors: Vec<Value> = Vec::new();
    let mut titles: Vec<String> = Vec::new();
    if !args.roms.is_empty() {
        let options = ImportOptions {
            force: args.force,
            display_name: args.display_name.clone(),
            aot_version: args.aot_version,
            include_rom: args.include_rom,
        };
        for path in &args.roms {
            match ops::import_rom(out, path, &options) {
                Ok(result) => titles.push(result.game_info.title_id),
                Err(error) => {
                    if !json {
                        eprintln!("error: {error}");
                    }
                    errors.push(
                        json!({"path": path.display().to_string(), "error": error.to_string()}),
                    );
                }
            }
        }
    } else {
        let queue = Queue::load(out)?;
        let mut queued: Vec<String> = if args.force {
            // --force rebuilds every package in the queue, including built ones.
            queue
                .entries
                .iter()
                .map(|entry| entry.title_id.clone())
                .collect()
        } else {
            queue
                .queued()
                .iter()
                .map(|entry| entry.title_id.clone())
                .collect()
        };
        if queued.is_empty() {
            return Err(PackError::invalid(if args.force {
                "the queue has no packages to rebuild; import a ROM with 'packages add --roms ROM' first"
            } else {
                "the queue has no unbuilt packages; import a ROM with 'packages add --roms ROM' first, or pass --force to rebuild already built packages"
            }));
        }
        queued.sort();
        titles = queued;
    }
    // Partial imports are reported per ROM but must not hide a failed request
    // from scripts: accepted ROMs are still built, the exit code is non-zero.
    let import_failed = !errors.is_empty();
    if titles.is_empty() {
        if json {
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({"errors": errors}))?
            );
        }
        return Ok(1);
    }

    let queue = Queue::load(out)?;
    let entries: Vec<QueueEntry> = titles
        .iter()
        .filter_map(|title| queue.get(title).cloned())
        .collect();
    if entries.is_empty() {
        return Err(PackError::invalid(
            "no queue entries matched the requested titles; run 'packages add' first",
        ));
    }

    if args.fake {
        let built = ops::fake_build(out, &entries, args.force)?;
        if json {
            let packages: Vec<Value> = built
                .iter()
                .map(|pack| {
                    json!({
                        "titleID": pack.title_id,
                        "packageDir": pack.package_dir.display().to_string(),
                        "packageFile": "GamePack.dylib",
                        "format": "fake",
                        "sha256": pack.sha256,
                        "bytes": pack.bytes,
                    })
                })
                .collect();
            println!(
                "{}",
                serde_json::to_string_pretty(
                    &json!({"mode": "fake", "packages": packages, "errors": errors})
                )?
            );
        } else {
            for pack in &built {
                println!(
                    "built (fake) {}  {}  sha256={}",
                    pack.title_id,
                    pack.package_dir.display(),
                    pack.sha256
                );
            }
            println!(
                "warning: --fake packs are placeholders for previews; they are not installable and must not be shipped"
            );
        }
        return Ok(if import_failed { 1 } else { 0 });
    }

    if args.execute {
        let repo_root = find_repo_root().ok_or_else(|| {
            PackError::invalid(
                "could not find the repository root (scripts/build-recomp-ios.sh); set THREEDS2APPLE_ROOT or run from the checkout",
            )
        })?;
        for entry in &entries {
            if !Path::new(&entry.rom_path).is_file() {
                return Err(PackError::invalid(format!(
                    "{}: ROM is no longer at {}; re-import it",
                    entry.title_id, entry.rom_path
                )));
            }
        }
        if let Err(error) = plan::execute(&entries, out, &repo_root) {
            for entry in &entries {
                let _ = ops::mark_failed(out, &entry.title_id, &error.to_string());
            }
            return Err(error);
        }
        for entry in &entries {
            let info = ops::mark_built(out, &entry.title_id).map_err(|error| {
                PackError::invalid(format!(
                    "{}: build finished but the package is inconsistent: {error}",
                    entry.title_id
                ))
            })?;
            if !json {
                println!(
                    "built {}  {}  {}",
                    info.title_id,
                    info.display_name,
                    gameinfo::package_dir(out, &info.title_id).display()
                );
            }
        }
        if json {
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({
                    "mode": "execute",
                    "packages": entries.iter().map(|entry| entry.title_id.clone()).collect::<Vec<_>>(),
                    "errors": errors,
                }))?
            );
        }
        return Ok(if import_failed { 1 } else { 0 });
    }

    // Default: print the macOS plan without running anything.
    let text = plan::render_plan(&entries, out);
    if json {
        let commands: Vec<Vec<String>> = entries
            .iter()
            .flat_map(|entry| plan::steps(entry, out))
            .map(|step| {
                let mut command = vec![step.program.clone()];
                command.extend(step.args.iter().cloned());
                command
            })
            .collect();
        println!(
            "{}",
            serde_json::to_string_pretty(
                &json!({"mode": "plan", "commands": commands, "errors": errors})
            )?
        );
    } else {
        println!("{text}");
        println!("# real build: run the commands above from the repository root on macOS,");
        println!(
            "# or run 'build --queued --execute' on the Mac; '--fake' writes placeholders here."
        );
    }
    Ok(if import_failed { 1 } else { 0 })
}

// --- catalog ---------------------------------------------------------------

fn cmd_catalog(out: &Path, args: CatalogArgs, json: bool) -> Result<i32> {
    if !args.package_dirs.is_empty() && !args.title_ids.is_empty() {
        return Err(PackError::invalid(
            "catalog takes either --package-dir or --title-id, not both",
        ));
    }
    let (catalog, packages) = if !args.package_dirs.is_empty() {
        ops::allocate_dirs(&args.package_dirs)?
    } else {
        let filter = if args.title_ids.is_empty() {
            None
        } else {
            Some(args.title_ids.as_slice())
        };
        ops::allocate(out, filter)?
    };
    let path = args
        .catalog_out
        .unwrap_or_else(|| gameinfo::catalog_path(out));
    catalog.write(&path)?;
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "catalog": path.display().to_string(),
                "summary": catalog.summary(),
                "games": catalog.games,
                "packages": packages.iter().map(|package| package.title_id.clone()).collect::<Vec<_>>(),
            }))?
        );
    } else {
        println!("catalog: {}", path.display());
        println!("{}", catalog.summary());
        for package in &packages {
            if let Some(pack) = &package.pack {
                println!(
                    "  {}  {}  {}  {}",
                    package.title_id,
                    package.display_name,
                    pack_format(&pack.format),
                    format_bytes(pack.bytes)
                );
            }
        }
    }
    Ok(0)
}

// --- pack ------------------------------------------------------------------

fn cmd_pack(out: &Path, args: PackArgs, json: bool) -> Result<i32> {
    if !args.all && args.title_ids.is_empty() {
        return Err(PackError::invalid(
            "pack needs --all or --title-id TITLE_ID (repeatable)",
        ));
    }
    let filter = if args.all {
        None
    } else {
        Some(args.title_ids.as_slice())
    };
    let (catalog, packages) = ops::allocate(out, filter)?;
    if packages.is_empty() {
        // Do not write an empty catalogue and then fail inside the packaging
        // script: tell the user what is missing.
        return Err(PackError::invalid(format!(
            "no built packages in {}; import ROMs with 'packages add --roms ROM' and build them first",
            gameinfo::packages_root(out).display()
        )));
    }
    let catalog_path = gameinfo::catalog_path(out);
    catalog.write(&catalog_path)?;
    let package_dirs: Vec<String> = packages
        .iter()
        .map(|package| {
            gameinfo::package_dir(&out.to_path_buf(), &package.title_id)
                .display()
                .to_string()
        })
        .collect();
    let placeholders = catalog.all_placeholders(&packages);

    let mut command = vec![
        "scripts/build-multi-game-ipa.sh".to_string(),
        "--catalog".to_string(),
        catalog_path.display().to_string(),
    ];
    if let Some(base_app) = &args.base_app {
        command.push("--base-app".to_string());
        command.push(base_app.display().to_string());
    }
    if args.fake_shell {
        command.push("--fake-shell".to_string());
    }
    if placeholders || args.allow_placeholder {
        command.push("--allow-placeholder-dylibs".to_string());
    }
    if let Some(ipa_out) = &args.ipa_out {
        command.push("--out-dir".to_string());
        command.push(ipa_out.display().to_string());
    }
    if let Some(ipa_name) = &args.ipa_name {
        command.push("--ipa-name".to_string());
        command.push(ipa_name.clone());
    }
    command.extend(package_dirs.iter().cloned());

    if !args.execute {
        if json {
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({
                    "executed": false,
                    "catalog": catalog_path.display().to_string(),
                    "summary": catalog.summary(),
                    "placeholderPacks": placeholders,
                    "command": command,
                }))?
            );
        } else {
            println!("catalog: {}", catalog_path.display());
            println!("{}", catalog.summary());
            if placeholders {
                println!("warning: selected packs are --fake placeholders; the IPA is a layout preview only");
            }
            println!("run from the repository root:");
            println!("  {}", plan::shell_quote_join(&command));
        }
        return Ok(0);
    }

    let repo_root = find_repo_root().ok_or_else(|| {
        PackError::invalid(
            "could not find the repository root (scripts/build-multi-game-ipa.sh); set THREEDS2APPLE_ROOT or run from the checkout",
        )
    })?;
    let script = repo_root.join("scripts/build-multi-game-ipa.sh");
    eprintln!(
        "== allocating {} package(s) into one shell IPA",
        packages.len()
    );
    let status = std::process::Command::new(&script)
        .args(&command[1..])
        .current_dir(&repo_root)
        .status()
        .map_err(|error| PackError::io(&script, error))?;
    if !status.success() {
        return Err(PackError::invalid(format!(
            "{} exited with {status}",
            script.display()
        )));
    }
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "executed": true,
                "catalog": catalog_path.display().to_string(),
                "summary": catalog.summary(),
                "placeholderPacks": placeholders,
                "command": command,
            }))?
        );
    } else {
        println!(
            "packed {} game(s); catalogue: {}",
            packages.len(),
            catalog_path.display()
        );
    }
    Ok(0)
}

// --- helpers ---------------------------------------------------------------

/// Markers that identify the repository root. The AOT-first commands only need
/// the new scripts; the legacy single-game script is not the sole marker so
/// removing it later cannot break product/pack.
fn is_repository_root(dir: &Path) -> bool {
    [
        "scripts/build-game-pack.sh",
        "scripts/build-multi-game-ipa.sh",
        "scripts/build-ios-app.sh",
    ]
    .iter()
    .any(|relative| dir.join(relative).is_file())
}

fn find_repo_root() -> Option<PathBuf> {
    if let Some(value) = std::env::var_os("THREEDS2APPLE_ROOT") {
        let candidate = PathBuf::from(value);
        if is_repository_root(&candidate) {
            return Some(candidate);
        }
    }
    let mut dir = std::env::current_dir().ok()?;
    loop {
        if is_repository_root(&dir) {
            return Some(dir);
        }
        if !dir.pop() {
            break;
        }
    }
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let checkout = manifest.parent()?.parent()?.to_path_buf();
    if is_repository_root(&checkout) {
        Some(checkout)
    } else {
        None
    }
}

fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

fn truncate(text: &str, limit: usize) -> String {
    let count = text.chars().count();
    if count <= limit {
        return text.to_string();
    }
    let mut truncated: String = text.chars().take(limit.saturating_sub(1)).collect();
    truncated.push('…');
    truncated
}
