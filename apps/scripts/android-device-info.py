#!/usr/bin/env python3
"""Collect read-only Android acceptance metadata, without app data or device serials."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


class DeviceInfoError(Exception):
    pass


def adb(executable, *args):
    try:
        result = subprocess.run([executable, *args], capture_output=True, timeout=20, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise DeviceInfoError("ADB could not complete the read-only query") from None
    if result.returncode or len(result.stdout) > 2 * 1024 * 1024:
        raise DeviceInfoError("ADB could not read the device; check its USB authorization and connection")
    try:
        return result.stdout.decode("utf-8").replace("\r", "")
    except UnicodeError:
        raise DeviceInfoError("The device returned unreadable metadata") from None


def collect(executable, package, serial=None):
    if not re.fullmatch(r"[A-Za-z]\w*(?:\.[A-Za-z]\w*){1,20}", package, flags=re.ASCII) or len(package) > 200:
        raise DeviceInfoError("Choose a valid Android package identifier")
    online = [parts[0] for line in adb(executable, "devices").splitlines()
              if len(parts := line.split()) == 2 and parts[1] == "device"]
    if serial:
        if serial not in online:
            raise DeviceInfoError("The selected device is not online and authorized")
    elif len(online) == 1:
        serial = online[0]
    else:
        raise DeviceInfoError("Connect one authorized device, or select it with --serial")

    def read(*args):
        return adb(executable, "-s", serial, *args)

    def prop(name):
        value = read("shell", "getprop", name).strip()
        if len(value) > 512 or any(ord(c) < 32 for c in value):
            raise DeviceInfoError("The device returned malformed property metadata")
        return value

    hardware = prop("ro.hardware")
    kernel_qemu, boot_qemu = prop("ro.kernel.qemu"), prop("ro.boot.qemu")
    if "1" in (kernel_qemu, boot_qemu) or hardware in ("ranchu", "goldfish") or serial.startswith("emulator-"):
        kind = "emulator"
    elif hardware:
        kind = "physical"
    else:
        kind = "unknown"

    details = read("shell", "dumpsys", "package", package)
    code = re.search(r"\bversionCode=(\d+)", details)
    version = re.search(r"\bversionName=([^\s]+)", details)
    if not code or not version:
        raise DeviceInfoError("The selected Shelfarr package is not installed or its version is unavailable")

    def install_time(field):
        match = re.search(rf"^\s*{field}=([^\n]+)$", details, flags=re.MULTILINE)
        return match.group(1).strip() if match else None

    return {
        "schema_version": 1, "collected_at": datetime.now(timezone.utc).isoformat(),
        "device_ref": hashlib.sha256(serial.encode()).hexdigest(),
        "device_kind": kind, "device_kind_basis": "ADB emulator properties and hardware identity",
        "manufacturer": prop("ro.product.manufacturer"), "model": prop("ro.product.model"),
        "android_version": prop("ro.build.version.release"), "api_level": prop("ro.build.version.sdk"),
        "app": {"package_name": package, "version_code": int(code.group(1)), "version_name": version.group(1),
                "first_install_time": install_time("firstInstallTime"), "last_update_time": install_time("lastUpdateTime")},
        "behavioral_tests_executed": [], "collection_only": True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default=shutil.which("adb") or "adb")
    parser.add_argument("--serial", help="Select a device when more than one is connected; not stored in the report")
    parser.add_argument("--package", default="org.shelfarr.app.debug")
    parser.add_argument("--output", required=True, type=Path, help="New private JSON file outside the source tree")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        report = collect(args.adb, args.package, args.serial)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("x", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2)
            handle.write("\n")
        print(json.dumps({"report": str(args.output), "device_kind": report["device_kind"],
                          "version_name": report["app"]["version_name"], "behavioral_tests_executed": []}))
        return 0
    except FileExistsError:
        print("Choose a new output file; previous acceptance evidence was not replaced", file=sys.stderr)
    except (DeviceInfoError, OSError) as error:
        print(str(error) if isinstance(error, DeviceInfoError) else "Could not write the private evidence file", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
