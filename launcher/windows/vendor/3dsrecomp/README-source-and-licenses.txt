3dsrecomp (Windows build) — provenance note
=============================================

This launcher bundles a 3dsrecomp.exe built from the upstream project
https://github.com/fearkov/3dsrecomp (pinned working revision used by this repo,
third_party/3dsrecomp) for the x86_64-pc-windows-gnu target.

The upstream repository does not publish a LICENSE file. The binary is included
only as a build-time tool (ROM -> generated C) for the user's own ROMs; it is not
part of the runtime that ships to the phone and no upstream source is vendored in
this repository. The generated C and all intermediate files stay in the launcher
workspace. If the upstream project publishes a licence, its terms govern this
binary and this note must be replaced by the upstream licence text.

Do not redistribute this binary together with game data.
