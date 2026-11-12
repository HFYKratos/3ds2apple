//! The contract with `scripts/`: stage command lines and the documented stdout
//! markers the Agent is allowed to parse.
//!
//! The Agent never builds a shell string. Each stage is `bash <script> <args>`
//! with an argument array, run in the configured checkout. It parses only:
//!
//! * the last non-empty stdout line of `build-game-ipa.sh` (the IPA path);
//! * log lines containing `SHA256:` and `manifest:`;
//! * the `key=value` build manifest (`build/ios/<name>/manifest.txt`).
//!
//! Anything else is streamed to the client as log lines only.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use builder_core::protocol::model::InputRole;

pub const SCRIPT_RUNTIME: &str = "scripts/build-zakuro-ios.sh";
pub const SCRIPT_RECOMP: &str = "scripts/build-recomp-ios.sh";
pub const SCRIPT_LINKED: &str = "scripts/build-linked-ios-lib.sh";
pub const SCRIPT_PACKAGE: &str = "scripts/build-game-ipa.sh";

/// One script invocation: the script path (relative to the checkout) and its
/// argument array.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScriptCall {
    pub script: PathBuf,
    pub args: Vec<String>,
}

impl ScriptCall {
    pub fn new(script: impl Into<PathBuf>, args: Vec<String>) -> Self {
        Self {
            script: script.into(),
            args,
        }
    }

    /// Build the command; callers set stdio and environment.
    pub fn command(&self, checkout: &Path) -> std::process::Command {
        let mut command = std::process::Command::new("bash");
        command
            .arg(checkout.join(&self.script))
            .args(&self.args)
            .current_dir(checkout);
        command
    }

    pub fn display(&self) -> String {
        let mut text = self.script.display().to_string();
        for arg in &self.args {
            text.push(' ');
            text.push_str(arg);
        }
        text
    }
}

/// Validate the client-controlled build arguments before they reach a script.
pub fn validate_build_arguments(
    name: &str,
    display_name: &str,
    bundle_id: Option<&str>,
    title_id: Option<&str>,
) -> Result<(), String> {
    builder_core::protocol::validate_game_name(name)?;
    builder_core::protocol::validate_display_name(display_name)?;
    if let Some(bundle_id) = bundle_id {
        builder_core::protocol::validate_bundle_id(bundle_id)?;
    }
    if let Some(title_id) = title_id {
        if !builder_core::protocol::valid_title_id(title_id) {
            return Err(format!(
                "title id must be 16 hex characters, got {title_id:?}"
            ));
        }
    }
    Ok(())
}

/// Stage 1: recompile the ROM (3dsrecomp → generated C → arm64 objects).
pub fn recomp_call(rom: &Path, name: &str) -> ScriptCall {
    ScriptCall::new(
        SCRIPT_RECOMP,
        vec![
            rom.display().to_string(),
            name.to_string(),
            "--auto-serial".to_string(),
        ],
    )
}

/// Stage 2: linked runtime for the title; collects `libzakuro_ios.a` and
/// `libgame.a` under `build/ios/<name>/`.
pub fn linked_call(name: &str, title_id: Option<&str>) -> ScriptCall {
    let mut args = vec![name.to_string()];
    if let Some(title_id) = title_id {
        args.push("--title-id".to_string());
        args.push(title_id.to_string());
    }
    args.push("--isolated-target".to_string());
    ScriptCall::new(SCRIPT_LINKED, args)
}

/// Stage 3: build the app and package the unsigned IPA into the job's `out/`.
pub fn package_call(
    name: &str,
    display_name: &str,
    bundle_id: Option<&str>,
    out_dir: &Path,
    ipa_name: &str,
) -> ScriptCall {
    let mut args = vec![name.to_string()];
    args.push("--display-name".to_string());
    args.push(display_name.to_string());
    if let Some(bundle_id) = bundle_id {
        args.push("--bundle-id".to_string());
        args.push(bundle_id.to_string());
    }
    args.push("--out-dir".to_string());
    args.push(out_dir.display().to_string());
    args.push("--ipa-name".to_string());
    args.push(ipa_name.to_string());
    args.push("--clean-project".to_string());
    ScriptCall::new(SCRIPT_PACKAGE, args)
}

/// IPA base name for a game (`<name>-AOT`).
pub fn ipa_name(name: &str) -> String {
    format!("{name}-AOT")
}

/// Markers parsed out of the packaging stage's combined output.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct PackageOutput {
    pub ipa_path: Option<PathBuf>,
    pub sha256: Option<String>,
    pub manifest_path: Option<PathBuf>,
}

impl PackageOutput {
    /// Resolve the IPA path: prefer the parsed marker, then the job output
    /// directory. Returns an error message when neither is usable.
    pub fn resolve_ipa(&self, out_dir: &Path, ipa_name: &str) -> Result<PathBuf, String> {
        if let Some(path) = &self.ipa_path {
            if path.is_file() {
                return Ok(path.clone());
            }
            return Err(format!(
                "build script printed {} but the file does not exist",
                path.display()
            ));
        }
        let fallback = out_dir.join(format!("{ipa_name}.ipa"));
        if fallback.is_file() {
            return Ok(fallback);
        }
        Err("build script did not report an IPA path and none was produced".to_string())
    }
}

/// Parse the documented markers from an interleaved stdout/stderr capture.
pub fn parse_package_output(lines: &[String]) -> PackageOutput {
    let mut output = PackageOutput::default();
    for line in lines {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if let Some(index) = trimmed.find("SHA256:") {
            let rest = trimmed[index + "SHA256:".len()..].trim();
            if let Some(token) = rest.split_whitespace().next() {
                if builder_core::protocol::is_hex(token, 64) {
                    output.sha256 = Some(token.to_ascii_lowercase());
                }
            }
        }
        if let Some(index) = trimmed.find("manifest:") {
            let rest = trimmed[index + "manifest:".len()..].trim();
            if let Some(token) = rest.split_whitespace().next() {
                output.manifest_path = Some(PathBuf::from(token));
            }
        }
        // The final plain line the script prints is the IPA path. Ignore lines
        // that look like log lines ("[build-game-ipa] ...").
        if !trimmed.starts_with('[') && trimmed.ends_with(".ipa") {
            output.ipa_path = Some(PathBuf::from(trimmed));
        }
    }
    output
}

/// Parsed build manifest (`build/ios/<name>/manifest.txt`).
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ManifestInfo {
    pub fields: BTreeMap<String, String>,
}

impl ManifestInfo {
    pub fn get(&self, key: &str) -> Option<&str> {
        self.fields.get(key).map(String::as_str)
    }

    pub fn ipa_sha256(&self) -> Option<&str> {
        self.get("ipa_sha256")
    }

    #[allow(dead_code)]
    pub fn title_id(&self) -> Option<&str> {
        self.get("title_id")
    }

    #[allow(dead_code)]
    pub fn ipa_bytes(&self) -> Option<u64> {
        self.get("ipa_bytes").and_then(|value| value.parse().ok())
    }
}

/// Parse `key=value` lines; unknown keys are kept, malformed lines ignored.
pub fn parse_manifest(text: &str) -> ManifestInfo {
    let mut fields = BTreeMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        fields.insert(key.trim().to_string(), value.trim().to_string());
    }
    ManifestInfo { fields }
}

/// Best-effort `(done, total)` from a progress line such as
/// `compiling generated code (318/761)`.
#[allow(dead_code)]
pub fn parse_file_progress(line: &str) -> Option<(u64, u64)> {
    let open = line.rfind('(')?;
    let close = line[open..].find('/')? + open;
    let end = line[close..].find(')')? + close;
    let done = line[open + 1..close].trim().parse().ok()?;
    let total = line[close + 1..end].trim().parse().ok()?;
    if total == 0 || done > total {
        return None;
    }
    Some((done, total))
}

/// Map a failing build's last lines to an actionable hint (PROTOCOL.md §8.2).
pub fn symptom_hint(lines: &[String]) -> Option<String> {
    let tail = lines
        .iter()
        .rev()
        .take(60)
        .map(|line| line.to_lowercase())
        .collect::<Vec<_>>();
    let contains = |needle: &str| tail.iter().any(|line| line.contains(needle));
    if contains("missing librecomp.a") {
        return Some("The 3dsrecomp step did not finish; see the recompiling log.".to_string());
    }
    if contains("no space left on device") || contains("out of memory") || contains("oom") {
        return Some(
            "The Mac ran out of disk or memory. Clean the build tree and retry; the Agent already compiles serially."
                .to_string(),
        );
    }
    if contains("xcode-select") || contains("sdk not found") || contains("unable to find sdk") {
        return Some(
            "Xcode or the iOS SDK is missing; run `builder-agent doctor` on the Mac.".to_string(),
        );
    }
    if contains("undefined symbol") && contains("_recomp_") {
        return Some(
            "Undefined _recomp_* symbols: libgame.a is missing or linked before libzakuro_ios.a; the build script enforces the order, so check the log."
                .to_string(),
        );
    }
    if contains("moltenvk") && (contains("framework") || contains("not found")) {
        return Some(
            "MoltenVK is missing on the Mac; run the Agent's MoltenVK setup and check the pinned SHA256."
                .to_string(),
        );
    }
    if contains("aot: linked, interpreting") {
        return Some(
            "The app linked the interpreter instead of the AOT code (title id / interface mismatch); rebuild both sides."
                .to_string(),
        );
    }
    if contains("title id") && (contains("not") || contains("missing")) {
        return Some(
            "The title id could not be derived; pass it explicitly and retry.".to_string(),
        );
    }
    None
}

/// Input role paths used by the runner.
pub fn rom_input_path(job_dir: &Path) -> PathBuf {
    crate::store::input_path(job_dir, InputRole::Rom)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recomp_arguments_follow_the_documented_cli() {
        let call = recomp_call(Path::new("/tmp/job/input/rom"), "pokemon-y");
        assert_eq!(call.script, PathBuf::from(SCRIPT_RECOMP));
        assert_eq!(
            call.args,
            vec!["/tmp/job/input/rom", "pokemon-y", "--auto-serial"]
        );
    }

    #[test]
    fn linked_arguments_include_title_and_isolation() {
        let call = linked_call("pokemon-y", Some("0004000000055E00"));
        assert_eq!(
            call.args,
            vec![
                "pokemon-y",
                "--title-id",
                "0004000000055E00",
                "--isolated-target"
            ]
        );
        let call = linked_call("pokemon-y", None);
        assert_eq!(call.args, vec!["pokemon-y", "--isolated-target"]);
    }

    #[test]
    fn package_arguments_target_the_job_output_dir() {
        let call = package_call(
            "pokemon-y",
            "Pokemon Y",
            Some("com.kratos.3ds2apple.pokemon-y"),
            Path::new("/tmp/job/out"),
            "pokemon-y-AOT",
        );
        assert_eq!(call.script, PathBuf::from(SCRIPT_PACKAGE));
        assert_eq!(
            call.args,
            vec![
                "pokemon-y",
                "--display-name",
                "Pokemon Y",
                "--bundle-id",
                "com.kratos.3ds2apple.pokemon-y",
                "--out-dir",
                "/tmp/job/out",
                "--ipa-name",
                "pokemon-y-AOT",
                "--clean-project",
            ]
        );
    }

    #[test]
    fn command_is_bash_with_array_arguments() {
        let call = recomp_call(Path::new("/jobs/j1/input/rom"), "game");
        let command = call.command(Path::new("/Users/builder/src/3ds2apple"));
        assert_eq!(command.get_program(), "bash");
        let args: Vec<String> = command
            .get_args()
            .map(|arg| arg.to_string_lossy().to_string())
            .collect();
        assert_eq!(
            args[0],
            "/Users/builder/src/3ds2apple/scripts/build-recomp-ios.sh"
        );
        assert!(args.contains(&"/jobs/j1/input/rom".to_string()));
        // No shell string: every argument is a separate argv element.
        assert!(!args
            .iter()
            .any(|arg| arg.contains("&&") || arg.contains(';')));
    }

    #[test]
    fn build_arguments_are_validated() {
        assert!(validate_build_arguments("pokemon-y", "Pokemon Y", None, None).is_ok());
        assert!(validate_build_arguments("-bad", "Pokemon Y", None, None).is_err());
        assert!(validate_build_arguments("ok", "", None, None).is_err());
        assert!(validate_build_arguments("ok", "Pokemon Y", Some("nodots"), None).is_err());
        assert!(validate_build_arguments("ok", "Pokemon Y", None, Some("0004")).is_err());
    }

    #[test]
    fn parses_packaging_output_markers() {
        let lines: Vec<String> = vec![
            "[build-game-ipa] building app".into(),
            "[build-game-ipa] xcodebuild succeeded".into(),
            "[build-game-ipa]   IPA:      /tmp/job/out/pokemon-y-AOT.ipa (96.4 MB, 101000000 bytes)".into(),
            "[build-game-ipa]   SHA256:   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".into(),
            "[build-game-ipa]   manifest: /repo/build/ios/pokemon-y/manifest.txt".into(),
            "/tmp/job/out/pokemon-y-AOT.ipa".into(),
        ];
        let output = parse_package_output(&lines);
        assert_eq!(
            output.ipa_path,
            Some(PathBuf::from("/tmp/job/out/pokemon-y-AOT.ipa"))
        );
        assert_eq!(
            output.sha256.as_deref(),
            Some("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        );
        assert_eq!(
            output.manifest_path,
            Some(PathBuf::from("/repo/build/ios/pokemon-y/manifest.txt"))
        );
    }

    #[test]
    fn rejects_bad_hash_markers() {
        let lines = vec!["SHA256: not-a-hash".to_string(), "SHA256:   ".to_string()];
        assert_eq!(parse_package_output(&lines).sha256, None);
    }

    #[test]
    fn parses_manifest_fields() {
        let text = "\
name=pokemon-y
title_id=0004000000055E00
bundle_id=com.kratos.3ds2apple.pokemon-y
ipa_bytes=101000000
ipa_sha256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
xcode=Xcode 16.4
";
        let manifest = parse_manifest(text);
        assert_eq!(manifest.title_id(), Some("0004000000055E00"));
        assert_eq!(manifest.ipa_bytes(), Some(101_000_000));
        assert!(manifest.ipa_sha256().is_some());
        assert_eq!(manifest.get("unknown"), None);
    }

    #[test]
    fn parses_file_progress() {
        assert_eq!(
            parse_file_progress("[build-recomp-ios] compiling generated code (318/761)"),
            Some((318, 761))
        );
        assert_eq!(parse_file_progress("no progress here"), None);
        assert_eq!(parse_file_progress("(5/0)"), None);
        assert_eq!(parse_file_progress("(900/100)"), None);
    }

    #[test]
    fn symptom_hints_cover_documented_failures() {
        assert!(symptom_hint(&["xcodebuild: error: missing librecomp.a".into()]).is_some());
        assert!(symptom_hint(&["clang: error: no space left on device".into()]).is_some());
        assert!(
            symptom_hint(&["Undefined symbols for architecture arm64: _recomp_init".into()])
                .unwrap()
                .contains("libgame.a")
        );
        assert!(
            symptom_hint(&["xcode-select: error: tool 'xcodebuild' requires Xcode".into()])
                .is_some()
        );
        assert!(symptom_hint(&["all good".into()]).is_none());
    }

    #[test]
    fn ipa_resolution_falls_back_to_out_dir() {
        let dir = tempfile::tempdir().unwrap();
        let output = PackageOutput::default();
        assert!(output.resolve_ipa(dir.path(), "game-AOT").is_err());
        std::fs::write(dir.path().join("game-AOT.ipa"), b"x").unwrap();
        assert_eq!(
            output.resolve_ipa(dir.path(), "game-AOT").unwrap(),
            dir.path().join("game-AOT.ipa")
        );
    }
}
