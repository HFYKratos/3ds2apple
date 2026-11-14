//! Filesystem mock backend for --mock-dir.
//!
//! Launchers and CI can exercise the full devpush CLI contract without an
//! iPhone. The mock keeps a state.json (devices + installed apps) and maps
//! container-relative paths onto containers/<bundleId> (VendContainer) and
//! documents/<bundleId> (VendDocuments).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::{
    finish_sha256, hash_file, pick_udid, sanitize_bundle_id, sanitize_relative, AppAttr,
    ContainerKind, DeviceRecord, EntryInfo, FileStat, FreeResult, GetRequest, GetResult,
    InstallResult, PutRequest, PutResult, PutTarRequest, PutTarResult, PutTarSource,
    UninstallResult,
};
use crate::error::{DevpushError, ErrorCode};
use crate::output::Reporter;
use crate::tarstream;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct MockApp {
    #[serde(default)]
    version: Option<String>,
    #[serde(default = "default_true")]
    file_sharing: bool,
    #[serde(default)]
    attrs: BTreeMap<String, serde_json::Value>,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct MockState {
    #[serde(default)]
    devices: Option<Vec<DeviceRecord>>,
    #[serde(default)]
    apps: BTreeMap<String, MockApp>,
}

fn default_devices() -> Vec<DeviceRecord> {
    vec![DeviceRecord {
        udid: "MOCK-0000000000000001".into(),
        name: Some("Mock iPhone".into()),
        model: Some("iPhone15,2".into()),
        ios_version: Some("17.0".into()),
        connection: "usb".into(),
        paired: true,
    }]
}

pub struct MockBackend {
    root: PathBuf,
}

impl MockBackend {
    pub fn open(root: PathBuf) -> Result<Self, DevpushError> {
        std::fs::create_dir_all(root.join("containers")).map_err(|e| {
            DevpushError::io(format!("cannot create mock dir {}: {e}", root.display()))
        })?;
        std::fs::create_dir_all(root.join("documents")).map_err(|e| {
            DevpushError::io(format!("cannot create mock dir {}: {e}", root.display()))
        })?;
        let backend = Self { root };
        if !backend.state_path().exists() {
            backend.save(&MockState::default())?;
        }
        Ok(backend)
    }

    fn state_path(&self) -> PathBuf {
        self.root.join("state.json")
    }

    fn load(&self) -> Result<MockState, DevpushError> {
        let path = self.state_path();
        let bytes = std::fs::read(&path).map_err(|e| {
            DevpushError::io(format!("cannot read mock state {}: {e}", path.display()))
        })?;
        serde_json::from_slice(&bytes).map_err(|e| {
            DevpushError::io(format!(
                "mock state {} is not valid JSON: {e}",
                path.display()
            ))
        })
    }

    fn save(&self, state: &MockState) -> Result<(), DevpushError> {
        let path = self.state_path();
        let bytes = serde_json::to_vec_pretty(state).map_err(|e| {
            DevpushError::new(
                ErrorCode::Internal,
                format!("cannot encode mock state: {e}"),
            )
        })?;
        std::fs::write(&path, bytes).map_err(|e| {
            DevpushError::io(format!("cannot write mock state {}: {e}", path.display()))
        })
    }

    fn devices_list(&self) -> Result<Vec<DeviceRecord>, DevpushError> {
        let state = self.load()?;
        Ok(state.devices.unwrap_or_else(default_devices))
    }

    fn pick(&self, udid: Option<&str>) -> Result<DeviceRecord, DevpushError> {
        let list = self.devices_list()?;
        Ok(pick_udid(&list, udid)?.clone())
    }

    fn app(&self, bundle: &str) -> Result<MockApp, DevpushError> {
        let state = self.load()?;
        state.apps.get(bundle).cloned().ok_or_else(|| {
            DevpushError::new(
                ErrorCode::AppMissing,
                format!("{bundle} is not installed in the mock device"),
            )
        })
    }

    fn root_for(&self, bundle: &str, container: ContainerKind) -> PathBuf {
        match container {
            ContainerKind::App => self.root.join("containers").join(bundle),
            ContainerKind::Documents => self.root.join("documents").join(bundle),
        }
    }

    fn resolve(
        &self,
        bundle: &str,
        container: ContainerKind,
        remote: &str,
    ) -> Result<(PathBuf, String), DevpushError> {
        let app = self.app(bundle)?;
        if container == ContainerKind::Documents && !app.file_sharing {
            return Err(DevpushError::new(
                ErrorCode::ContainerUnavailable,
                format!("{bundle} does not expose Documents (UIFileSharingEnabled is false)"),
            ));
        }
        let rel = sanitize_relative(remote)?;
        let mut path = self.root_for(bundle, container);
        for part in rel.split('/') {
            path.push(part);
        }
        Ok((path, rel))
    }

    fn path_not_found(rel: &str) -> DevpushError {
        DevpushError::new(
            ErrorCode::PathNotFound,
            format!("remote path does not exist: {rel}"),
        )
    }

    pub async fn devices(&mut self) -> Result<Vec<DeviceRecord>, DevpushError> {
        self.devices_list()
    }

    pub async fn install(
        &mut self,
        ipa: &Path,
        bundle: Option<&str>,
        udid: Option<&str>,
    ) -> Result<InstallResult, DevpushError> {
        self.pick(udid)?;
        let bundle = bundle.ok_or_else(|| DevpushError::usage("mock install needs --bundle-id (a real device reports it through installation_proxy)"))?;
        let bundle = sanitize_bundle_id(bundle)?;
        let meta = tokio::fs::metadata(ipa)
            .await
            .map_err(|e| DevpushError::io(format!("cannot read {}: {e}", ipa.display())))?;
        if !meta.is_file() {
            return Err(DevpushError::io(format!(
                "{} is not a regular file",
                ipa.display()
            )));
        }
        let (bytes, sha256) = hash_file(ipa).await?;
        let mut state = self.load()?;
        let mut attrs = BTreeMap::new();
        attrs.insert("CFBundleVersion".to_string(), serde_json::json!("1.0"));
        attrs.insert(
            "CFBundleShortVersionString".to_string(),
            serde_json::json!("1.0"),
        );
        state.apps.insert(
            bundle.clone(),
            MockApp {
                version: Some("1.0".into()),
                file_sharing: true,
                attrs,
            },
        );
        self.save(&state)?;
        for kind in [ContainerKind::App, ContainerKind::Documents] {
            let _ = tokio::fs::create_dir_all(self.root_for(&bundle, kind)).await;
        }
        Ok(InstallResult {
            ipa: ipa.display().to_string(),
            bytes,
            sha256,
            installed: true,
            verified_bundle_id: Some(bundle),
        })
    }

    pub async fn uninstall(
        &mut self,
        bundle: &str,
        udid: Option<&str>,
    ) -> Result<UninstallResult, DevpushError> {
        self.pick(udid)?;
        let bundle = sanitize_bundle_id(bundle)?;
        let mut state = self.load()?;
        if state.apps.remove(&bundle).is_none() {
            return Err(DevpushError::new(
                ErrorCode::AppMissing,
                format!("{bundle} is not installed in the mock device"),
            ));
        }
        self.save(&state)?;
        for kind in [ContainerKind::App, ContainerKind::Documents] {
            let root = self.root_for(&bundle, kind);
            if root.exists() {
                let _ = std::fs::remove_dir_all(root);
            }
        }
        Ok(UninstallResult {
            bundle_id: bundle,
            uninstalled: true,
        })
    }

    pub async fn app_attr(
        &mut self,
        bundle: &str,
        udid: Option<&str>,
    ) -> Result<AppAttr, DevpushError> {
        self.pick(udid)?;
        let bundle = sanitize_bundle_id(bundle)?;
        let app = self.app(&bundle)?;
        let mut keys = serde_json::Map::new();
        for (k, v) in &app.attrs {
            keys.insert(k.clone(), v.clone());
        }
        Ok(AppAttr {
            installed: true,
            data_container: Some(
                self.root_for(&bundle, ContainerKind::App)
                    .display()
                    .to_string(),
            ),
            app_bundle_version: app
                .attrs
                .get("CFBundleVersion")
                .and_then(|v| v.as_str().map(str::to_string))
                .or_else(|| app.version.clone()),
            file_sharing_enabled: Some(app.file_sharing),
            keys,
        })
    }

    pub async fn ls(
        &mut self,
        bundle: &str,
        path: &str,
        container: ContainerKind,
        udid: Option<&str>,
    ) -> Result<Vec<EntryInfo>, DevpushError> {
        self.pick(udid)?;
        let bundle = sanitize_bundle_id(bundle)?;
        let (dir, rel) = self.resolve(&bundle, container, path)?;
        let mut read_dir = match tokio::fs::read_dir(&dir).await {
            Ok(rd) => rd,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Err(Self::path_not_found(&rel))
            }
            Err(e) => {
                return Err(DevpushError::io(format!(
                    "cannot list {}: {e}",
                    dir.display()
                )))
            }
        };
        let mut entries = Vec::new();
        while let Some(entry) = read_dir
            .next_entry()
            .await
            .map_err(|e| DevpushError::io(format!("cannot list {}: {e}", dir.display())))?
        {
            let name = entry.file_name().to_string_lossy().to_string();
            let meta = entry.metadata().await.ok();
            let mtime = meta
                .as_ref()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64);
            entries.push(EntryInfo {
                name,
                is_dir: meta.as_ref().map(|m| m.is_dir()).unwrap_or(false),
                size: meta
                    .as_ref()
                    .filter(|m| m.is_file())
                    .map(|m| m.len())
                    .unwrap_or(0),
                mtime,
            });
        }
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(entries)
    }

    pub async fn stat(
        &mut self,
        bundle: &str,
        path: &str,
        container: ContainerKind,
        udid: Option<&str>,
    ) -> Result<FileStat, DevpushError> {
        self.pick(udid)?;
        let bundle = sanitize_bundle_id(bundle)?;
        let (file, rel) = self.resolve(&bundle, container, path)?;
        let meta = match tokio::fs::metadata(&file).await {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Err(Self::path_not_found(&rel))
            }
            Err(e) => {
                return Err(DevpushError::io(format!(
                    "cannot stat {}: {e}",
                    file.display()
                )))
            }
        };
        let mtime = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64);
        Ok(FileStat {
            path: rel,
            is_dir: meta.is_dir(),
            size: if meta.is_file() { meta.len() } else { 0 },
            mtime,
        })
    }

    pub async fn put(
        &mut self,
        req: &PutRequest,
        reporter: &mut Reporter,
    ) -> Result<PutResult, DevpushError> {
        self.pick(req.udid.as_deref())?;
        let bundle = sanitize_bundle_id(&req.bundle_id)?;
        let (dest, rel) = self.resolve(&bundle, req.container, &req.remote)?;
        let meta = tokio::fs::metadata(&req.local)
            .await
            .map_err(|e| DevpushError::io(format!("cannot read {}: {e}", req.local.display())))?;
        if !meta.is_file() {
            return Err(DevpushError::io(format!(
                "{} is not a regular file",
                req.local.display()
            )));
        }
        reporter.set_total(Some(meta.len()));
        reporter.set_file(
            req.local
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("file"),
        );
        if let Some(parent) = dest.parent() {
            tokio::fs::create_dir_all(parent).await.map_err(|e| {
                DevpushError::io(format!("cannot create {}: {e}", parent.display()))
            })?;
        }
        let mut src = tokio::fs::File::open(&req.local)
            .await
            .map_err(|e| DevpushError::io(format!("cannot open {}: {e}", req.local.display())))?;
        let mut dst = tokio::fs::File::create(&dest)
            .await
            .map_err(|e| DevpushError::io(format!("cannot create {}: {e}", dest.display())))?;
        let mut hasher = Sha256::new();
        let mut buf = vec![0u8; 128 * 1024];
        let mut sent = 0u64;
        loop {
            let n = src.read(&mut buf).await.map_err(|e| {
                DevpushError::io(format!("cannot read {}: {e}", req.local.display()))
            })?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
            dst.write_all(&buf[..n])
                .await
                .map_err(|e| DevpushError::io(format!("cannot write {}: {e}", dest.display())))?;
            sent += n as u64;
            reporter.tick(sent);
        }
        dst.flush()
            .await
            .map_err(|e| DevpushError::io(format!("cannot flush {}: {e}", dest.display())))?;
        reporter.finish();
        Ok(PutResult {
            remote_path: rel,
            bytes: sent,
            sha256: finish_sha256(hasher),
        })
    }

    pub async fn get(
        &mut self,
        req: &GetRequest,
        reporter: &mut Reporter,
    ) -> Result<GetResult, DevpushError> {
        self.pick(req.udid.as_deref())?;
        let bundle = sanitize_bundle_id(&req.bundle_id)?;
        let (src_path, rel) = self.resolve(&bundle, req.container, &req.remote)?;
        let meta = match tokio::fs::metadata(&src_path).await {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Err(Self::path_not_found(&rel))
            }
            Err(e) => {
                return Err(DevpushError::io(format!(
                    "cannot stat {}: {e}",
                    src_path.display()
                )))
            }
        };
        reporter.set_total(Some(meta.len()));
        reporter.set_file(rel.rsplit('/').next().unwrap_or(&rel));
        if let Some(parent) = req.local.parent() {
            if !parent.as_os_str().is_empty() {
                tokio::fs::create_dir_all(parent).await.map_err(|e| {
                    DevpushError::io(format!("cannot create {}: {e}", parent.display()))
                })?;
            }
        }
        let mut src = tokio::fs::File::open(&src_path)
            .await
            .map_err(|e| DevpushError::io(format!("cannot open {}: {e}", src_path.display())))?;
        let mut dst = tokio::fs::File::create(&req.local)
            .await
            .map_err(|e| DevpushError::io(format!("cannot create {}: {e}", req.local.display())))?;
        let mut hasher = Sha256::new();
        let mut buf = vec![0u8; 128 * 1024];
        let mut sent = 0u64;
        loop {
            let n = src.read(&mut buf).await.map_err(|e| {
                DevpushError::io(format!("cannot read {}: {e}", src_path.display()))
            })?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
            dst.write_all(&buf[..n]).await.map_err(|e| {
                DevpushError::io(format!("cannot write {}: {e}", req.local.display()))
            })?;
            sent += n as u64;
            reporter.tick(sent);
        }
        dst.flush()
            .await
            .map_err(|e| DevpushError::io(format!("cannot flush {}: {e}", req.local.display())))?;
        reporter.finish();
        Ok(GetResult {
            local_path: req.local.display().to_string(),
            bytes: sent,
            sha256: finish_sha256(hasher),
        })
    }

    pub async fn put_tar(
        &mut self,
        req: &PutTarRequest,
        reporter: &mut Reporter,
    ) -> Result<PutTarResult, DevpushError> {
        self.pick(req.udid.as_deref())?;
        let bundle = sanitize_bundle_id(&req.bundle_id)?;
        let (dest, rel) = self.resolve(&bundle, req.container, &req.dest)?;
        reporter.set_file(rel.rsplit('/').next().unwrap_or(&rel));
        if let Some(parent) = dest.parent() {
            tokio::fs::create_dir_all(parent).await.map_err(|e| {
                DevpushError::io(format!("cannot create {}: {e}", parent.display()))
            })?;
        }
        let mut dst = tokio::fs::File::create(&dest)
            .await
            .map_err(|e| DevpushError::io(format!("cannot create {}: {e}", dest.display())))?;
        let (bytes, entries) = match &req.source {
            PutTarSource::Manifest { list, root } => {
                let entries = tarstream::read_manifest(list, root)?;
                reporter.set_total(None);
                let stats = tarstream::write_tar(&mut dst, &entries, reporter).await?;
                (stats.payload_bytes, Some(stats.entries))
            }
            PutTarSource::TarFile(tar) => {
                let mut src = tokio::fs::File::open(tar)
                    .await
                    .map_err(|e| DevpushError::io(format!("cannot open {}: {e}", tar.display())))?;
                reporter.set_total(src.metadata().await.ok().map(|m| m.len()));
                let mut buf = vec![0u8; 128 * 1024];
                let mut sent = 0u64;
                loop {
                    let n = src.read(&mut buf).await.map_err(|e| {
                        DevpushError::io(format!("cannot read {}: {e}", tar.display()))
                    })?;
                    if n == 0 {
                        break;
                    }
                    dst.write_all(&buf[..n]).await.map_err(|e| {
                        DevpushError::io(format!("cannot write {}: {e}", dest.display()))
                    })?;
                    sent += n as u64;
                    reporter.tick(sent);
                }
                (sent, None)
            }
        };
        dst.flush()
            .await
            .map_err(|e| DevpushError::io(format!("cannot flush {}: {e}", dest.display())))?;
        reporter.finish();
        let mut check = tokio::fs::File::open(&dest)
            .await
            .map_err(|e| DevpushError::io(format!("cannot reopen {}: {e}", dest.display())))?;
        let tar_ok = tarstream::tar_ok_reader(&mut check).await?;
        Ok(PutTarResult {
            dest: rel,
            bytes,
            entries,
            tar_ok,
        })
    }

    pub async fn tar_ok(
        &mut self,
        bundle: &str,
        path: &str,
        container: ContainerKind,
        udid: Option<&str>,
    ) -> Result<bool, DevpushError> {
        self.pick(udid)?;
        let bundle = sanitize_bundle_id(bundle)?;
        let (file, rel) = self.resolve(&bundle, container, path)?;
        let mut f = tokio::fs::File::open(&file).await.map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                Self::path_not_found(&rel)
            } else {
                DevpushError::io(format!("cannot open {}: {e}", file.display()))
            }
        })?;
        tarstream::tar_ok_reader(&mut f).await
    }

    pub async fn mkdir(
        &mut self,
        bundle: &str,
        path: &str,
        container: ContainerKind,
        udid: Option<&str>,
    ) -> Result<(), DevpushError> {
        self.pick(udid)?;
        let bundle = sanitize_bundle_id(bundle)?;
        let (dir, _rel) = self.resolve(&bundle, container, path)?;
        tokio::fs::create_dir_all(&dir)
            .await
            .map_err(|e| DevpushError::io(format!("cannot create {}: {e}", dir.display())))
    }

    pub async fn rm(
        &mut self,
        bundle: &str,
        path: &str,
        container: ContainerKind,
        udid: Option<&str>,
    ) -> Result<bool, DevpushError> {
        self.pick(udid)?;
        let bundle = sanitize_bundle_id(bundle)?;
        let (target, _rel) = self.resolve(&bundle, container, path)?;
        match tokio::fs::metadata(&target).await {
            Ok(meta) => {
                if meta.is_dir() {
                    tokio::fs::remove_dir_all(&target).await.map_err(|e| {
                        DevpushError::io(format!("cannot remove {}: {e}", target.display()))
                    })?;
                } else {
                    tokio::fs::remove_file(&target).await.map_err(|e| {
                        DevpushError::io(format!("cannot remove {}: {e}", target.display()))
                    })?;
                }
                Ok(true)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(DevpushError::io(format!(
                "cannot stat {}: {e}",
                target.display()
            ))),
        }
    }

    pub async fn free(
        &mut self,
        _bundle: &str,
        udid: Option<&str>,
    ) -> Result<FreeResult, DevpushError> {
        self.pick(udid)?;
        Ok(FreeResult {
            free_bytes: 64 * 1024 * 1024 * 1024,
            total_bytes: Some(256 * 1024 * 1024 * 1024),
        })
    }
}
