//! Real device backend: Apple usbmuxd -> lockdownd -> house_arrest/VendContainer
//! + AFC file transfer, installation_proxy install/uninstall/lookup.
//!
//! This is a clean-room CLI around the MIT-licensed idevice crate. The service
//! usage pattern (house_arrest VendContainer + AFC, installation_proxy) follows
//! S2Arm's s2a-devpush (Apache-2.0) as credited in NOTICE.

use std::collections::HashSet;
use std::path::Path;

use idevice::{
    afc::{opcode::AfcFopenMode, AfcClient},
    house_arrest::HouseArrestClient,
    installation_proxy::InstallationProxyClient,
    lockdown::LockdownClient,
    provider::UsbmuxdProvider,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice},
    IdeviceError, IdeviceService,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::{
    ensure_parents_afc, hash_file, mkdir_all_afc, sanitize_bundle_id, sanitize_relative, AppAttr,
    ContainerKind, DeviceRecord, EntryInfo, FileStat, FreeResult, GetRequest, GetResult,
    InstallResult, PutRequest, PutResult, PutTarRequest, PutTarResult, PutTarSource,
    UninstallResult,
};
use crate::error::{DevpushError, ErrorCode};
use crate::output::Reporter;
use crate::tarstream;

pub struct RealBackend {
    addr: UsbmuxdAddr,
    mux: UsbmuxdConnection,
}

impl RealBackend {
    pub async fn connect() -> Result<Self, DevpushError> {
        let addr = UsbmuxdAddr::from_env_var()
            .map_err(|e| DevpushError::usage(format!("invalid USBMUXD_SOCKET_ADDRESS: {e}")))?;
        let socket = addr.to_socket().await.map_err(|e| {
            DevpushError::new(
                ErrorCode::UsbmuxdUnavailable,
                format!("cannot connect to Apple usbmuxd ({addr:?}): {e}"),
            )
        })?;
        Ok(Self {
            addr,
            mux: UsbmuxdConnection::new(socket, 0),
        })
    }

    async fn all_devices(&mut self) -> Result<Vec<UsbmuxdDevice>, DevpushError> {
        let mut list = self
            .mux
            .get_devices()
            .await
            .map_err(|e| DevpushError::from_idevice(e, "cannot list devices"))?;
        list.sort_by_key(|d| match d.connection_type {
            Connection::Usb => 0u8,
            _ => 1u8,
        });
        let mut seen = HashSet::new();
        list.retain(|d| seen.insert(d.udid.clone()));
        Ok(list)
    }

    async fn pick(
        &mut self,
        udid: Option<&str>,
    ) -> Result<(UsbmuxdDevice, UsbmuxdProvider), DevpushError> {
        let list = self.all_devices().await?;
        if list.is_empty() {
            return Err(DevpushError::new(
                ErrorCode::DeviceNotFound,
                "no iPhone/iPad is connected",
            ));
        }
        let dev = if let Some(want) = udid {
            list.into_iter()
                .find(|d| d.udid.eq_ignore_ascii_case(want))
                .ok_or_else(|| {
                    DevpushError::new(
                        ErrorCode::DeviceNotFound,
                        format!("device {want} is not connected"),
                    )
                })?
        } else if list.len() == 1 {
            list.into_iter().next().expect("one device")
        } else {
            let ids = list
                .iter()
                .map(|d| d.udid.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            return Err(DevpushError::new(
                ErrorCode::DeviceAmbiguous,
                format!("{} devices are connected ({ids}); pass --udid", list.len()),
            ));
        };
        let provider = dev.to_provider(self.addr.clone(), "devpush");
        Ok((dev, provider))
    }

    async fn open_container(
        &mut self,
        bundle: &str,
        container: ContainerKind,
        udid: Option<&str>,
    ) -> Result<AfcClient, DevpushError> {
        let (_dev, provider) = self.pick(udid).await?;
        open_container(&provider, bundle, container).await
    }

    pub async fn devices(&mut self) -> Result<Vec<DeviceRecord>, DevpushError> {
        let list = self.all_devices().await?;
        let mut records = Vec::with_capacity(list.len());
        for dev in list {
            let connection = match &dev.connection_type {
                Connection::Usb => "usb".to_string(),
                Connection::Network(ip) => format!("network ({ip})"),
                Connection::Unknown(desc) => format!("unknown ({desc})"),
            };
            let provider = dev.to_provider(self.addr.clone(), "devpush");
            let mut record = DeviceRecord {
                udid: dev.udid.clone(),
                name: None,
                model: None,
                ios_version: None,
                connection,
                paired: true,
            };
            match LockdownClient::connect(&provider).await {
                Ok(mut lockdown) => {
                    if let Ok(value) = lockdown.get_value(Some("DeviceName"), None).await {
                        record.name = value.as_string().map(str::to_string);
                    }
                    if let Ok(value) = lockdown.get_value(Some("ProductType"), None).await {
                        record.model = value.as_string().map(str::to_string);
                    }
                    if let Ok(value) = lockdown.get_value(Some("ProductVersion"), None).await {
                        record.ios_version = value.as_string().map(str::to_string);
                    }
                }
                Err(err) => {
                    // A device that has not been trusted yet reports InvalidHostID.
                    record.paired = !matches!(err, IdeviceError::InvalidHostID);
                }
            }
            records.push(record);
        }
        Ok(records)
    }

    pub async fn install(
        &mut self,
        ipa: &Path,
        bundle: Option<&str>,
        udid: Option<&str>,
    ) -> Result<InstallResult, DevpushError> {
        let (_dev, provider) = self.pick(udid).await?;
        let (bytes, sha256) = hash_file(ipa).await?;
        idevice::utils::installation::install_package(&provider, ipa, None)
            .await
            .map_err(map_install_error)?;
        let mut verified_bundle_id = None;
        if let Some(bundle) = bundle {
            let bundle = sanitize_bundle_id(bundle)?;
            let mut proxy = InstallationProxyClient::connect(&provider)
                .await
                .map_err(|e| DevpushError::from_idevice(e, "cannot connect installation_proxy"))?;
            let apps = proxy
                .get_apps(Some("Any"), Some(vec![bundle.clone()]))
                .await
                .map_err(|e| DevpushError::from_idevice(e, "cannot query installed apps"))?;
            if !apps.contains_key(bundle.as_str()) {
                return Err(DevpushError::new(
                    ErrorCode::InstallFailed,
                    format!(
                        "install_package returned success but {bundle} is not listed on the device"
                    ),
                ));
            }
            verified_bundle_id = Some(bundle);
        }
        Ok(InstallResult {
            ipa: ipa.display().to_string(),
            bytes,
            sha256,
            installed: true,
            verified_bundle_id,
        })
    }

    pub async fn uninstall(
        &mut self,
        bundle: &str,
        udid: Option<&str>,
    ) -> Result<UninstallResult, DevpushError> {
        let bundle = sanitize_bundle_id(bundle)?;
        let (_dev, provider) = self.pick(udid).await?;
        let mut proxy = InstallationProxyClient::connect(&provider)
            .await
            .map_err(|e| DevpushError::from_idevice(e, "cannot connect installation_proxy"))?;
        proxy.uninstall(bundle.clone(), None).await.map_err(|e| {
            let mut err = DevpushError::from_idevice(e, &format!("uninstalling {bundle}"));
            err.code = ErrorCode::InstallFailed;
            err
        })?;
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
        let bundle = sanitize_bundle_id(bundle)?;
        let (_dev, provider) = self.pick(udid).await?;
        let mut proxy = InstallationProxyClient::connect(&provider)
            .await
            .map_err(|e| DevpushError::from_idevice(e, "cannot connect installation_proxy"))?;
        let apps = proxy
            .get_apps(Some("Any"), Some(vec![bundle.clone()]))
            .await
            .map_err(|e| DevpushError::from_idevice(e, "cannot query installed apps"))?;
        let info = apps.get(&bundle).ok_or_else(|| {
            DevpushError::new(
                ErrorCode::AppMissing,
                format!("{bundle} is not installed on the device"),
            )
        })?;
        let dict = info.as_dictionary().ok_or_else(|| {
            DevpushError::new(
                ErrorCode::Internal,
                "installation_proxy returned a non-dictionary app record",
            )
        })?;
        let mut keys = serde_json::Map::new();
        for (key, value) in dict.iter() {
            let json_value = plist_to_json(value);
            if json_value.is_string() || json_value.is_boolean() || json_value.is_number() {
                keys.insert(key.clone(), json_value);
            }
        }
        let get_string = |names: &[&str]| -> Option<String> {
            names.iter().find_map(|name| {
                dict.get(name)
                    .and_then(|v| v.as_string())
                    .map(str::to_string)
            })
        };
        Ok(AppAttr {
            installed: true,
            data_container: get_string(&["Container", "DataContainer", "Path"]),
            app_bundle_version: get_string(&["CFBundleVersion", "CFBundleShortVersionString"]),
            file_sharing_enabled: dict
                .get("UIFileSharingEnabled")
                .and_then(|v| v.as_boolean()),
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
        let bundle = sanitize_bundle_id(bundle)?;
        let rel = sanitize_relative(path)?;
        let mut afc = self.open_container(&bundle, container, udid).await?;
        let names = afc
            .list_dir(rel.clone())
            .await
            .map_err(|e| DevpushError::from_idevice(e, &format!("cannot list {rel}")))?;
        let mut entries = Vec::new();
        for name in names {
            if name == "." || name == ".." || name.is_empty() {
                continue;
            }
            let child = format!("{rel}/{name}");
            let (is_dir, size, mtime) = match afc.get_file_info(child.clone()).await {
                Ok(info) => (
                    info.st_ifmt == "S_IFDIR",
                    info.size as u64,
                    Some(info.modified.and_utc().timestamp()),
                ),
                Err(_) => (false, 0, None),
            };
            entries.push(EntryInfo {
                name,
                is_dir,
                size,
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
        let bundle = sanitize_bundle_id(bundle)?;
        let rel = sanitize_relative(path)?;
        let mut afc = self.open_container(&bundle, container, udid).await?;
        let info = afc
            .get_file_info(rel.clone())
            .await
            .map_err(|e| DevpushError::from_idevice(e, &format!("cannot stat {rel}")))?;
        Ok(FileStat {
            path: rel,
            is_dir: info.st_ifmt == "S_IFDIR",
            size: info.size as u64,
            mtime: Some(info.modified.and_utc().timestamp()),
        })
    }

    pub async fn put(
        &mut self,
        req: &PutRequest,
        reporter: &mut Reporter,
    ) -> Result<PutResult, DevpushError> {
        let bundle = sanitize_bundle_id(&req.bundle_id)?;
        let remote = sanitize_relative(&req.remote)?;
        let meta = tokio::fs::metadata(&req.local)
            .await
            .map_err(|e| DevpushError::io(format!("cannot read {}: {e}", req.local.display())))?;
        if !meta.is_file() {
            return Err(DevpushError::io(format!(
                "{} is not a regular file",
                req.local.display()
            )));
        }
        let mut afc = self
            .open_container(&bundle, req.container, req.udid.as_deref())
            .await?;
        ensure_parents_afc(&mut afc, &remote).await;
        reporter.set_total(Some(meta.len()));
        reporter.set_file(
            req.local
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("file"),
        );
        let fd = afc
            .open(remote.clone(), AfcFopenMode::WrOnly)
            .await
            .map_err(|e| {
                DevpushError::from_idevice(e, &format!("cannot open {remote} for writing"))
            })?;
        let mut file = Box::pin(fd);
        let mut src = tokio::fs::File::open(&req.local)
            .await
            .map_err(|e| DevpushError::io(format!("cannot read {}: {e}", req.local.display())))?;
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
            file.write_all(&buf[..n])
                .await
                .map_err(|e| DevpushError::io(format!("cannot write {remote}: {e}")))?;
            sent += n as u64;
            reporter.tick(sent);
        }
        file.flush()
            .await
            .map_err(|e| DevpushError::io(format!("cannot flush {remote}: {e}")))?;
        drop(file);
        reporter.finish();
        Ok(PutResult {
            remote_path: remote,
            bytes: sent,
            sha256: super::finish_sha256(hasher),
        })
    }

    pub async fn get(
        &mut self,
        req: &GetRequest,
        reporter: &mut Reporter,
    ) -> Result<GetResult, DevpushError> {
        let bundle = sanitize_bundle_id(&req.bundle_id)?;
        let remote = sanitize_relative(&req.remote)?;
        let mut afc = self
            .open_container(&bundle, req.container, req.udid.as_deref())
            .await?;
        let info = afc
            .get_file_info(remote.clone())
            .await
            .map_err(|e| DevpushError::from_idevice(e, &format!("cannot stat {remote}")))?;
        reporter.set_total(Some(info.size as u64));
        reporter.set_file(remote.rsplit('/').next().unwrap_or(&remote));
        if let Some(parent) = req.local.parent() {
            if !parent.as_os_str().is_empty() {
                tokio::fs::create_dir_all(parent).await.map_err(|e| {
                    DevpushError::io(format!("cannot create {}: {e}", parent.display()))
                })?;
            }
        }
        let fd = afc
            .open(remote.clone(), AfcFopenMode::RdOnly)
            .await
            .map_err(|e| {
                DevpushError::from_idevice(e, &format!("cannot open {remote} for reading"))
            })?;
        let mut file = Box::pin(fd);
        let mut dst = tokio::fs::File::create(&req.local)
            .await
            .map_err(|e| DevpushError::io(format!("cannot create {}: {e}", req.local.display())))?;
        let mut hasher = Sha256::new();
        let mut buf = vec![0u8; 128 * 1024];
        let mut received = 0u64;
        loop {
            let n = file
                .read(&mut buf)
                .await
                .map_err(|e| DevpushError::io(format!("cannot read {remote}: {e}")))?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
            dst.write_all(&buf[..n]).await.map_err(|e| {
                DevpushError::io(format!("cannot write {}: {e}", req.local.display()))
            })?;
            received += n as u64;
            reporter.tick(received);
        }
        dst.flush()
            .await
            .map_err(|e| DevpushError::io(format!("cannot flush {}: {e}", req.local.display())))?;
        drop(file);
        reporter.finish();
        Ok(GetResult {
            local_path: req.local.display().to_string(),
            bytes: received,
            sha256: super::finish_sha256(hasher),
        })
    }

    pub async fn put_tar(
        &mut self,
        req: &PutTarRequest,
        reporter: &mut Reporter,
    ) -> Result<PutTarResult, DevpushError> {
        let bundle = sanitize_bundle_id(&req.bundle_id)?;
        let dest = sanitize_relative(&req.dest)?;
        let mut afc = self
            .open_container(&bundle, req.container, req.udid.as_deref())
            .await?;
        ensure_parents_afc(&mut afc, &dest).await;
        reporter.set_file(dest.rsplit('/').next().unwrap_or(&dest).to_string());
        let fd = afc
            .open(dest.clone(), AfcFopenMode::WrOnly)
            .await
            .map_err(|e| {
                DevpushError::from_idevice(e, &format!("cannot open {dest} for writing"))
            })?;
        let mut out = Box::pin(fd);
        let (bytes, entries) = match &req.source {
            PutTarSource::Manifest { list, root } => {
                let entries = tarstream::read_manifest(list, root)?;
                reporter.set_total(None);
                let stats = tarstream::write_tar(&mut out, &entries, reporter).await?;
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
                    out.write_all(&buf[..n])
                        .await
                        .map_err(|e| DevpushError::io(format!("cannot write {dest}: {e}")))?;
                    sent += n as u64;
                    reporter.tick(sent);
                }
                (sent, None)
            }
        };
        out.flush()
            .await
            .map_err(|e| DevpushError::io(format!("cannot flush {dest}: {e}")))?;
        drop(out);
        reporter.finish();
        let check_fd = afc
            .open(dest.clone(), AfcFopenMode::RdOnly)
            .await
            .map_err(|e| {
                DevpushError::from_idevice(e, &format!("cannot reopen {dest} for verification"))
            })?;
        let mut check = Box::pin(check_fd);
        let tar_ok = tarstream::tar_ok_reader(&mut check).await?;
        drop(check);
        Ok(PutTarResult {
            dest,
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
        let bundle = sanitize_bundle_id(bundle)?;
        let rel = sanitize_relative(path)?;
        let mut afc = self.open_container(&bundle, container, udid).await?;
        let fd = afc
            .open(rel.clone(), AfcFopenMode::RdOnly)
            .await
            .map_err(|e| {
                DevpushError::from_idevice(e, &format!("cannot open {rel} for reading"))
            })?;
        let mut file = Box::pin(fd);
        tarstream::tar_ok_reader(&mut file).await
    }

    pub async fn mkdir(
        &mut self,
        bundle: &str,
        path: &str,
        container: ContainerKind,
        udid: Option<&str>,
    ) -> Result<(), DevpushError> {
        let bundle = sanitize_bundle_id(bundle)?;
        let rel = sanitize_relative(path)?;
        let mut afc = self.open_container(&bundle, container, udid).await?;
        mkdir_all_afc(&mut afc, &rel).await;
        Ok(())
    }

    pub async fn rm(
        &mut self,
        bundle: &str,
        path: &str,
        container: ContainerKind,
        udid: Option<&str>,
    ) -> Result<bool, DevpushError> {
        let bundle = sanitize_bundle_id(bundle)?;
        let rel = sanitize_relative(path)?;
        let mut afc = self.open_container(&bundle, container, udid).await?;
        match afc.get_file_info(rel.clone()).await {
            Ok(_) => {
                afc.remove_all(rel.clone())
                    .await
                    .map_err(|e| DevpushError::from_idevice(e, &format!("cannot remove {rel}")))?;
                Ok(true)
            }
            Err(_) => Ok(false),
        }
    }

    pub async fn free(
        &mut self,
        bundle: &str,
        udid: Option<&str>,
    ) -> Result<FreeResult, DevpushError> {
        let bundle = sanitize_bundle_id(bundle)?;
        let mut afc = self
            .open_container(&bundle, ContainerKind::App, udid)
            .await?;
        let info = afc
            .get_device_info()
            .await
            .map_err(|e| DevpushError::from_idevice(e, "cannot query device free space"))?;
        Ok(FreeResult {
            free_bytes: info.free_bytes as u64,
            total_bytes: Some(info.total_bytes as u64),
        })
    }
}

fn map_install_error(err: IdeviceError) -> DevpushError {
    let mut mapped = DevpushError::from_idevice(err, "installing IPA");
    mapped.code = ErrorCode::InstallFailed;
    mapped
}

async fn open_container(
    provider: &UsbmuxdProvider,
    bundle: &str,
    container: ContainerKind,
) -> Result<AfcClient, DevpushError> {
    let house_arrest = HouseArrestClient::connect(provider)
        .await
        .map_err(|e| DevpushError::from_idevice(e, "cannot connect house_arrest"))?;
    let result = match container {
        ContainerKind::App => house_arrest.vend_container(bundle.to_string()).await,
        ContainerKind::Documents => house_arrest.vend_documents(bundle.to_string()).await,
    };
    match result {
        Ok(afc) => Ok(afc),
        Err(err) => {
            let raw = format!("{err}");
            let missing = match InstallationProxyClient::connect(provider).await {
                Ok(mut proxy) => match proxy
                    .get_apps(Some("Any"), Some(vec![bundle.to_string()]))
                    .await
                {
                    Ok(apps) => Some(!apps.contains_key(bundle)),
                    Err(_) => None,
                },
                Err(_) => None,
            };
            let lower = raw.to_ascii_lowercase();
            if lower.contains("pair") || lower.contains("trust") {
                return Err(DevpushError::from_idevice(err, "opening app container")
                    .with_hint(ErrorCode::PairingRequired.hint()));
            }
            if lower.contains("locked") {
                return Err(DevpushError::from_idevice(err, "opening app container")
                    .with_hint(ErrorCode::DeviceLocked.hint()));
            }
            match missing {
                Some(true) => Err(DevpushError::new(
                    ErrorCode::AppMissing,
                    format!("{bundle} is not installed on the device (house_arrest: {raw})"),
                )),
                Some(false) => Err(DevpushError::new(
                    ErrorCode::ContainerUnavailable,
                    format!(
                        "cannot open the {} container of {bundle} (house_arrest: {raw})",
                        container.as_str()
                    ),
                )),
                None => Err(DevpushError::new(
                    ErrorCode::ContainerUnavailable,
                    format!(
                        "cannot open the {} container of {bundle} (house_arrest: {raw})",
                        container.as_str()
                    ),
                )),
            }
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

fn plist_to_json(value: &plist::Value) -> Value {
    match value {
        plist::Value::Boolean(b) => json!(b),
        plist::Value::Integer(i) => i
            .as_signed()
            .map(|v| json!(v))
            .or_else(|| i.as_unsigned().map(|v| json!(v)))
            .unwrap_or(Value::Null),
        plist::Value::Real(r) => json!(r),
        plist::Value::String(s) => json!(s),
        plist::Value::Data(d) => json!(hex(d)),
        plist::Value::Date(d) => json!(format!("{d:?}")),
        plist::Value::Array(a) => json!(a.iter().map(plist_to_json).collect::<Vec<_>>()),
        plist::Value::Dictionary(d) => {
            let mut map = serde_json::Map::new();
            for (key, value) in d.iter() {
                map.insert(key.clone(), plist_to_json(value));
            }
            json!(map)
        }
        _ => Value::Null,
    }
}
