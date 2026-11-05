#!/bin/zsh
# Builds K10 Battery.app next to this script.
set -euo pipefail
cd "${0:A:h}"
APP="K10 Battery.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework IOKit -framework SwiftUI -framework ServiceManagement -framework UserNotifications \
  Sources/*.swift -o "$APP/Contents/MacOS/K10Battery"
# Sign with an Apple Development identity if one exists, so the Input Monitoring
# permission survives rebuilds (ad-hoc signatures change with every build).
ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --sign "${ID:--}" "$APP"
echo "Built $PWD/$APP"
