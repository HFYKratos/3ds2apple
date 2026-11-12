//! The signing/installation guide shown after a build.
//!
//! The frontend never signs, installs or provisions anything: the unsigned IPA
//! is the product, and signing with the user's own Apple ID happens in
//! Sideloadly/AltStore on a Windows or macOS machine. The guide is generated
//! with the real artifact path, size and SHA256 so the user can verify what
//! they are about to sign.

use std::path::Path;

use serde::Serialize;

use crate::error::Error;
use crate::output::{format_bytes, Printer};

/// One downloaded IPA and its verified digest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct IpaInfo {
    pub path: String,
    pub bytes: u64,
    pub sha256: String,
}

impl IpaInfo {
    pub fn file_name(&self) -> String {
        Path::new(&self.path)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or(&self.path)
            .to_string()
    }
}

/// Hash a downloaded IPA and return its summary.
///
/// This is a local re-verification of what `zkb` already checked against the
/// Agent's manifest; it catches a corrupt or partially written download before
/// the user tries to sign it.
pub fn inspect_ipa(path: &Path) -> Result<IpaInfo, Error> {
    if !path.is_file() {
        return Err(Error::local(format!(
            "IPA {} does not exist; pass the path printed by the build",
            path.display()
        )));
    }
    let hash = builder_core::hash::sha256_file(path)
        .map_err(|error| Error::local(format!("could not read {}: {error}", path.display())))?;
    Ok(IpaInfo {
        path: path.display().to_string(),
        bytes: hash.bytes,
        sha256: hash.sha256,
    })
}

/// Build the guide text. `ipa` fills in the artifact-specific facts.
pub fn guide(ipa: Option<&IpaInfo>) -> String {
    let mut lines: Vec<String> = vec![
        "Installing the unsigned IPA".to_string(),
        "==========================".to_string(),
        String::new(),
        "This build produced an unsigned IPA. It contains code derived from the game you own;"
            .to_string(),
        "keep it on your own devices, do not redistribute it, and sign it yourself.".to_string(),
        String::new(),
    ];
    match ipa {
        Some(ipa) => {
            lines.push(format!("IPA:     {}", ipa.path));
            lines.push(format!("Size:    {}", format_bytes(ipa.bytes)));
            lines.push(format!("SHA256:  {}", ipa.sha256));
            lines.push(String::new());
            lines.push("Verify the copy before signing it:".to_string());
            lines.push(format!("  sha256sum '{}'", ipa.path));
            lines.push("  # Windows PowerShell:".to_string());
            lines.push(format!(
                "  Get-FileHash -Algorithm SHA256 '{}'",
                ipa.file_name()
            ));
            lines.push(String::new());
        }
        None => {
            lines.push(
                "Run `3ds2apple-builder install-guide --ipa <path-to-ipa>` to fill in the path"
                    .to_string(),
            );
            lines.push("and SHA256 of your download.".to_string());
            lines.push(String::new());
        }
    }
    lines.push("Option A - Sideloadly (Windows or macOS)".to_string());
    lines.push(
        "  1. Install Sideloadly (https://sideloadly.io/) and its Apple mobile-device".to_string(),
    );
    lines.push("     drivers as it instructs.".to_string());
    lines.push("  2. Connect the iPhone/iPad by USB and tap Trust on the device.".to_string());
    lines.push(
        "  3. Drag the IPA into Sideloadly, pick the device, enter your own Apple ID".to_string(),
    );
    lines.push("     inside Sideloadly, and press Start.".to_string());
    lines.push(
        "  4. First install only: trust the developer certificate on the device via".to_string(),
    );
    lines.push("     Settings > General > VPN & Device Management.".to_string());
    lines.push(
        "  5. A free Apple ID certificate expires after 7 days; a paid developer account"
            .to_string(),
    );
    lines.push("     lasts longer. That is Apple's limit, not this tool's.".to_string());
    lines.push(String::new());
    lines.push("Option B - AltStore / SideStore (Windows or macOS)".to_string());
    lines
        .push("  Install AltStore or SideStore, pair it with the device, then use its".to_string());
    lines.push(
        "  \"My Apps\" > + flow to install the IPA. The same certificate rules apply.".to_string(),
    );
    lines.push(String::new());
    lines.push("Linux workstations".to_string());
    lines.push(
        "  Official Sideloadly and AltStore builds do not run on Linux. Copy the IPA to"
            .to_string(),
    );
    lines.push(
        "  a Windows or macOS machine and follow Option A or B there. Community Linux".to_string(),
    );
    lines.push("  tools exist but are not tested or supported by this project.".to_string());
    lines.push(String::new());
    lines.push("Privacy and safety".to_string());
    lines.push(
        "  * This tool never asks for, stores or transmits an Apple ID, password, 2FA".to_string(),
    );
    lines.push("    code, device UDID, certificate or provisioning profile.".to_string());
    lines.push(
        "  * The ROM is sent only to the macOS host you configured and is deleted there"
            .to_string(),
    );
    lines.push("    when the build ends (unless you explicitly kept it).".to_string());
    lines.push(
        "  * The IPA must not be uploaded to any public service or shared; it contains".to_string(),
    );
    lines.push("    game-derived code.".to_string());
    lines.join("\n")
}

/// Print the guide (human mode only; JSON mode emits a one-line diagnostic).
pub fn print_guide(ipa: Option<&IpaInfo>, printer: Printer) {
    if printer.json {
        if let Some(ipa) = ipa {
            printer.diagnostic(format!(
                "install guide: {} ({} bytes, sha256 {})",
                ipa.path, ipa.bytes, ipa.sha256
            ));
        }
        return;
    }
    println!("{}", guide(ipa));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guide_without_artifact_still_explains_the_manual_step() {
        let text = guide(None);
        assert!(text.contains("unsigned IPA"));
        assert!(text.contains("Sideloadly"));
        assert!(text.contains("AltStore"));
        assert!(text.contains("never asks for"));
        assert!(text.contains("install-guide --ipa"));
        assert!(text.contains("Linux workstations"));
    }

    #[test]
    fn guide_with_artifact_shows_verified_facts() {
        let ipa = IpaInfo {
            path: "/home/u/.local/share/3ds2apple/builder/artifacts/pokemon-y/pokemon-y-AOT.ipa"
                .to_string(),
            bytes: 96 * 1024 * 1024,
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".to_string(),
        };
        let text = guide(Some(&ipa));
        assert!(text.contains("96.0 MiB"));
        assert!(text.contains(&ipa.sha256));
        assert!(text.contains("sha256sum"));
        assert!(text.contains("pokemon-y-AOT.ipa"));
        assert_eq!(ipa.file_name(), "pokemon-y-AOT.ipa");
    }

    #[test]
    fn inspect_ipa_reports_a_missing_file() {
        let dir = tempfile::tempdir().unwrap();
        let error = inspect_ipa(&dir.path().join("missing.ipa")).unwrap_err();
        assert_eq!(error.exit_code(), crate::error::EXIT_IO);
    }

    #[test]
    fn inspect_ipa_hashes_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("fake.ipa");
        std::fs::write(&path, b"abc").unwrap();
        let info = inspect_ipa(&path).unwrap();
        assert_eq!(info.bytes, 3);
        assert_eq!(
            info.sha256,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
