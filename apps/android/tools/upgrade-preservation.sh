#!/usr/bin/env bash
# Installs an older debug build, seeds fixture data, updates the package in place with
# a newer build signed by the same key, then checks in the new version's process that
# the Keystore session, preferences, the downloaded book and its queued place survived.
#
# Needs a running EMULATOR (it uninstalls org.shelfarr.app.debug first, which would
# erase a real phone's data), git history, the Android SDK and JDK 17+. The baseline
# is the published v3 source, before discovery and centralized storage names. Both
# builds use this machine's debug key, so they update each other as published builds do.
#
#   apps/android/tools/upgrade-preservation.sh [new_version_code]
set -euo pipefail
cd "$(dirname "$0")/.."

old_code=3
new_code="${1:-4}"
baseline_ref=1b99abe3f3f73c79aa6ba86d42c1458678cad98f
if [[ ! "$new_code" =~ ^[0-9]+$ ]] || (( new_code <= old_code || new_code > 2100000000 )); then
  echo "The new version code must be an integer above $old_code and at most 2100000000." >&2
  exit 2
fi
package=org.shelfarr.app.debug
runner="$package.test/androidx.test.runner.AndroidJUnitRunner"
out="app/build/reports/upgrade-preservation"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

if [[ "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" != "1" && "$(adb shell getprop ro.boot.qemu | tr -d '\r')" != "1" ]]; then
  echo "Refusing: this test uninstalls $package first. Use an emulator." >&2
  exit 2
fi

scratch_root="${TMPDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/shelfarr-upgrade-tests}"
mkdir -p "$scratch_root"
baseline_dir="$(mktemp -d "$scratch_root/shelfarr-upgrade.XXXXXXXX")"
trap 'rm -rf -- "$baseline_dir"' EXIT
repo_root="$(git rev-parse --show-toplevel)"
git -C "$repo_root" archive "$baseline_ref" apps/android apps/design | tar -x -C "$baseline_dir"
(
  cd "$baseline_dir/apps/android"
  ./gradlew --no-daemon -q :app:assembleDebug \
    -PshelfarrVersionCode="$old_code" -PshelfarrVersionName=0.1.2
  cp app/build/outputs/apk/debug/app-debug.apk "$out/old.apk"
)
./gradlew --no-daemon -q :app:assembleDebug :app:assembleDebugAndroidTest \
  -PshelfarrVersionCode="$new_code" -PshelfarrVersionName="0.0.$new_code"
cp app/build/outputs/apk/debug/app-debug.apk "$out/new.apk"
cp app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk "$out/test.apk"

instrument() {
  # One stage per run. am instrument exits 0 even when a test fails or is skipped,
  # so require a pass with no assumption failure.
  local stage="$1"
  shift
  local log="$out/$stage.txt"
  adb shell am instrument -w -r -e shelfarrUpgradeStage "$stage" "$@" \
    -e class "org.shelfarr.app.upgrade.UpgradePreservationTest#$stage" "$runner" | tee "$log"
  grep -q "^OK (1 test)" "$log" || { echo "Stage $stage failed: $log" >&2; exit 1; }
  if grep -q "AssumptionViolatedException" "$log"; then echo "Stage $stage was skipped: $log" >&2; exit 1; fi
}

adb logcat -c || true
adb uninstall "$package" > /dev/null 2>&1 || true
adb uninstall "$package.test" > /dev/null 2>&1 || true
adb install "$out/old.apk"
adb install "$out/test.apk"
adb shell dumpsys package "$package" | grep -E "versionCode|firstInstallTime|lastUpdateTime" | tee "$out/package-before.txt"

instrument seed

# An in-place update through PackageInstaller (adb streams the APK into an install
# session); the same signing key, so Android keeps the app's data.
adb install -r "$out/new.apk"
adb shell dumpsys package "$package" | grep -E "versionCode|firstInstallTime|lastUpdateTime" | tee "$out/package-after.txt"

instrument verify -e shelfarrExpectVersionCode "$new_code" -e shelfarrUpgradeCleanup true
adb logcat -d > "$out/logcat.txt" || true
echo "Upgrade preservation passed: $out"
