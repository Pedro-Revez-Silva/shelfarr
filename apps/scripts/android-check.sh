#!/usr/bin/env bash
# Unit, screenshot-render, lint and debug build checks for the Android app.
# Needs JDK 17+ and an Android SDK (see docs/native-consumer.md).
set -euo pipefail
cd "$(dirname "$0")/../android"
./gradlew --no-daemon \
  :app:testDebugUnitTest \
  :app:lintDebug \
  :app:assembleDebug \
  -Proborazzi.test.record=true
echo "Debug APK: $(pwd)/app/build/outputs/apk/debug/app-debug.apk"
echo "Rendered screens: $(pwd)/app/build/screenshots"
