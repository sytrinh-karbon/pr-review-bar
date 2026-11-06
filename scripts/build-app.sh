#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

app="build/PR Review Bar.app"

swift build -c release
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/PRReviewBar" "$app/Contents/MacOS/"
cp App/Info.plist "$app/Contents/"
codesign --force --sign - "$app"

echo "Built $app"
