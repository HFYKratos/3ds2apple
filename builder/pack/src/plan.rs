//! Build-script command plan and slugs.
//!
//! The real AOT compile/link happens on macOS in `scripts/` (delegated to the
//! user's Mac or Build Agent). This module turns one queue entry into the exact
//! command sequence, so the desktop CLI can either print it (Linux/Windows) or
//! execute it (macOS) without re-implementing the pipeline.

use std::path::Path;

use crate::error::{PackError, Result};
use crate::queue::QueueEntry;

/// One external build step.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuildStep {
    /// Human label for progress output.
    pub label: String,
    /// Script path relative to the repository root.
    pub program: String,
    /// Arguments passed as an array (never a shell string).
    pub args: Vec<String>,
    /// Extra environment variables for this step (AOT codegen options).
    pub env: Vec<(String, String)>,
}

/// AOT codegen options from the launcher's advanced build settings.
/// Defaults reproduce the 0.2.1 behaviour: -O2, no LTO, no fast-math.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodegenOptions {
    /// One of O1/O2/O3/Oz.
    pub opt_level: String,
    /// Add -flto to the compile and the link.
    pub lto: bool,
    /// Add -ffast-math (changes guest float results; measurement only).
    pub fast_math: bool,
}

impl Default for CodegenOptions {
    fn default() -> Self {
        Self {
            opt_level: "O2".to_string(),
            lto: false,
            fast_math: false,
        }
    }
}

impl CodegenOptions {
    /// Validate the optimization level and normalise the string.
    pub fn validate(&self) -> Result<()> {
        match self.opt_level.as_str() {
            "O1" | "O2" | "O3" | "Oz" => Ok(()),
            other => Err(PackError::invalid(format!(
                "--opt-level must be O1, O2, O3 or Oz (got {other:?})"
            ))),
        }
    }

    /// Environment variable assignments passed to the build scripts (the AOT
    /// scripts read THREEDS2APPLE_AOT_OPT/LTO/FAST_MATH, see scripts/README.md).
    pub fn env_assignments(&self) -> Vec<(String, String)> {
        vec![
            ("THREEDS2APPLE_AOT_OPT".to_string(), self.opt_level.clone()),
            (
                "THREEDS2APPLE_AOT_LTO".to_string(),
                if self.lto { "1" } else { "0" }.to_string(),
            ),
            (
                "THREEDS2APPLE_AOT_FAST_MATH".to_string(),
                if self.fast_math { "1" } else { "0" }.to_string(),
            ),
        ]
    }

    /// Canonical short marker used in launcher build-cache keys.
    pub fn cache_marker(&self) -> String {
        format!(
            "opt={};lto={};fastmath={}",
            self.opt_level,
            if self.lto { 1 } else { 0 },
            if self.fast_math { 1 } else { 0 }
        )
    }
}

impl BuildStep {
    /// Render the step as a copy-pasteable shell line (environment + arguments).
    pub fn render(&self) -> String {
        let mut line = String::new();
        for (key, value) in &self.env {
            line.push_str(key);
            line.push('=');
            line.push_str(&shell_quote(value));
            line.push(' ');
        }
        line.push_str(&shell_quote(&self.program));
        for arg in &self.args {
            line.push(' ');
            line.push_str(&shell_quote(arg));
        }
        line
    }
}

/// Quote one argument for a POSIX shell.
pub fn shell_quote(value: &str) -> String {
    if !value.is_empty()
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_./:+@%,".contains(c))
    {
        return value.to_string();
    }
    let escaped = value.replace('\'', "'\\''");
    format!("'{escaped}'")
}

/// Build slug: ASCII lower-case words from the display name plus the last 8
/// title-ID digits, e.g. `pokemon-y-00055e00`. Matches the existing scripts'
/// name rule `[A-Za-z0-9._-]` and is unique per title ID.
pub fn slug_for(display_name: &str, title_id: &str) -> String {
    let mut slug = String::new();
    let mut last_dash = true;
    for character in display_name.chars() {
        let folded: Option<&str> = if character.is_ascii_alphanumeric() {
            None
        } else {
            fold_latin(character)
        };
        match (character.is_ascii_alphanumeric(), folded) {
            (true, _) => {
                if slug.len() < 40 {
                    slug.push(character.to_ascii_lowercase());
                    last_dash = false;
                }
            }
            (false, Some(replacement)) => {
                for folded_char in replacement.chars() {
                    if slug.len() < 40 {
                        slug.push(folded_char);
                        last_dash = false;
                    }
                }
            }
            (false, None) if character.is_alphabetic() => {
                // Unsupported scripts have no ASCII equivalent: drop the
                // character instead of producing a run of dashes.
            }
            (false, None) => {
                if !last_dash && slug.len() < 40 {
                    slug.push('-');
                    last_dash = true;
                }
            }
        }
    }
    while slug.ends_with('-') {
        slug.pop();
    }
    let suffix: String = title_id
        .chars()
        .rev()
        .take(8)
        .collect::<String>()
        .chars()
        .rev()
        .collect();
    if slug.is_empty() {
        format!("game-{}", suffix.to_ascii_lowercase())
    } else {
        format!("{slug}-{}", suffix.to_ascii_lowercase())
    }
}

/// Fold one common accented Latin character to its ASCII form (best effort;
/// names in other scripts fall back to the title-ID-only slug).
fn fold_latin(character: char) -> Option<&'static str> {
    let lower = character.to_lowercase().next().unwrap_or(character);
    Some(match lower {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' => "a",
        'ç' | 'ć' | 'ĉ' | 'ċ' | 'č' => "c",
        'ď' | 'đ' => "d",
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ĕ' | 'ė' | 'ę' | 'ě' => "e",
        'ğ' | 'ģ' => "g",
        'ì' | 'í' | 'î' | 'ï' | 'ī' | 'į' | 'ı' => "i",
        'ķ' => "k",
        'ĺ' | 'ļ' | 'ľ' => "l",
        'ñ' | 'ń' | 'ņ' | 'ň' => "n",
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' | 'ŏ' | 'ő' => "o",
        'ŕ' | 'ř' => "r",
        'ś' | 'ŝ' | 'ş' | 'š' => "s",
        'ť' | 'ţ' => "t",
        'ù' | 'ú' | 'û' | 'ü' | 'ū' | 'ŭ' | 'ů' | 'ű' | 'ų' => "u",
        'ý' | 'ÿ' => "y",
        'ź' | 'ż' | 'ž' => "z",
        'æ' => "ae",
        'œ' => "oe",
        'ß' => "ss",
        'þ' => "th",
        'ð' => "d",
        _ => return None,
    })
}

/// Whether a value satisfies the existing build scripts' name rule.
pub fn is_valid_slug(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 96
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// The three macOS steps for one game: recomp, linked runtime, game pack.
pub fn steps(entry: &QueueEntry, out_root: &Path, options: &CodegenOptions) -> Vec<BuildStep> {
    let rom = entry.rom_path.clone();
    let slug = entry.slug.clone();
    let title = entry.title_id.clone();
    let display = entry.display_name.clone();
    let product = entry.product_code.clone();
    let out_dir = out_root.display().to_string();
    let mut pack_args = vec![
        slug.clone(),
        "--title-id".to_string(),
        title.clone(),
        "--display-name".to_string(),
        display,
        "--out".to_string(),
        out_dir,
    ];
    if !product.is_empty() {
        pack_args.push("--product-code".to_string());
        pack_args.push(product);
    }
    if !rom.is_empty() {
        pack_args.push("--rom".to_string());
        pack_args.push(rom.clone());
    }
    let env = options.env_assignments();
    vec![
        BuildStep {
            label: "recompiling (3dsrecomp -> generated C -> libgame.a)".to_string(),
            program: "scripts/build-recomp-ios.sh".to_string(),
            args: vec![rom, slug.clone(), "--auto-serial".to_string()],
            env: env.clone(),
        },
        BuildStep {
            label: "linking (linked libzakuro_ios.a + libgame.a)".to_string(),
            program: "scripts/build-linked-ios-lib.sh".to_string(),
            args: vec![slug.clone(), "--title-id".to_string(), title],
            env: env.clone(),
        },
        BuildStep {
            label: "packaging (GamePack.dylib -> out/packages/<titleID>)".to_string(),
            program: "scripts/build-game-pack.sh".to_string(),
            args: pack_args,
            env,
        },
    ]
}

/// Human-readable plan block for one or more entries.
pub fn render_plan(entries: &[QueueEntry], out_root: &Path, options: &CodegenOptions) -> String {
    let mut text = String::new();
    for (index, entry) in entries.iter().enumerate() {
        text.push_str(&format!(
            "# {}. {} ({}) -> {}\n",
            index + 1,
            entry.display_name,
            entry.title_id,
            entry.slug
        ));
        for step in steps(entry, out_root, options) {
            text.push_str(&step.render());
            text.push('\n');
        }
        text.push('\n');
    }
    text
}

/// Render a full command line (program + arguments) for display/copy-paste.
pub fn shell_quote_join(command: &[String]) -> String {
    command
        .iter()
        .map(|part| shell_quote(part))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Execute the plan on this machine (macOS only; the CLI enforces that).
pub fn execute(
    entries: &[QueueEntry],
    out_root: &Path,
    repo_root: &Path,
    options: &CodegenOptions,
) -> Result<()> {
    if !cfg!(target_os = "macos") {
        return Err(PackError::invalid(
            "the real AOT build must run on macOS with Xcode or on Windows with the launcher's bundled LLVM toolchain; run it on the matching host (use --fake on Linux/Windows for a preview package)",
        ));
    }
    for entry in entries {
        for step in steps(entry, out_root, options) {
            eprintln!("== {} ({})", step.label, entry.title_id);
            let status = std::process::Command::new(&step.program)
                .args(&step.args)
                .envs(step.env.iter().map(|(key, value)| (key, value)))
                .current_dir(repo_root)
                .status()
                .map_err(|error| PackError::io(repo_root.join(&step.program), error))?;
            if !status.success() {
                return Err(PackError::invalid(format!(
                    "{} failed for {} with {}",
                    step.program, entry.title_id, status
                )));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry() -> QueueEntry {
        QueueEntry {
            title_id: "0004000000055E00".to_string(),
            rom_path: "/roms/Pokemon Y.cci".to_string(),
            display_name: "Pokémon Y".to_string(),
            product_code: "CTR-P-EK2A".to_string(),
            slug: slug_for("Pokémon Y", "0004000000055E00"),
            aot_version: 1,
            state: crate::queue::QueueState::Queued,
            error: None,
        }
    }

    #[test]
    fn slugs_are_ascii_unique_and_valid() {
        assert_eq!(
            slug_for("Pokémon Y", "0004000000055E00"),
            "pokemon-y-00055e00"
        );
        assert_eq!(
            slug_for("Pokémon Alpha Sapphire", "000400000011C500"),
            "pokemon-alpha-sapphire-0011c500"
        );
        assert_eq!(slug_for("  ", "0004000000055E00"), "game-00055e00");
        assert!(slug_for(&"A".repeat(200), "0004000000055E00").len() <= 96);
        for name in ["Pokémon Y", "A/B", "  ", &"x".repeat(200)] {
            assert!(is_valid_slug(&slug_for(name, "0004000000055E00")));
        }
    }

    #[test]
    fn plan_commands_match_the_script_contract() {
        let entry = entry();
        let options = CodegenOptions::default();
        let steps = steps(&entry, Path::new("out"), &options);
        assert_eq!(steps.len(), 3);
        assert_eq!(steps[0].program, "scripts/build-recomp-ios.sh");
        assert_eq!(
            steps[0].args,
            vec![
                "/roms/Pokemon Y.cci".to_string(),
                "pokemon-y-00055e00".to_string(),
                "--auto-serial".to_string()
            ]
        );
        assert_eq!(steps[1].program, "scripts/build-linked-ios-lib.sh");
        assert_eq!(
            steps[1].args,
            vec![
                "pokemon-y-00055e00".to_string(),
                "--title-id".to_string(),
                "0004000000055E00".to_string()
            ]
        );
        assert_eq!(steps[2].program, "scripts/build-game-pack.sh");
        assert!(steps[2].args.contains(&"--out".to_string()));
        assert!(steps[2].args.contains(&"out".to_string()));
        assert!(steps[2].args.contains(&"--title-id".to_string()));
        let rendered = steps[0].render();
        assert!(rendered.contains("scripts/build-recomp-ios.sh"));
        assert!(rendered.contains("Pokemon Y.cci"));
        assert!(render_plan(&[entry], Path::new("out"), &options).contains("# 1."));
    }

    #[test]
    fn shell_quoting_is_safe() {
        assert_eq!(shell_quote("plain-name_1.rs"), "plain-name_1.rs");
        assert_eq!(shell_quote("two words"), "'two words'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
        assert_eq!(shell_quote(""), "''");
    }

    #[test]
    fn codegen_options_are_passed_to_every_aot_step() {
        let entry = entry();
        let default_options = CodegenOptions::default();
        default_options.validate().unwrap();
        assert_eq!(default_options.cache_marker(), "opt=O2;lto=0;fastmath=0");
        let default_steps = steps(&entry, Path::new("out"), &default_options);
        for step in &default_steps {
            assert!(step
                .env
                .iter()
                .any(|(key, value)| key == "THREEDS2APPLE_AOT_OPT" && value == "O2"));
            assert!(step
                .env
                .iter()
                .any(|(key, value)| key == "THREEDS2APPLE_AOT_LTO" && value == "0"));
            assert!(step
                .env
                .iter()
                .any(|(key, value)| key == "THREEDS2APPLE_AOT_FAST_MATH" && value == "0"));
        }
        let rendered = default_steps[0].render();
        assert!(rendered.starts_with("THREEDS2APPLE_AOT_OPT=O2 "), "{rendered}");
        assert!(rendered.contains("scripts/build-recomp-ios.sh"));

        let custom = CodegenOptions {
            opt_level: "O3".to_string(),
            lto: true,
            fast_math: true,
        };
        custom.validate().unwrap();
        assert_eq!(custom.cache_marker(), "opt=O3;lto=1;fastmath=1");
        let custom_steps = steps(&entry, Path::new("out"), &custom);
        let rendered = custom_steps[0].render();
        assert!(rendered.starts_with("THREEDS2APPLE_AOT_OPT=O3 "), "{rendered}");
        assert!(rendered.contains("THREEDS2APPLE_AOT_LTO=1 "), "{rendered}");
        assert!(rendered.contains("THREEDS2APPLE_AOT_FAST_MATH=1 "), "{rendered}");
        assert!(render_plan(&[entry], Path::new("out"), &custom).contains("THREEDS2APPLE_AOT_OPT=O3"));

        let mut invalid = CodegenOptions::default();
        invalid.opt_level = "O9".to_string();
        assert!(invalid.validate().is_err());
    }
}
