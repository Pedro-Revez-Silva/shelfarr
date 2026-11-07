#!/usr/bin/env bash
# Runs the iOS app on a simulator against a local fixture server and drives it with
# XCUITest: library and search, details, a rendered EPUB, downloads through the system
# background session, a local audiobook, reopening everything offline, the activity
# time sent with progress, a silent reader reopen and the audiobook resume rewind.
#
# Needs macOS, Xcode 16.4+, XcodeGen and python3.
#
#   apps/scripts/ios-runtime-smoke.sh [--device iphone|ipad|all] [xcodebuild args...]
#
# --device (or SHELFARR_SMOKE_DEVICE) picks the simulator family; the default is iphone,
# and all runs iPhone then iPad. Each family uses the newest available simulator whose
# iOS runtime the selected SDK supports, unless IOS_SIMULATOR_UDID (single family only)
# names one. Extra arguments go to xcodebuild, e.g.
#   apps/scripts/ios-runtime-smoke.sh --device ipad -only-testing:ShelfarrUITests/RuntimeSmokeTests
#
# A simulator this script had to boot is shut down again when it finishes; one that was
# already booted (yours, or another run's) is left running.
#
# Results, per family (iphone or ipad):
#   apps/ios/build/runtime-smoke/<family>/   RuntimeSmoke.xcresult, screenshots in
#                                            attachments/, xcodebuild, fixture server and
#                                            simulator logs, device.json
#   apps/ios/test-results/runtime-smoke/<family>/summary.json
# Fails unless, for every family run, at least one test ran and none failed.
#
# Families can run in parallel only with distinct SHELFARR_SMOKE_DERIVED_DATA paths;
# their fixture ports already differ (iPhone 8765/8766, iPad 8775/8776, overridable with
# SHELFARR_SMOKE_PORT and SHELFARR_SMOKE_CONTROL_PORT for a single family).
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/../ios"

device="${SHELFARR_SMOKE_DEVICE:-iphone}"
if [ "${1:-}" = "--device" ]; then
  device="${2:?--device needs iphone, ipad or all}"
  shift 2
fi
case "$device" in
  iphone|ipad) ;;
  all)
    if [ -n "${IOS_SIMULATOR_UDID:-}" ]; then
      echo "IOS_SIMULATOR_UDID names one simulator; use it with --device iphone or ipad" >&2
      exit 2
    fi
    # One process per family: its own server, simulator ownership and strict errors.
    overall=0
    for family in iphone ipad; do
      env -u SHELFARR_SMOKE_PORT -u SHELFARR_SMOKE_CONTROL_PORT -u SHELFARR_SMOKE_DEVICE \
        "$script" --device "$family" "$@" || overall=1
    done
    exit "$overall"
    ;;
  *) echo "Unknown device family '$device' (use iphone, ipad or all)" >&2; exit 2 ;;
esac

derived="${SHELFARR_SMOKE_DERIVED_DATA:-build}"
xcodegen generate
sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"

# Prints the UDID of the newest available simulator of a family supported by the SDK.
pick_simulator() {
  xcrun simctl list devices available --json | python3 -c '
import json, re, sys
family, sdk_text = sys.argv[1], sys.argv[2]
prefix = {"iphone": "iPhone", "ipad": "iPad"}[family]
runtimes = json.load(sys.stdin)["devices"]
sdk = tuple((list(map(int, sdk_text.split("."))) + [0, 0])[:3])
def version(key):
    found = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?$", key)
    return tuple(int(part or 0) for part in found.groups()) if found else None
best = None
for key, devices in runtimes.items():
    v = version(key)
    if v is None or v > sdk:
        continue
    for device in devices:
        name = device["name"]
        if not device.get("isAvailable") or not name.startswith(prefix):
            continue
        # Prefer full-size models: no iPhone SE, no iPad mini.
        rank = (v, device.get("state") == "Booted", "SE" not in name and "mini" not in name)
        if best is None or rank > best[0]:
            best = (rank, device["udid"], name, key)
if best is None:
    sys.exit(f"No available {prefix} simulator supported by iOS SDK {sdk_text}")
print(best[1])
print(f"Using {best[2]} ({best[3]})", file=sys.stderr)
' "$1" "$sdk_version"
}

family="$device"
out="build/runtime-smoke/$family"
results="test-results/runtime-smoke/$family"
summary="$results/summary.json"
default_port=8765 default_control=8766
if [ "$family" = ipad ]; then default_port=8775; default_control=8776; fi
port="${SHELFARR_SMOKE_PORT:-$default_port}"
control_port="${SHELFARR_SMOKE_CONTROL_PORT:-$default_control}"

rm -rf "$out" "$results"
mkdir -p "$out" "$results"

udid="${IOS_SIMULATOR_UDID:-}"
[ -n "$udid" ] || udid="$(pick_simulator "$family")"

# Boot only when needed, and remember whether this run did it: only then is the
# simulator shut down afterwards. `simctl boot` fails for a device already booted.
booted_here=0
server_pid=""
# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  if [ "$booted_here" -eq 1 ]; then
    xcrun simctl shutdown "$udid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
if xcrun simctl boot "$udid" 2>/dev/null; then booted_here=1; fi
xcrun simctl bootstatus "$udid" -b
xcrun simctl list devices --json | python3 -c '
import json, sys
udid, family, sdk, booted = sys.argv[1:5]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for device in devices:
        if device["udid"] == udid:
            json.dump({"family": family, "name": device["name"], "udid": udid, "runtime": runtime,
                       "sdk": sdk, "booted_by_script": booted == "1"}, sys.stdout, indent=2)
' "$udid" "$family" "$sdk_version" "$booted_here" > "$out/device.json" || true

python3 -B RuntimeSmoke/smoke_server.py --port "$port" --control-port "$control_port" > "$out/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:$control_port/stats" > /dev/null 2>&1 && break
  sleep 0.2
done
curl -fsS "http://127.0.0.1:$control_port/stats" > /dev/null

status=0
# The download daemon identifies its client through the code signature. Ad-hoc
# signing works on the simulator without a developer account; an unsigned build
# launches, but nsurlsessiond rejects it as having no bundle ID.
TEST_RUNNER_SHELFARR_SMOKE_PORT="$port" \
TEST_RUNNER_SHELFARR_SMOKE_CONTROL_PORT="$control_port" \
xcodebuild test \
  -project Shelfarr.xcodeproj \
  -scheme ShelfarrRuntimeSmoke \
  -configuration Debug \
  -destination "id=$udid" \
  -derivedDataPath "$derived" \
  -resultBundlePath "$out/RuntimeSmoke.xcresult" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  "$@" 2>&1 | tee "$out/xcodebuild.log" || status=$?

# Diagnostics are kept whether or not the tests passed.
curl -fsS "http://127.0.0.1:$control_port/stats" > "$out/server-stats.json" 2>/dev/null || true
xcrun simctl spawn "$udid" log show --style compact --last 20m \
  --predicate 'process == "Shelfarr" OR process == "nsurlsessiond"' > "$out/device.log" 2>/dev/null || true
if [ -d "$out/RuntimeSmoke.xcresult" ]; then
  xcrun xcresulttool export attachments --path "$out/RuntimeSmoke.xcresult" --output-path "$out/attachments" \
    || echo "warning: could not export screenshots from the result bundle"
  xcrun xcresulttool get test-results summary --path "$out/RuntimeSmoke.xcresult" > "$summary" \
    || echo "warning: could not summarise the result bundle"
fi

if [ "$status" -eq 0 ]; then
  # A green build with no executed test is a failure, not a pass.
  python3 - "$summary" "$family" <<'PY' || status=1
import json, sys
try:
    summary = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit("No readable test summary")
passed = summary.get("passedTests", 0)
failed = summary.get("failedTests", 0)
skipped = summary.get("skippedTests", 0)
print(f"Runtime smoke ({sys.argv[2]}): {passed} passed, {failed} failed, {skipped} skipped, result {summary.get('result')}")
if summary.get("result") != "Passed" or passed == 0 or failed:
    sys.exit(1)
PY
fi
exit "$status"

