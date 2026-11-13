#!/usr/bin/env bash
# Core tests and a simulator build of the iOS app. Needs macOS, Xcode 16.4+ and
# XcodeGen (see docs/native-consumer.md).
set -euo pipefail
cd "$(dirname "$0")/../ios"

(cd ShelfarrCore && swift test)

xcodegen generate
destination="${IOS_DESTINATION:-generic/platform=iOS Simulator}"
xcodebuild \
  -project Shelfarr.xcodeproj \
  -scheme Shelfarr \
  -configuration Debug \
  -destination "$destination" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build
