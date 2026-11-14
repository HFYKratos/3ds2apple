# sim-probe — dlopen a cross-built GamePack inside the iOS Simulator

Part of 3ds2apple (Apache-2.0). Reference-only host app for proving the
no-Apple-SDK LLVM/LLD GamePack path end to end on the build VM.

`main.c` is a tiny iOS Simulator app that:

1. `dlopen()`s a GamePack dylib passed via `SIMCTL_CHILD_GAMEPACK_PATH`,
2. `dlsym()`s `zk_gamepack_title_id` / `zk_gamepack_abi_version` /
   `zk_gamepack_register`,
3. defines the host-side `zk_register_gamepack` C ABI (what libzakuro_ios_sim.a
   provides in the real app) and records the forwarded recomp tables,
4. asserts title ID, GamePack ABI 1, registration return codes, host callback
   arguments and rejection of a mismatched host ABI; exits 0 only if all pass.

`run-sim-probe.sh` builds the app with Xcode on the macOS VM (the host app is
reference tooling; the GamePack under test is built by
`tools/winbuild/build-gamepack.sh --target sim` with LLVM/LLD and no Apple SDK),
embeds the pack in `Frameworks/`, boots the iPhone 17 Pro simulator, installs,
launches with `--console-pty` and shuts the simulator down afterwards.

## Result (2026-11-14, task-22)

PASS on the full 270 MB Pokemon Y simulator pack built on Linux with LLVM
21.1.8 + `ld64.lld` (`sha256 41a470ea...03162`):

```text
result: ok   dlopen
result: info pack title_id=0004000000055e00 pack_abi=1
result: info register title=0004000000055e00 recomp_abi=5 generation=5 entries=1 modules=1
result: info zk_gamepack_register(1) = 0
result: ok   host zk_register_gamepack called exactly once
result: summary failures=0
== probe exit status: 0
```

Also PASS on a 13 KB stand-in pack (machinery check). The simulator is shut
down by the script when it finishes; pass `--keep-booted` to keep it up.

## Usage (on the macOS build VM, repo root)

```sh
tools/winbuild/sim-probe/run-sim-probe.sh <GamePack-0004000000055E00-sim.dylib>
# optional: --udid <UDID> --keep-booted
```

Requires Xcode 26.6 / iOS 26.5 simulator, xcrun, and a booted-capable Intel or
Apple-silicon simulator (the VM used x86_64). No Apple SDK is needed on the
machine that built the pack.