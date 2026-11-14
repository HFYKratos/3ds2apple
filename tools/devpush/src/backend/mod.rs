//! Device backend abstraction: real idevice/usbmuxd backend or filesystem mock.

pub mod mock;
pub mod real;

use std::path::Path;

use serde::{Deserialize, Serialize};
use sha2::Digest;
use sha2::Sha256;

use crate::error::{DevpushError, ErrorCode};
use crate::output::Reporter;

#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
pub enum ContainerKind {
    /// house_arrest VendContainer: the whole app data container (developer-signed apps).
    App,
    /// house_arrest VendDocuments: only Documents (apps with UIFileSharingEnabled).
    Documents,
}

impl ContainerKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::App => "app",
            Self::Documents => "documents",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceRecord {
    pub udid: String,
    pub name: Option<String>,
    pub model: Option<String>,
    pub ios_version: Option<String>,
    pub connection: String,
    pub paired: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryInfo {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    pub mtime: Option<i64>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileStat {
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    pub mtime: Option<i64>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallResult {
    pub ipa: String,
    pub bytes: u64,
    pub sha256: String,
    pub installed: bool,
    pub verified_bundle_id: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UninstallResult {
    pub bundle_id: String,
    pub uninstalled: bool,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppAttr {
    pub installed: bool,
    pub data_container: Option<String>,
    pub app_bundle_version: Option<String>,
    pub file_sharing_enabled: Option<bool>,
    pub keys: serde_json::Map<String, serde_json::Value>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PutResult {
    pub remote_path: String,
    pub bytes: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GetResult {
    pub local_path: String,
    pub bytes: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PutTarResult {
    pub dest: String,
    pub bytes: u64,
    pub entries: Option<usize>,
    pub tar_ok: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FreeResult {
    pub free_bytes: u64,
    pub total_bytes: Option<u64>,
}

#[derive(Clone, Debug)]
pub struct PutRequest {
    pub bundle_id: String,
    pub container: ContainerKind,
    pub local: std::path::PathBuf,
    pub remote: String,
    pub udid: Option<String>,
}

#[derive(Clone, Debug)]
pub struct GetRequest {
    pub bundle_id: String,
    pub container: ContainerKind,
    pub remote: String,
    pub local: std::path::PathBuf,
    pub udid: Option<String>,
}

#[derive(Clone, Debug)]
pub enum PutTarSource {
    TarFile(std::path::PathBuf),
    Manifest {
        list: std::path::PathBuf,
        root: std::path::PathBuf,
    },
}

#[derive(Clone, Debug)]
pub struct PutTarRequest {
    pub bundle_id: String,
    pub container: ContainerKind,
    pub dest: String,
    pub source: PutTarSource,
    pub udid: Option<String>,
}

pub enum Backend {
    Real(real::RealBackend),
    Mock(mock::MockBackend),
}

impl Backend {
    pub async fn connect(mock_dir: Option<std::path::PathBuf>) -> Result<Self, DevpushError> {
        match mock_dir {
            Some(dir) => Ok(Self::Mock(mock::MockBackend::open(dir)?)),
            None => Ok(Self::Real(real::RealBackend::connect().await?)),
        }
    }

    #[allow(dead_code)]
    pub fn is_mock(&self) -> bool {
        matches!(self, Self::Mock(_))
    }

    pub async fn devices(&mut self) -> Result<Vec<DeviceRecord>, DevpushError> {
        match self {
            Self::Real(b) => b.devices().await,
            Self::Mock(b) => b.devices().await,
        }
    }

    pub async fn install(
        &mut self,
        ipa: &Path,
        bundle: Option<&str>,
        udid: Option<&str>,
    ) -> Result<InstallResult, DevpushError> {
        match self {
            Self::Real(b) => b.install(ipa, bundle, udid).await,
            Self::Mock(b) => b.install(ipa, bundle, udid).await,
        }
    }

    pub async fn uninstall(
        &mut self,
        bundle: &str,
        udid: Option<&str>,
    ) -> Result<UninstallResult, DevpushError> {
        match self {
            Self::Real(b) => b.uninstall(bundle, udid).await,
            Self::Mock(b) => b.uninstall(bundle, udid).await,
        }
    }

    pub async fn app_attr(
        &mut self,
        bundle: &str,
        udid: Option<&str>,
    ) -> Result<AppAttr, DevpushError> {
        match self {
            Self::Real(b) => b.app_attr(bundle, udid).await,
            Self::Mock(b) => b.app_attr(bundle, udid).await,
        }
    }

    pub async fn ls(
        &mut self,
        bundle: &str,
        path: &str,
        container: ContainerKind,
        udid: Option<&str>,
    ) -> Result<Vec<EntryInfo>, DevpushError> {
        match self {
            Self::Real(b) => b.ls(bundle, path, container, udid).await,
            Self::Mock(b) => b.ls(bundle, path, container, udid).await,
        }
    }

    pub async fn stat(
        &mut self,
        bundle: &str,
        path: &str,
        container: ContainerKind,
        udid: Option<&str>,
    ) -> Result<FileStat, DevpushError> {
        match self {
            Self::Real(b) => b.stat(bundle, path, container, udid).await,
            Self::Mock(b) => b.stat(bundle, path, container, udid).await,
        }
    }

    pub async fn put(
        &mut self,
        req: &PutRequest,
        reporter: &mut Reporter,
    ) -> Result<PutResult, DevpushError> {
        match self {
            Self::Real(b) => b.put(req, reporter).await,
            Self::Mock(b) => b.put(req, reporter).await,
        }
    }

    pub async fn get(
        &mut self,
        req: &GetRequest,
        reporter: &mut Reporter,
    ) -> Result<GetResult, DevpushError> {
        match self {
            Self::Real(b) => b.get(req, reporter).await,
            Self::Mock(b) => b.get(req, reporter).await,
        }
    }

    pub async fn put_tar(
        &mut self,
        req: &PutTarRequest,
        reporter: &mut Reporter,
    ) -> Result<PutTarResult, DevpushError> {
        match self {
            Self::Real(b) => b.put_tar(req, reporter).await,
            Self::Mock(b) => b.put_tar(req, reporter).await,
        }
    }

    pub async fn tar_ok(
        &mut self,
        bundle: &str,
        path: &str,
        container: ContainerKind,
        udid: Option<&str>,
    ) -> Result<bool, DevpushError> {
        match self {
            Self::Real(b) => b.tar_ok(bundle, path, container, udid).await,
            Self::Mock(b) => b.tar_ok(bundle, path, container, udid).await,
        }
    }

    pub async fn mkdir(
        &mut self,
        bundle: &str,
        path: &str,
        container: ContainerKind,
        udid: Option<&str>,
    ) -> Result<(), DevpushError> {
        match self {
            Self::Real(b) => b.mkdir(bundle, path, container, udid).await,
            Self::Mock(b) => b.mkdir(bundle, path, container, udid).await,
        }
    }

    pub async fn rm(
        &mut self,
        bundle: &str,
        path: &str,
        container: ContainerKind,
        udid: Option<&str>,
    ) -> Result<bool, DevpushError> {
        match self {
            Self::Real(b) => b.rm(bundle, path, container, udid).await,
            Self::Mock(b) => b.rm(bundle, path, container, udid).await,
        }
    }

    pub async fn free(
        &mut self,
        bundle: &str,
        udid: Option<&str>,
    ) -> Result<FreeResult, DevpushError> {
        match self {
            Self::Real(b) => b.free(bundle, udid).await,
            Self::Mock(b) => b.free(bundle, udid).await,
        }
    }
}

/// Reject absolute paths, backslashes, empty paths and any dot-dot component.
/// Returns a normalized container-relative path.
pub fn sanitize_relative(path: &str) -> Result<String, DevpushError> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err(DevpushError::invalid("remote path must not be empty"));
    }
    if trimmed.contains('\\') {
        return Err(DevpushError::invalid(format!(
            "remote path must use forward slashes: {trimmed}"
        )));
    }
    if trimmed.starts_with('/') || trimmed.contains(':') || trimmed.starts_with("~/") {
        return Err(DevpushError::invalid(format!(
            "remote path must be container-relative: {trimmed}"
        )));
    }
    let mut parts: Vec<&str> = Vec::new();
    for seg in trimmed.split('/') {
        match seg {
            "" | "." => continue,
            ".." => {
                return Err(DevpushError::invalid(format!(
                    "remote path escapes the container: {trimmed}"
                )))
            }
            other => parts.push(other),
        }
    }
    if parts.is_empty() {
        return Err(DevpushError::invalid("remote path has no file component"));
    }
    Ok(parts.join("/"))
}

/// Bundle identifiers are used as directory names in mock mode; keep them to the
/// characters Apple allows.
pub fn sanitize_bundle_id(bundle: &str) -> Result<String, DevpushError> {
    let ok = !bundle.is_empty()
        && bundle.len() <= 155
        && bundle
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'));
    if !ok {
        return Err(DevpushError::invalid(format!(
            "invalid bundle identifier: {bundle:?}"
        )));
    }
    Ok(bundle.to_string())
}

pub fn pick_udid<'a>(
    devices: &'a [DeviceRecord],
    udid: Option<&str>,
) -> Result<&'a DeviceRecord, DevpushError> {
    if devices.is_empty() {
        return Err(DevpushError::new(
            ErrorCode::DeviceNotFound,
            "no iPhone/iPad is connected",
        ));
    }
    if let Some(want) = udid {
        return devices
            .iter()
            .find(|d| d.udid.eq_ignore_ascii_case(want))
            .ok_or_else(|| {
                DevpushError::new(
                    ErrorCode::DeviceNotFound,
                    format!("device {want} is not connected"),
                )
            });
    }
    if devices.len() > 1 {
        let list = devices
            .iter()
            .map(|d| d.udid.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        return Err(DevpushError::new(
            ErrorCode::DeviceAmbiguous,
            format!(
                "{} devices are connected ({list}); pass --udid",
                devices.len()
            ),
        ));
    }
    Ok(&devices[0])
}

pub fn finish_sha256(hasher: Sha256) -> String {
    let digest = hasher.finalize();
    let mut out = String::with_capacity(digest.len() * 2);
    for b in digest {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

/// Hash a local file and return (bytes, sha256 hex).
pub async fn hash_file(path: &Path) -> Result<(u64, String), DevpushError> {
    use tokio::io::AsyncReadExt;
    let mut file = tokio::fs::File::open(path)
        .await
        .map_err(|e| DevpushError::io(format!("cannot read {}: {e}", path.display())))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 256 * 1024];
    let mut total = 0u64;
    loop {
        let n = file
            .read(&mut buf)
            .await
            .map_err(|e| DevpushError::io(format!("cannot read {}: {e}", path.display())))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        total += n as u64;
    }
    Ok((total, finish_sha256(hasher)))
}

/// Create missing parent directories for a remote path (best effort: existing
/// directories are fine, exactly like the AFC clients in the wild).
pub async fn ensure_parents_afc(afc: &mut idevice::afc::AfcClient, remote: &str) {
    let mut prefix = String::new();
    let mut parts: Vec<&str> = remote.split('/').collect();
    parts.pop();
    for part in parts {
        if part.is_empty() {
            continue;
        }
        if !prefix.is_empty() {
            prefix.push('/');
        }
        prefix.push_str(part);
        let _ = afc.mk_dir(prefix.clone()).await;
    }
}

/// Create every component of a remote directory path (including the final one).
pub async fn mkdir_all_afc(afc: &mut idevice::afc::AfcClient, remote: &str) {
    let mut prefix = String::new();
    for part in remote.split('/') {
        if part.is_empty() {
            continue;
        }
        if !prefix.is_empty() {
            prefix.push('/');
        }
        prefix.push_str(part);
        let _ = afc.mk_dir(prefix.clone()).await;
    }
}
