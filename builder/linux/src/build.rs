//! `build`: pick a ROM, drive the shared `zkb build`, verify the IPA, show the
//! result and the installation guidance.
//!
//! The protocol path, upload, log stream, cancellation and artifact download
//! are entirely the shared CLI's job. This wrapper adds the Linux first-run
//! conveniences: it can find the ROM in the usual local directories, it picks
//! the only configured host automatically, and it re-hashes the downloaded IPA
//! against the Agent's manifest before telling the user the build succeeded.

use std::io::{BufRead, IsTerminal};
use std::path::{Path, PathBuf};

use builder_core::config::BuilderConfig;
use serde::Serialize;

use crate::error::Error;
use crate::install::{self, IpaInfo};
use crate::output::{format_bytes, Printer};
use crate::paths::{self, RomCandidate};
use crate::zkb::{self, Zkb};

/// Options for `build` (the shared CLI's flags plus local ROM discovery).
#[derive(Debug, Clone, Default)]
pub struct BuildOptions {
    pub host: Option<String>,
    pub rom: Option<PathBuf>,
    pub rom_dirs: Vec<PathBuf>,
    pub name: Option<String>,
    pub display_name: Option<String>,
    pub bundle_id: Option<String>,
    pub title_id: Option<String>,
    pub out: Option<PathBuf>,
    pub no_moltenvk: bool,
    pub hardware_renderer: bool,
    pub clean: bool,
    pub keep_input: bool,
    pub expected_revision: Option<String>,
    pub no_download: bool,
    pub allow_any_file: bool,
}

/// The verified local artifact plus the facts worth printing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BuildReport {
    pub host: String,
    pub game_name: String,
    pub display_name: String,
    pub ipa: String,
    pub ipa_bytes: u64,
    pub sha256: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub manifest: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_revision: Option<String>,
}

/// Run one build and return the process exit code.
pub fn build<F>(
    options: &BuildOptions,
    config_path: &Path,
    env_get: F,
    zkb: &Zkb,
    printer: Printer,
    interactive: bool,
) -> Result<i32, Error>
where
    F: Fn(&str) -> Option<String>,
{
    let host = resolve_host(config_path, options.host.as_deref(), printer)?;
    let rom = resolve_rom(options, &env_get, printer, interactive)?;
    let name = resolve_game_name(options, &rom.path)?;
    let display_name = resolve_display_name(options, &rom.path);
    let out = options
        .out
        .clone()
        .unwrap_or_else(|| paths::default_out_dir(&name));
    std::fs::create_dir_all(&out)
        .map_err(|error| Error::local(format!("cannot create {}: {error}", out.display())))?;

    let args = build_zkb_args(
        options,
        &host,
        &rom.path,
        &name,
        &out,
        Some(config_path),
        printer.json,
    );
    printer.progress(format!("building {display_name} ({name}) on host {host}"));
    printer.progress(format!(
        "ROM: {} ({})",
        rom.path.display(),
        format_bytes(rom.bytes)
    ));
    printer.progress(format!("artifact directory: {}", out.display()));
    printer.blank();

    let output = zkb.run_streaming(&args, true)?;
    if !output.succeeded() {
        return Err(Error::Forwarded(output.code));
    }

    let reported_sha = output.last_marker("sha256: ");
    if options.no_download {
        printer.blank();
        printer.line("The build succeeded; no IPA was downloaded (--no-download).");
        if let Some(sha) = &reported_sha {
            printer.line(format!("sha256: {sha}"));
        }
        printer.line(format!(
            "Download it later with: zkb download --host {host} <job-id> --out {}",
            out.display()
        ));
        return Ok(crate::error::EXIT_SUCCESS);
    }

    let reported_ipa = output
        .last_marker("ipa: ")
        .map(PathBuf::from)
        .filter(|path| path.is_file());
    let ipa_path = match reported_ipa.or_else(|| find_newest_ipa(&out)) {
        Some(path) => path,
        None => {
            return Err(Error::local(format!(
                "the build succeeded but no IPA was found in {}; run \
                 `zkb download --host {host} <job-id> --out {}`",
                out.display(),
                out.display()
            )))
        }
    };
    let info = install::inspect_ipa(&ipa_path)?;
    let manifest = read_manifest_sha(&out);
    if let Some(expected) = &manifest {
        if !expected.eq_ignore_ascii_case(&info.sha256) {
            return Err(Error::local(format!(
                "the downloaded IPA does not match the build manifest: manifest SHA256 {expected}, \
                 local file SHA256 {}. The download is corrupt; delete it and rerun \
                 `zkb download`.",
                info.sha256
            )));
        }
    } else if let Some(expected) = &reported_sha {
        if !expected.eq_ignore_ascii_case(&info.sha256) {
            return Err(Error::local(format!(
                "the downloaded IPA does not match the SHA256 reported by the build: reported \
                 {expected}, local file {}. The download is corrupt.",
                info.sha256
            )));
        }
    }

    let report = BuildReport {
        host,
        game_name: name,
        display_name,
        ipa: info.path.clone(),
        ipa_bytes: info.bytes,
        sha256: info.sha256.clone(),
        manifest: Some(out.join("manifest.txt").display().to_string()),
        title_id: output.last_marker("title_id: "),
        source_revision: output.last_marker("source_revision: "),
    };
    print_report(&report, &info, manifest.is_some(), printer);
    Ok(crate::error::EXIT_SUCCESS)
}

/// Print the verified result; in JSON mode it goes to stderr so stdout stays
/// the shared client's NDJSON stream.
pub fn print_report(
    report: &BuildReport,
    info: &IpaInfo,
    manifest_verified: bool,
    printer: Printer,
) {
    if printer.json {
        match serde_json::to_string(report) {
            Ok(text) => printer.diagnostic(&text),
            Err(error) => {
                printer.diagnostic(format!("could not serialise the build report: {error}"))
            }
        }
        return;
    }
    printer.line("Build succeeded");
    printer.line(format!(
        "  game:     {} ({})",
        report.display_name, report.game_name
    ));
    printer.line(format!("  ipa:      {}", report.ipa));
    printer.line(format!("  size:     {}", format_bytes(info.bytes)));
    printer.line(format!("  sha256:   {}", report.sha256));
    if let Some(manifest) = &report.manifest {
        printer.line(format!("  manifest: {manifest}"));
    }
    if let Some(title_id) = &report.title_id {
        printer.line(format!("  title_id: {title_id}"));
    }
    if let Some(revision) = &report.source_revision {
        printer.line(format!("  source:   {revision}"));
    }
    if manifest_verified {
        printer.line("  verified: local SHA256 matches the Agent's manifest");
    } else {
        printer
            .line("  verified: local SHA256 matches the build's reported hash (no manifest copy)");
    }
    printer.blank();
    printer.line("This IPA is unsigned and contains code derived from your game.");
    printer.line("Sign and install it yourself on Windows or macOS (Sideloadly/AltStore);");
    printer.line("never redistribute it or upload it to a public service.");
    printer.line(format!(
        "Full guide: 3ds2apple-builder install-guide --ipa '{}'",
        report.ipa
    ));
    if report.source_revision.is_none() {
        if let Some(root) = paths::project_root(Path::new(".")) {
            if let Some((revision, _dirty)) = paths::git_revision(&root) {
                printer.blank();
                printer.line(format!(
                    "Tip: pin the Mac checkout with --expected-revision {revision} for \
                     reproducible builds."
                ));
            }
        }
    }
}

/// Resolve the host to build on: explicit, or the only configured profile.
pub fn resolve_host(
    config_path: &Path,
    requested: Option<&str>,
    printer: Printer,
) -> Result<String, Error> {
    let config = BuilderConfig::load(config_path).map_err(|message| {
        Error::usage(format!(
            "cannot read the Builder config {}: {message}",
            config_path.display()
        ))
    })?;
    if let Some(requested) = requested {
        return match config.find(requested) {
            Some(profile) => Ok(profile.id.clone()),
            None => Err(Error::usage(format!(
                "unknown host {requested:?}; configured hosts: {}",
                host_list(&config)
            ))),
        };
    }
    match config.hosts.as_slice() {
        [] => Err(Error::usage(
            "no build host is configured yet; pair your macOS VM first with \
             `3ds2apple-builder vm setup --name cachyos-vm`",
        )),
        [profile] => {
            printer.progress(format!(
                "using the only configured host: {} ({})",
                profile.name,
                profile.transport.describe()
            ));
            Ok(profile.id.clone())
        }
        _ => Err(Error::usage(format!(
            "several hosts are configured ({}); pass --host <name>",
            host_list(&config)
        ))),
    }
}

fn host_list(config: &BuilderConfig) -> String {
    if config.hosts.is_empty() {
        return "none".to_string();
    }
    config
        .hosts
        .iter()
        .map(|host| format!("{} ({})", host.id, host.name))
        .collect::<Vec<_>>()
        .join(", ")
}

/// A ROM the user chose, with its size for the privacy/summary lines.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RomChoice {
    pub path: PathBuf,
    pub bytes: u64,
}

/// Resolve `--rom`, or offer the ROMs found in the usual local directories.
pub fn resolve_rom<F>(
    options: &BuildOptions,
    env_get: &F,
    printer: Printer,
    interactive: bool,
) -> Result<RomChoice, Error>
where
    F: Fn(&str) -> Option<String>,
{
    if let Some(path) = &options.rom {
        return validate_rom_path(path, options.allow_any_file);
    }
    let cwd = std::env::current_dir().ok();
    let home = env_get("HOME")
        .or_else(|| env_get("USERPROFILE"))
        .map(PathBuf::from);
    let env_rom_dir = env_get(paths::ENV_ROM_DIR).map(PathBuf::from);
    let candidates = candidate_roms(
        &options.rom_dirs,
        cwd.as_deref(),
        home.as_deref(),
        env_rom_dir.as_deref(),
    );
    if candidates.is_empty() {
        return Err(Error::usage(format!(
            "no .3ds/.cci file found in the usual directories; pass --rom <path> \
             (searched: {})",
            search_dirs_summary(
                &options.rom_dirs,
                cwd.as_deref(),
                home.as_deref(),
                env_rom_dir.as_deref()
            )
        )));
    }
    if !interactive {
        let list = candidates
            .iter()
            .map(|candidate| candidate.path.display().to_string())
            .collect::<Vec<_>>()
            .join(", ");
        return Err(Error::usage(format!(
            "--rom is required when not running interactively; found: {list}"
        )));
    }
    if candidates.len() == 1 {
        let only = candidates[0].clone();
        printer.progress(format!("using the only ROM found: {}", only.path.display()));
        return choice_from_candidate(&only);
    }
    let mut stdin = std::io::stdin().lock();
    choose_rom(&candidates, &mut stdin)
}

/// List the ROM files the interactive picker would offer.
pub fn candidate_roms(
    rom_dirs: &[PathBuf],
    cwd: Option<&Path>,
    home: Option<&Path>,
    env_rom_dir: Option<&Path>,
) -> Vec<RomCandidate> {
    let dirs = paths::rom_search_dirs(rom_dirs, cwd, home, env_rom_dir);
    paths::list_roms(&dirs)
}

fn search_dirs_summary(
    rom_dirs: &[PathBuf],
    cwd: Option<&Path>,
    home: Option<&Path>,
    env_rom_dir: Option<&Path>,
) -> String {
    paths::rom_search_dirs(rom_dirs, cwd, home, env_rom_dir)
        .iter()
        .map(|dir| dir.display().to_string())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Interactive numbered picker for multiple ROM files.
pub fn choose_rom<R: BufRead>(
    candidates: &[RomCandidate],
    reader: &mut R,
) -> Result<RomChoice, Error> {
    if candidates.is_empty() {
        return Err(Error::usage("no ROM file to choose from"));
    }
    eprintln!("Found several ROM files:");
    for (index, candidate) in candidates.iter().enumerate() {
        eprintln!(
            "  {}. {} ({})",
            index + 1,
            candidate.path.display(),
            format_bytes(candidate.bytes)
        );
    }
    eprint!("Choose a ROM [1-{}] or enter a path: ", candidates.len());
    let mut line = String::new();
    if reader.read_line(&mut line).unwrap_or(0) == 0 {
        return Err(Error::usage("no answer on stdin; pass --rom <path>"));
    }
    let answer = line.trim();
    if answer.is_empty() {
        return Err(Error::usage("no ROM chosen; pass --rom <path>"));
    }
    if let Ok(index) = answer.parse::<usize>() {
        if (1..=candidates.len()).contains(&index) {
            return choice_from_candidate(&candidates[index - 1]);
        }
        return Err(Error::usage(format!(
            "{index} is not in 1-{}",
            candidates.len()
        )));
    }
    validate_rom_path(Path::new(answer), true)
}

fn choice_from_candidate(candidate: &RomCandidate) -> Result<RomChoice, Error> {
    Ok(RomChoice {
        path: candidate.path.clone(),
        bytes: candidate.bytes,
    })
}

/// Validate a ROM path: exists, is a file, and (unless overridden) has a
/// `.3ds`/`.cci` extension.
pub fn validate_rom_path(path: &Path, allow_any_file: bool) -> Result<RomChoice, Error> {
    if !path.is_file() {
        return Err(Error::usage(format!(
            "ROM file {} does not exist",
            path.display()
        )));
    }
    if !paths::has_rom_extension(path, allow_any_file) {
        return Err(Error::usage(format!(
            "{} does not look like a .3ds/.cci ROM (pass --allow-any-file to try anyway)",
            path.display()
        )));
    }
    let canonical = path
        .canonicalize()
        .map_err(|error| Error::local(format!("cannot resolve {}: {error}", path.display())))?;
    let bytes = std::fs::metadata(&canonical)
        .map_err(|error| Error::local(format!("cannot read {}: {error}", canonical.display())))?
        .len();
    Ok(RomChoice {
        path: canonical,
        bytes,
    })
}

/// Build name: explicit value or a slug from the ROM file name.
pub fn resolve_game_name(options: &BuildOptions, rom: &Path) -> Result<String, Error> {
    if let Some(name) = &options.name {
        builder_core::protocol::validate_game_name(name).map_err(Error::usage)?;
        return Ok(name.clone());
    }
    let stem = rom
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("game");
    Ok(builder_core::protocol::slugify_game_name(stem))
}

/// Home-screen display name: explicit value or the ROM file stem.
pub fn resolve_display_name(options: &BuildOptions, rom: &Path) -> String {
    if let Some(name) = &options.display_name {
        return name.clone();
    }
    let stem = rom
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("Game");
    let trimmed: String = stem
        .chars()
        .filter(|ch| !ch.is_control() && *ch != '/' && *ch != '\\')
        .collect();
    let trimmed = trimmed.trim();
    if trimmed.is_empty() {
        "Game".to_string()
    } else {
        trimmed.chars().take(48).collect()
    }
}

/// Assemble the shared-client argument vector (no shell string).
pub fn build_zkb_args(
    options: &BuildOptions,
    host: &str,
    rom: &Path,
    name: &str,
    out: &Path,
    config_path: Option<&Path>,
    json: bool,
) -> Vec<String> {
    let mut args = vec![
        "build".to_string(),
        "--host".to_string(),
        host.to_string(),
        "--rom".to_string(),
        rom.display().to_string(),
        "--name".to_string(),
        name.to_string(),
        "--out".to_string(),
        out.display().to_string(),
    ];
    if let Some(display_name) = &options.display_name {
        args.push("--display-name".to_string());
        args.push(display_name.clone());
    }
    if let Some(bundle_id) = &options.bundle_id {
        args.push("--bundle-id".to_string());
        args.push(bundle_id.clone());
    }
    if let Some(title_id) = &options.title_id {
        args.push("--title-id".to_string());
        args.push(title_id.clone());
    }
    if let Some(revision) = &options.expected_revision {
        args.push("--expected-revision".to_string());
        args.push(revision.clone());
    }
    for (flag, set) in [
        ("--no-moltenvk", options.no_moltenvk),
        ("--hardware-renderer", options.hardware_renderer),
        ("--clean", options.clean),
        ("--keep-input", options.keep_input),
        ("--no-download", options.no_download),
        ("--allow-any-file", options.allow_any_file),
    ] {
        if set {
            args.push(flag.to_string());
        }
    }
    zkb::with_globals(config_path, json, args)
}

/// Newest `.ipa` file directly inside `out`.
pub fn find_newest_ipa(out: &Path) -> Option<PathBuf> {
    let mut best: Option<(std::time::SystemTime, PathBuf)> = None;
    for entry in std::fs::read_dir(out).ok()?.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        if path
            .extension()
            .and_then(|extension| extension.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref()
            != Some("ipa")
        {
            continue;
        }
        let modified = entry
            .metadata()
            .and_then(|metadata| metadata.modified())
            .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
        if best
            .as_ref()
            .map(|(best, _)| modified > *best)
            .unwrap_or(true)
        {
            best = Some((modified, path));
        }
    }
    best.map(|(_, path)| path)
}

/// `ipa_sha256=` from the Agent's `manifest.txt`, when the CLI saved a copy.
pub fn read_manifest_sha(out: &Path) -> Option<String> {
    let text = std::fs::read_to_string(out.join("manifest.txt")).ok()?;
    text.lines().find_map(|line| {
        line.strip_prefix("ipa_sha256=")
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    })
}

/// Whether stdin is a terminal (prompting is only allowed then).
pub fn stdin_is_terminal() -> bool {
    std::io::stdin().is_terminal()
}

#[cfg(test)]
mod tests {
    use super::*;
    use builder_core::config::HostProfile;
    use builder_core::transport::{LocalSpec, TransportSpec};
    use std::collections::BTreeMap;
    use std::io::Cursor;

    fn write_config(path: &Path, hosts: Vec<HostProfile>) {
        let config = BuilderConfig {
            version: builder_core::config::CONFIG_VERSION,
            hosts,
        };
        config.save(path).unwrap();
    }

    fn local_host(id: &str) -> HostProfile {
        HostProfile {
            id: id.to_string(),
            name: format!("{id} name"),
            transport: TransportSpec::Local(LocalSpec {
                program: PathBuf::from("/bin/true"),
                args: Vec::new(),
                env: BTreeMap::new(),
            }),
            created_at: "2026-01-01T00:00:00Z".to_string(),
            last_test_at: None,
            agent_version: None,
            agent_id: None,
        }
    }

    fn quiet() -> Printer {
        // JSON mode keeps test output clean: human lines are suppressed.
        Printer::new(true)
    }

    #[test]
    fn resolves_explicit_and_implicit_hosts() {
        let dir = tempfile::tempdir().unwrap();
        let config = dir.path().join("config.toml");
        assert!(resolve_host(&config, None, quiet()).is_err());

        write_config(&config, vec![local_host("vm")]);
        assert_eq!(resolve_host(&config, None, quiet()).unwrap(), "vm");
        assert_eq!(resolve_host(&config, Some("vm"), quiet()).unwrap(), "vm");
        assert_eq!(
            resolve_host(&config, Some("vm name"), quiet()).unwrap(),
            "vm"
        );
        let error = resolve_host(&config, Some("other"), quiet()).unwrap_err();
        assert!(error.to_string().contains("configured hosts: vm"));

        write_config(&config, vec![local_host("vm"), local_host("lan")]);
        let error = resolve_host(&config, None, quiet()).unwrap_err();
        assert!(error.to_string().contains("--host"));
    }

    fn rom(path: &str) -> RomCandidate {
        RomCandidate {
            path: PathBuf::from(path),
            bytes: 1024,
        }
    }

    #[test]
    fn validates_rom_paths_and_extensions() {
        let dir = tempfile::tempdir().unwrap();
        let rom_path = dir.path().join("Pokemon Y.cci");
        std::fs::write(&rom_path, b"payload").unwrap();
        let choice = validate_rom_path(&rom_path, false).unwrap();
        assert_eq!(choice.bytes, 7);

        let text = dir.path().join("notes.txt");
        std::fs::write(&text, b"payload").unwrap();
        assert!(validate_rom_path(&text, false).is_err());
        assert!(validate_rom_path(&text, true).is_ok());
        assert!(validate_rom_path(&dir.path().join("missing.cci"), false).is_err());
    }

    #[test]
    fn interactive_picker_accepts_numbers_and_paths() {
        let candidates = vec![rom("/tmp/a.cci"), rom("/tmp/b.3ds")];
        let mut input = Cursor::new("2\n");
        let choice = choose_rom(&candidates, &mut input).unwrap();
        assert_eq!(choice.path, PathBuf::from("/tmp/b.3ds"));

        let mut input = Cursor::new("9\n");
        assert!(choose_rom(&candidates, &mut input).is_err());

        let mut input = Cursor::new("\n");
        assert!(choose_rom(&candidates, &mut input).is_err());
    }

    #[test]
    fn candidate_roms_come_from_the_documented_directories() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path().join("work");
        let rom_dir = cwd.join("ROM");
        std::fs::create_dir_all(&rom_dir).unwrap();
        std::fs::write(rom_dir.join("game.cci"), b"payload").unwrap();
        let candidates = candidate_roms(&[], Some(&cwd), None, None);
        assert_eq!(candidates.len(), 1);
        assert!(candidates[0].path.ends_with("game.cci"));
    }

    #[test]
    fn resolves_names_from_the_rom_file_name() {
        let options = BuildOptions::default();
        let path = Path::new("/roms/Pokemon Y (USA).cci");
        assert_eq!(resolve_game_name(&options, path).unwrap(), "pokemon-y-usa");
        assert_eq!(resolve_display_name(&options, path), "Pokemon Y (USA)");

        let explicit = BuildOptions {
            name: Some("pokemon-y".to_string()),
            display_name: Some("Pokémon Y".to_string()),
            ..BuildOptions::default()
        };
        assert_eq!(resolve_game_name(&explicit, path).unwrap(), "pokemon-y");
        assert_eq!(resolve_display_name(&explicit, path), "Pokémon Y");

        let bad = BuildOptions {
            name: Some("-bad name".to_string()),
            ..BuildOptions::default()
        };
        assert!(resolve_game_name(&bad, path).is_err());
    }

    #[test]
    fn zkb_arguments_are_ordered_and_shell_free() {
        let options = BuildOptions {
            display_name: Some("Pokemon Y".to_string()),
            clean: true,
            no_moltenvk: true,
            expected_revision: Some("4cc6186".to_string()),
            ..BuildOptions::default()
        };
        let args = build_zkb_args(
            &options,
            "vm",
            Path::new("/roms/game.cci"),
            "game",
            Path::new("/out/game"),
            Some(Path::new("/home/u/.config/3ds2apple/builder/config.toml")),
            false,
        );
        assert_eq!(args[0], "--config");
        assert_eq!(args[2], "build");
        assert!(args.contains(&"--host".to_string()));
        assert!(args.contains(&"vm".to_string()));
        assert!(args.contains(&"--display-name".to_string()));
        assert!(args.contains(&"--clean".to_string()));
        assert!(args.contains(&"--no-moltenvk".to_string()));
        assert!(args.contains(&"--expected-revision".to_string()));
        assert!(args.contains(&"Pokemon Y".to_string()));
        // No flag value is glued to its flag with '=' (each is its own argument).
        assert!(
            !args
                .iter()
                .any(|arg| arg.starts_with("--") && arg.contains('=')),
            "{args:?}"
        );
    }

    #[test]
    fn finds_the_newest_ipa_and_reads_the_manifest_hash() {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("out");
        std::fs::create_dir_all(&out).unwrap();
        std::fs::write(out.join("old.ipa"), b"old").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::write(out.join("new.ipa"), b"new").unwrap();
        std::fs::write(out.join("manifest.txt"), "ipa_sha256=abc123\n").unwrap();
        let newest = find_newest_ipa(&out).unwrap();
        assert!(newest.ends_with("new.ipa"), "{}", newest.display());
        assert_eq!(read_manifest_sha(&out), Some("abc123".to_string()));
        assert_eq!(read_manifest_sha(dir.path()), None);
    }

    #[test]
    fn newest_ipa_search_ignores_missing_directories() {
        assert_eq!(find_newest_ipa(Path::new("/does/not/exist")), None);
    }
}
