# Project TODO

This file tracks behaviour seen in the reference emulator that 3ds2apple does
not support yet. Only its layout/interaction ideas were studied; no GPL code or
text is copied, and no game assets are stored in the repository.

## 0.2.0 — implemented

- [x] iOS 26/27 grouped Settings and in-game menu style (inset-grouped cards,
      system semantic colours, light/dark follows the system, tap-outside-to-
      resume, gear button, inline sub-page titles and single disclosure arrows).
- [x] In-game menu options: Save state, Virtual controls, Screen layout,
      Swap screens, Rotate screen, Global Settings, Per-Application Settings
      and Close game. Save Manager / Export logs remain in Settings/Debug.
- [x] Real unlimited run speed: Run speed limit off, Turbo limit off, 60 Hz
      frame budget, audio muted, high-power warning. Default/Turbo fixed speeds
      remain 1×–4×.
- [x] Update channel Stable/Beta, single GitHub check, daily background check
      and local notification via UNUserNotificationCenter.
- [x] Analog deadzone for on-screen/physical sticks; physical controller button
      remapping with reset; built-in Standard/High contrast control appearances;
      per-app Gamepad profiles.
- [x] Physical-controller 2–4 button hotkeys for Toggle Turbo, Quick save/load,
      Swap screens, Rotate screen and Open menu, with live recording, presets,
      persistence and reset.
- [x] Per-game presentation overrides keyed by title ID.

## 0.2.0 — remaining, requires emulator-core work (not UI-only)

- [ ] Delta-style controller skin import (custom button art). The app ships
      built-in Standard/High contrast appearances; importing external skin
      packs needs a skin format, asset loader and layout mapping.
- [ ] Cheat code manager (Action Replay/memory patch engine).
- [ ] Game manual viewer (requires manual documents and a viewer).
- [ ] Amiibo loading/simulation (NFC/amiibo service in the emulator core).
- [ ] Simulated blow/microphone input (microphone capture into the HLE).
- [ ] Camera source/flip settings (camera emulation layer).
- [ ] Network / online multiplayer and Web API settings (network service layer).
- [ ] CPU JIT / shader JIT / RPC / LLE module settings (project is AOT-only by
      design; these would require a different execution architecture).
- [ ] AirPlay external-display layout options: iOS owns external display
      presentation; the app does not expose a custom external-screen UI.
- [ ] Hide 3DS images from the Android gallery: Android-only; no iOS equivalent.

## Optional / future UI polish

- [ ] In-game menu artwork/skin theming (the current menu intentionally follows
      the iOS system appearance; the user requested no game header).
- [ ] Reference-emulator percentage speed limit (e.g. 150%). The runtime now
      supports fixed 1×–4× and true unlimited speed; arbitrary percentages
      would need fractional-speed scheduling.
