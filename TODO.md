# Project TODO

This file tracks behaviour seen in the reference emulator that 3ds2apple does
not support yet. Only its layout/interaction ideas were studied; no GPL code or
text is copied, and no game assets are stored in the repository.

## Settings / in-game menu (reference-emulator items not implemented)

- [ ] Controller skin selection (on-screen button skin assets) - the app ships
      one fixed skin; the reference app can import Delta-style skins.
- [ ] Cheat code manager (the reference app's "金手指" page) - not implemented.
- [ ] Game manual viewer - not implemented.
- [ ] Amiibo loading/simulation in the in-game menu - not shown as a fake row.
- [ ] Cheat manager in the in-game menu - the Debug page has no cheat UI.
- [ ] Multiplayer / online play - not implemented (no network features).
- [ ] Screen-rotation quick toggle inside the in-game menu (Settings -> Graphics
      -> Screen rotation exists instead).
- [ ] Dead-zone configuration UI, controller remapping and per-game controller
      profiles.
- [ ] Amiibo loading/simulation - not implemented.
- [ ] Simulated blow/microphone input - not implemented.
- [ ] AirPlay scaling/layout options - iOS handles external display output
      through the system; the app does not expose these options.
- [ ] Per-game settings overrides (global settings only today).
- [ ] In-game menu artwork/skin theming.
- [ ] Reference-emulator percentage speed limit (e.g. 150%): the runtime now has
      real unlimited speed (Run speed limit off / Turbo limit off), but the
      "limit to a chosen percentage" control is not implemented.
- [x] Update channel (Stable/Beta) and daily background update notifications
      (UpdateChecker; local notification via UNUserNotificationCenter).
- [ ] Hide 3DS images from the Android gallery (Android-only feature; iOS has no
      equivalent).
- [ ] Camera and Network settings categories.

## Already supported

- iOS 26/27 grouped Settings and in-game menu style (inset-grouped cards, system
  semantic colours, light/dark follows the system, tap-outside-to-resume).
- Custom screen layouts, screen rotation, swap screens, integer scaling,
  screen aspect, resolution, fast-forward, quick save/load, save manager,
  diagnostics export, on-screen control layout editing.