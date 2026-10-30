#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build/module-cache dist
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Core.swift Tests/main.swift -o .build/self-test
.build/self-test
STAGE=$(mktemp -d /private/tmp/spotlight-uninstall.XXXXXX)
APP="$STAGE/聚焦卸载.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Assets/GitHub-Mark.png LICENSE Assets/NOTICE.md "$APP/Contents/Resources/"
xcrun swiftc -swift-version 5 -O -module-cache-path .build/module-cache -target arm64-apple-macos26.0 Sources/Core.swift Sources/PermissionsWindow.swift Sources/main.swift -o "$APP/Contents/MacOS/SpotlightUninstall"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.vinasky.spotlight-uninstall</string>
<key>CFBundleName</key><string>聚焦卸载</string>
<key>CFBundleDisplayName</key><string>聚焦卸载</string>
<key>CFBundleExecutable</key><string>SpotlightUninstall</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSAccessibilityUsageDescription</key><string>读取系统聚焦的 App 结果，在旁边显示卸载按钮。</string>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto --norsrc --noextattr -c -k --sequesterRsrc --keepParent "$APP" dist/SpotlightUninstall-1.0.0-arm64.zip
print -r -- "$APP" > .build/app-path
print -r -- "Built: $APP"
