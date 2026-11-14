//! Stable error codes, exit codes and idevice error mapping for devpush.
//!
//! Contract: docs/device-bridge.md. Every failure is printed as one JSON object
//! (--json) or one human line, and the process exit code is stable per code.

use serde_json::{json, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    Usage,
    InvalidArgument,
    DeviceNotFound,
    DeviceAmbiguous,
    UsbmuxdUnavailable,
    PairingRequired,
    DeviceLocked,
    AppMissing,
    ContainerUnavailable,
    StallTimeout,
    AfcError,
    PathNotFound,
    IoError,
    InstallFailed,
    DeveloperModeRequired,
    #[allow(dead_code)]
    Unsupported,
    Internal,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Usage => "usage",
            Self::InvalidArgument => "invalid_argument",
            Self::DeviceNotFound => "device_not_found",
            Self::DeviceAmbiguous => "device_ambiguous",
            Self::UsbmuxdUnavailable => "usbmuxd_unavailable",
            Self::PairingRequired => "pairing_required",
            Self::DeviceLocked => "device_locked",
            Self::AppMissing => "app_missing",
            Self::ContainerUnavailable => "container_unavailable",
            Self::StallTimeout => "stall_timeout",
            Self::AfcError => "afc_error",
            Self::PathNotFound => "path_not_found",
            Self::IoError => "io_error",
            Self::InstallFailed => "install_failed",
            Self::DeveloperModeRequired => "developer_mode_required",
            Self::Unsupported => "unsupported",
            Self::Internal => "internal_error",
        }
    }

    /// Stable process exit codes (contract v1):
    /// 0 ok, 1 internal, 2 usage, 3 device, 4 pairing/locked, 5 app/container,
    /// 6 stall, 7 afc/path/io, 8 install, 9 developer-mode/unsupported.
    pub fn exit_code(self) -> i32 {
        match self {
            Self::Usage | Self::InvalidArgument => 2,
            Self::DeviceNotFound | Self::DeviceAmbiguous | Self::UsbmuxdUnavailable => 3,
            Self::PairingRequired | Self::DeviceLocked => 4,
            Self::AppMissing | Self::ContainerUnavailable => 5,
            Self::StallTimeout => 6,
            Self::AfcError | Self::PathNotFound | Self::IoError => 7,
            Self::InstallFailed => 8,
            Self::DeveloperModeRequired | Self::Unsupported => 9,
            Self::Internal => 1,
        }
    }

    pub fn hint(self) -> &'static str {
        match self {
            Self::Usage => "Run devpush <command> --help for the expected arguments.",
            Self::InvalidArgument => "Remote paths are container-relative (e.g. Documents/Games/<TITLEID>/GamePack.dylib); never absolute and never contain dot-dot.",
            Self::DeviceNotFound => "Connect the iPhone/iPad by USB, unlock it and tap Trust; for Wi-Fi keep the device on the same network as usbmuxd.",
            Self::DeviceAmbiguous => "Several devices are connected; pass --udid to choose one (see devpush devices).",
            Self::UsbmuxdUnavailable => "Apple usbmuxd is not reachable. Install/start usbmuxd (libimobiledevice) or the Apple Mobile Device service, then retry.",
            Self::PairingRequired => "Unlock the device and tap Trust on the Trust This Computer prompt; on iOS 16+ also enable Settings > Privacy & Security > Developer Mode.",
            Self::DeviceLocked => "Unlock the iPhone/iPad and keep it unlocked while installing or pushing files.",
            Self::AppMissing => "The app is not installed on this device. Install the base shell IPA first (Impactor/plumesign or Xcode/devicectl), then retry.",
            Self::ContainerUnavailable => "The app must be developer-signed (get-task-allow) to open its whole container; for --container documents the app must set UIFileSharingEnabled.",
            Self::StallTimeout => "No progress for the stall timeout: the cable/Wi-Fi connection probably dropped or the app was reinstalled. Reconnect and retry; completed files are kept.",
            Self::AfcError => "AFC file transfer failed. Check free space on the device and that the app is not being updated; retry after reconnecting.",
            Self::PathNotFound => "The remote path does not exist inside the app container.",
            Self::IoError => "Local file or socket I/O failed; check the path, permissions and free disk space.",
            Self::InstallFailed => "The IPA must already be signed by Impactor/plumesign or Xcode. Check the Apple ID session, the free-app slot (3 apps per free account) and device pairing.",
            Self::DeveloperModeRequired => "Enable Settings > Privacy & Security > Developer Mode on the device, reboot and confirm.",
            Self::Unsupported => "This operation/device/iOS combination is not supported by the current devpush build.",
            Self::Internal => "Unexpected internal error; re-run with the same arguments and report the diagnostic text.",
        }
    }
}

#[derive(Debug, Clone)]
pub struct DevpushError {
    pub code: ErrorCode,
    pub message: String,
    /// Optional actionable hint. Code-level default hint is used when absent.
    pub detail: Option<String>,
    /// AFC sub-code when the failure came from the device filesystem.
    pub afc_code: Option<i32>,
}

impl DevpushError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            detail: None,
            afc_code: None,
        }
    }

    pub fn usage(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::Usage, message)
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::InvalidArgument, message)
    }

    pub fn io(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::IoError, message)
    }

    pub fn with_hint(mut self, hint: impl Into<String>) -> Self {
        self.detail = Some(hint.into());
        self
    }

    pub fn with_afc_code(mut self, code: i32) -> Self {
        self.afc_code = Some(code);
        self
    }

    pub fn to_json(&self) -> Value {
        let mut obj = json!({
            "code": self.code.as_str(),
            "message": self.message,
            "hint": self.detail.clone().unwrap_or_else(|| self.code.hint().to_string()),
        });
        if let Some(c) = self.afc_code {
            obj["afcCode"] = json!(c);
        }
        obj
    }

    /// Map an idevice crate error to a stable devpush error.
    pub fn from_idevice(err: idevice::IdeviceError, context: &str) -> Self {
        use idevice::IdeviceError as E;
        let text = format!("{context}: {err}");
        match &err {
            E::Afc(afc) => {
                let sub = afc.sub_code();
                let code = match sub {
                    8 => ErrorCode::PathNotFound,
                    10 | 11 => ErrorCode::ContainerUnavailable,
                    18 => ErrorCode::AfcError,
                    _ => ErrorCode::AfcError,
                };
                DevpushError::new(code, text).with_afc_code(sub)
            }
            E::InvalidHostID => DevpushError::new(ErrorCode::PairingRequired, text),
            E::DeviceLocked => DevpushError::new(ErrorCode::DeviceLocked, text),
            E::DeviceNotFound => DevpushError::new(ErrorCode::DeviceNotFound, text),
            E::DeveloperModeNotEnabled => DevpushError::new(ErrorCode::DeveloperModeRequired, text),
            E::ServiceNotFound => DevpushError::new(ErrorCode::ContainerUnavailable, text),
            E::Socket(io_err) => {
                let kind = io_err.kind();
                if matches!(
                    kind,
                    std::io::ErrorKind::ConnectionRefused
                        | std::io::ErrorKind::NotFound
                        | std::io::ErrorKind::ConnectionReset
                ) {
                    DevpushError::new(ErrorCode::UsbmuxdUnavailable, text)
                } else {
                    DevpushError::new(ErrorCode::IoError, text)
                }
            }
            _ => {
                let lower = text.to_ascii_lowercase();
                let code = if lower.contains("pair") || lower.contains("trust") {
                    ErrorCode::PairingRequired
                } else if lower.contains("locked") || lower.contains("passcode") {
                    ErrorCode::DeviceLocked
                } else if lower.contains("usbmux") {
                    ErrorCode::UsbmuxdUnavailable
                } else if lower.contains("not found") {
                    ErrorCode::PathNotFound
                } else if lower.contains("no space") {
                    ErrorCode::AfcError
                } else if lower.contains("developer mode") {
                    ErrorCode::DeveloperModeRequired
                } else {
                    ErrorCode::IoError
                };
                DevpushError {
                    code,
                    message: text,
                    detail: None,
                    afc_code: None,
                }
            }
        }
    }
}

impl std::fmt::Display for DevpushError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code.as_str(), self.message)
    }
}

impl std::error::Error for DevpushError {}
