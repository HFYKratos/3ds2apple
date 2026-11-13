# UI snapshots (QA)

Headless Mac Catalyst snapshots of the real SwiftUI shell, rendered by
`ios/preview/` (see `scripts/ios-ui-preview.sh` and `ios/preview/README.md`).
No game content: the covers are generated placeholders and the library entries
are synthetic (Pokemon Y / Alpha Sapphire / Mario Land).

Regenerate on the macOS VM (no iOS Simulator needed):

```bash
PATH=/usr/local/bin:$PATH xcodebuild -project ios/preview/build/3ds2apple-preview.xcodeproj \
  -scheme 3ds2apple-preview -destination "platform=macOS,variant=Mac Catalyst" \
  -configuration Debug -derivedDataPath ios/preview/build/DerivedData build
# English:
APP=ios/preview/build/DerivedData/Build/Products/Debug-maccatalyst/3ds2apple-preview.app
ZKPREVIEW_SHOT_DIR=/tmp/ui-shots "$APP/Contents/MacOS/3ds2apple-preview"
# Chinese:
ZKPREVIEW_SHOT_DIR=/tmp/ui-shots-zh "$APP/Contents/MacOS/3ds2apple-preview" -AppleLanguages "(zh-Hans)"
```

The images here were taken for v0.1.4 (2026-11-14).