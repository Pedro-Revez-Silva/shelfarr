#!/usr/bin/env bash
# Needs a running emulator, Android SDK and JDK 17+. Fixture tests replace the
# signed-in session and remove fixture files; never run them on a personal phone.
set -euo pipefail
cd "$(dirname "$0")/../android"

if [[ "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" != "1" && "$(adb shell getprop ro.boot.qemu | tr -d '\r')" != "1" ]]; then
  echo "Refusing fixture instrumentation on a physical or unidentified device. Use an emulator; follow the physical-device acceptance guide for a personal phone." >&2
  exit 2
fi

adb logcat -c
smoke_status=0
./gradlew --no-daemon :app:connectedDebugAndroidTest || smoke_status=$?

# Keep diagnostics even when instrumentation or the app process failed.
mkdir -p app/build/reports/reader-smoke
adb logcat -d > app/build/reports/reader-smoke/logcat.txt || true
exit "$smoke_status"
