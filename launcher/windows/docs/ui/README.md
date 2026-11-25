# Windows launcher UI evidence (0.2.1)

These renders are the 0.2.1 Windows launcher UI smoke evidence. They were captured on Linux/Xvfb
from the 0.2.1 launcher build with its developer-only --ui-smoke mode and a synthetic fixture
(empty library, or the built-in synthetic demo entries for the deploy/settings views). No ROM,
real game icon, real game title or game data is stored in this repository.

Files:

- v4-library-en.png — Library, English: empty synthetic library in the 0.2.1 UI.
- v4-library-zh.png — Library, zh-Hans: empty synthetic library, Chinese UI strings.
- v4-library-portable-en.png — Library with the default portable workspace (no env override).
- v4-deploy-en.png — Deploy, English: the 0.2.1 deploy screen with the synthetic selection.
- v4-deploy-zh.png — Deploy, zh-Hans.
- v4-settings-en.png — Settings, English.
- v4-settings-portable-en.png — Settings, English: portable games/state and tools folder reasons.

The previous 0.1.0 v4 renders and the first-run migration render were replaced or removed in the
0.2.1 media refresh. The render command is:

    cd launcher/windows
    export DOTNET_ROOT=$HOME/.dotnet10
    dotnet build src/Launcher.Desktop/ThreeDsTwoApple.Launcher.Desktop.csproj -c Release
    THREEDS2APPLE_UI_SMOKE_VIEW=library     THREEDS2APPLE_UI_SMOKE_SHOT=/tmp/library.png       xvfb-run -a src/Launcher.Desktop/bin/Release/net10.0/3ds2apple-launcher --ui-smoke

These are development renders; a real Windows 11 run and device acceptance still need a Windows
PC and an iPhone/iPad (see launcher/windows/README.md).
