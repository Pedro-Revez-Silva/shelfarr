#!/usr/bin/env bash
# Needs a running emulator or connected test device, Android SDK and JDK 17+.
set -euo pipefail
cd "$(dirname "$0")/../android"

adb logcat -c
smoke_status=0
./gradlew --no-daemon :app:connectedDebugAndroidTest || smoke_status=$?

# Keep diagnostics even when instrumentation or the app process failed.
mkdir -p app/build/reports/reader-smoke
adb logcat -d > app/build/reports/reader-smoke/logcat.txt || true
adb pull /sdcard/Android/data/org.shelfarr.app.debug/files/reader-smoke app/build/reports/reader-smoke/screens || true
exit "$smoke_status"
