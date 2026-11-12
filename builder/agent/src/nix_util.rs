//! Process-group and filesystem helpers built on `nix` so the Agent contains
//! no hand-written `unsafe` code.

use std::path::Path;

pub use nix::sys::signal::Signal;

/// Terminate every process in a process group.
pub fn signal_process_group(pgid: i32, signal: Signal) -> Result<(), String> {
    nix::sys::signal::killpg(nix::unistd::Pid::from_raw(pgid), signal)
        .map_err(|error| format!("could not signal process group {pgid}: {error}"))
}

/// Whether any process in the group still exists.
#[allow(dead_code)]
pub fn process_group_exists(pgid: i32) -> bool {
    nix::sys::signal::killpg(
        nix::unistd::Pid::from_raw(pgid),
        None::<nix::sys::signal::Signal>,
    )
    .is_ok()
}

/// Free bytes available to the current user on the filesystem holding `path`.
pub fn free_disk_bytes(path: &Path) -> Option<u64> {
    let stats = nix::sys::statvfs::statvfs(path).ok()?;
    let available = stats.blocks_available() as u64;
    let fragment = stats.fragment_size() as u64;
    Some(available.saturating_mul(fragment))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn free_disk_is_reported_for_temp() {
        let dir = tempfile::tempdir().unwrap();
        let free = free_disk_bytes(dir.path()).expect("statvfs should work");
        assert!(free > 0);
    }

    #[test]
    fn current_process_group_exists() {
        // Our own process group id is the pid when the test runner owns it; just
        // check the probe does not panic and treats a bogus group as absent.
        assert!(!process_group_exists(2_147_483_000));
    }
}
