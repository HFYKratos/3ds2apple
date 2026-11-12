//! The installation guide shown after a successful build.
//!
//! The Builder produces an unsigned IPA and never touches signing, provisioning
//! or devices. This module renders the Windows instructions the user actually
//! needs: verify the checksum, install with Sideloadly (or AltStore/SideStore),
//! trust the developer certificate, and understand the seven-day expiry of a
//! free Apple ID certificate. It never asks for an Apple ID inside the Builder.

use std::path::Path;

use crate::paths;
use crate::preflight::format_bytes;

/// Facts about the produced artifact shown in the guide.
#[derive(Debug, Clone)]
pub struct ArtifactGuide<'a> {
    pub display_name: &'a str,
    pub ipa_path: &'a Path,
    pub bytes: u64,
    pub sha256: &'a str,
    pub title_id: Option<&'a str>,
    pub source_revision: Option<&'a str>,
    pub xcode: Option<&'a str>,
    pub host_name: Option<&'a str>,
}

/// Render the Windows installation guide.
pub fn render_windows(guide: &ArtifactGuide<'_>) -> String {
    let mut out = String::new();
    out.push_str("3ds2apple unsigned IPA - install guide (Windows)\n");
    out.push_str("==================================================\n\n");
    out.push_str(&format!("Game:      {}\n", guide.display_name));
    out.push_str(&format!(
        "IPA file:  {}\n",
        paths::display_path(guide.ipa_path)
    ));
    out.push_str(&format!("Size:      {}\n", format_bytes(guide.bytes)));
    out.push_str(&format!("SHA256:    {}\n", guide.sha256));
    if let Some(title_id) = guide.title_id {
        out.push_str(&format!("Title ID:  {title_id}\n"));
    }
    if let Some(host) = guide.host_name {
        out.push_str(&format!("Built on:  {host}\n"));
    }
    let mut toolchain = Vec::new();
    if let Some(xcode) = guide.xcode {
        toolchain.push(format!("Xcode {xcode}"));
    }
    if let Some(revision) = guide.source_revision {
        toolchain.push(format!("source {revision}"));
    }
    if !toolchain.is_empty() {
        out.push_str(&format!("Toolchain: {}\n", toolchain.join(", ")));
    }
    out.push('\n');

    out.push_str("1. Verify the file (recommended)\n");
    out.push_str("   Open Command Prompt and run:\n");
    out.push_str(&format!(
        "     certutil -hashfile \"{}\" SHA256\n",
        paths::display_path(guide.ipa_path)
    ));
    out.push_str("   Or in PowerShell:\n");
    out.push_str(&format!(
        "     Get-FileHash -Algorithm SHA256 \"{}\"\n",
        paths::display_path(guide.ipa_path)
    ));
    out.push_str("   The printed hash must match the SHA256 above, character for character.\n\n");

    out.push_str("2. Install with Sideloadly\n");
    out.push_str("   a. Install Sideloadly from https://sideloadly.io/ (it may install\n");
    out.push_str("      Apple's device drivers the first time; follow its instructions).\n");
    out.push_str("   b. Connect the iPhone/iPad by USB and tap \"Trust\" on the device.\n");
    out.push_str("   c. Drag the .ipa into Sideloadly, or use its IPA picker, and select\n");
    out.push_str("      the connected device.\n");
    out.push_str("   d. Enter your own Apple ID inside Sideloadly and press Start.\n");
    out.push_str("      The Builder never asks for or stores your Apple ID, password,\n");
    out.push_str("      certificate or device UDID.\n");
    out.push_str("   e. On the device, trust the developer certificate:\n");
    out.push_str("      Settings > General > VPN & Device Management > Developer App > Trust.\n\n");

    out.push_str("3. Alternatives\n");
    out.push_str("   - AltStore: https://altstore.io/\n");
    out.push_str("   - SideStore: https://sidestore.io/\n");
    out.push_str("   - macOS signing machines can use Sideloadly or Xcode's Devices window.\n\n");

    out.push_str("Notes\n");
    out.push_str("   - This IPA is unsigned and contains code derived from your own game.\n");
    out.push_str("     Sign and install it yourself; do not redistribute it.\n");
    out.push_str("   - A free Apple ID certificate expires after 7 days and must be\n");
    out.push_str("     re-signed; a paid Apple developer account lasts about a year. That is\n");
    out.push_str("     Apple's limit, not the Builder's.\n");
    out.push_str("   - The game's ROM was uploaded only to your own build host and is\n");
    out.push_str("     deleted there when the build ends, unless you asked to keep it.\n");
    out
}

/// Short reminder printed after the guide: what the Builder itself will never do.
pub fn responsibility_note() -> &'static str {
    "The Builder does not sign, install or manage devices. Signing and installation are your \
     own steps with your own Apple ID."
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn guide<'a>(path: &'a Path, sha: &'a str) -> ArtifactGuide<'a> {
        ArtifactGuide {
            display_name: "Pokemon Y",
            ipa_path: path,
            bytes: 101_000_000,
            sha256: sha,
            title_id: Some("0004000000055E00"),
            source_revision: Some("4cc6186"),
            xcode: Some("16.4"),
            host_name: Some("Mac mini in the office"),
        }
    }

    #[test]
    fn guide_contains_the_facts_and_commands() {
        let path = PathBuf::from(r"C:\Users\me\3ds2apple\artifacts\pokemon-y-AOT.ipa");
        let sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
        let text = render_windows(&guide(&path, sha));
        assert!(text.contains("pokemon-y-AOT.ipa"));
        assert!(text.contains(sha));
        assert!(text.contains("0004000000055E00"));
        assert!(text.contains("4cc6186"));
        assert!(text.contains("96.3 MiB") || text.contains("MiB"), "{text}");
        assert!(text.contains("certutil -hashfile"));
        assert!(text.contains("Get-FileHash"));
        assert!(text.contains("https://sideloadly.io/"));
        assert!(text.contains("https://altstore.io/"));
        assert!(text.contains("Settings > General > VPN & Device Management"));
        assert!(text.contains("7 days"));
        assert!(text.contains("do not redistribute"));
    }

    #[test]
    fn guide_never_asks_for_credentials() {
        let path = PathBuf::from("/tmp/pokemon-y-AOT.ipa");
        let text = render_windows(&guide(&path, "ab"));
        let lower = text.to_ascii_lowercase();
        assert!(!lower.contains("enter your password"));
        assert!(!lower.contains("2fa"));
        assert!(!lower.contains("udid:"));
        assert!(lower.contains("never asks for or stores your apple id"));
    }

    #[test]
    fn guide_works_without_optional_facts() {
        let path = PathBuf::from("/tmp/game-AOT.ipa");
        let minimal = ArtifactGuide {
            display_name: "Game",
            ipa_path: &path,
            bytes: 1024,
            sha256: "00",
            title_id: None,
            source_revision: None,
            xcode: None,
            host_name: None,
        };
        let text = render_windows(&minimal);
        assert!(text.contains("1.0 KiB"));
        assert!(!text.contains("Title ID:"));
        assert!(!text.contains("Toolchain:"));
        assert!(responsibility_note().contains("does not sign"));
    }

    #[test]
    fn cjk_display_names_are_kept() {
        let path = PathBuf::from("/tmp/game.ipa");
        let mut facts = guide(&path, "aa");
        facts.display_name = "宝可梦 Y";
        let text = render_windows(&facts);
        assert!(text.contains("宝可梦 Y"));
    }
}
