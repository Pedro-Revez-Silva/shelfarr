#!/usr/bin/env python3
"""Writes the in-app update feed (schema 1) for a signed Android APK.

The APK is checked first: its signature with apksigner, its package, version and
minimum SDK with aapt2. Nothing is uploaded; publish the APK, then the feed, to the
directory the app was built to trust. Needs ANDROID_HOME (build-tools) and java.

Example:
  apps/scripts/android-update-manifest.py \\
    --apk app-debug.apk \\
    --feed-url https://example.org/downloads/android-development.json \\
    --apk-url https://example.org/downloads/shelfarr-android-development-3.apk \\
    --channel development --package org.shelfarr.app.debug \\
    --signer-sha256 <64 hex> --previous-version-code 2 \\
    --notes-file notes.txt --output android-development.json
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

MAX_APK_BYTES = 256 * 1024 * 1024
MAX_NOTES_CHARS = 4000
MAX_VERSION_CODE = 2_100_000_000
VERSION_NAME = re.compile(r"[0-9A-Za-z][0-9A-Za-z._+-]{0,63}")
BAD_URL_TEXT = re.compile(r"[\\@#?\s]|%2e|%2f|%5c|%00|%40|%23|%3f", re.IGNORECASE)


def fail(message: str) -> None:
    sys.exit(f"error: {message}")


def build_tool(name: str) -> str:
    home = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not home:
        fail("set ANDROID_HOME to an Android SDK with build-tools")
    def version(path: Path) -> list:
        return [(0, int(x), "") if x.isdigit() else (1, 0, x) for x in re.split(r"[.-]", path.parent.name)]

    tools = sorted(Path(home, "build-tools").glob("*/" + name), key=version)
    if not tools:
        fail(f"no {name} under {home}/build-tools")
    return str(tools[-1])


def run(command: list) -> str:
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"{Path(command[0]).name} failed: {(result.stderr or result.stdout).strip()[:500]}")
    return result.stdout


def check_url(url: str, feed: str, suffix: str) -> tuple:
    if BAD_URL_TEXT.search(url):
        fail(f"{url} must not contain credentials, a query, a fragment or encoded separators")
    parts = urlsplit(url)
    if parts.scheme != "https" or not parts.hostname:
        fail(f"{url} must be an absolute https URL")
    segments = parts.path.split("/")[1:]
    if any(s in ("", ".", "..") for s in segments) or not parts.path.endswith(suffix):
        fail(f"{url} must be a clean path ending in {suffix}")
    if feed:
        base = urlsplit(feed)
        directory = base.path.rsplit("/", 1)[0] + "/"
        if (parts.scheme, parts.hostname, parts.port) != (base.scheme, base.hostname, base.port):
            fail("the APK must be on the feed's origin")
        if not parts.path.startswith(directory):
            fail(f"the APK must be inside the feed's directory, {directory}")
    return parts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--feed-url", required=True, help="the shelfarrUpdateFeedUrl the app was built with")
    parser.add_argument("--apk-url", required=True, help="where the APK will be published, inside the feed's directory")
    parser.add_argument("--channel", default="development", choices=["development", "release"])
    parser.add_argument("--package", required=True, help="expected application ID, e.g. org.shelfarr.app.debug")
    parser.add_argument("--signer-sha256", help="expected signing certificate SHA-256 (recommended)")
    parser.add_argument("--previous-version-code", type=int, help="the version code currently published; the new one must be larger")
    parser.add_argument("--notes-file", type=Path, help="plain-text release notes, at most 4000 characters")
    parser.add_argument("--output", type=Path, help="write here instead of stdout")
    args = parser.parse_args()

    check_url(args.feed_url, "", ".json")
    check_url(args.apk_url, args.feed_url, ".apk")

    apk = args.apk
    size = apk.stat().st_size
    if not 0 < size <= MAX_APK_BYTES:
        fail(f"APK size {size} is outside 1..{MAX_APK_BYTES}")

    signers = run([build_tool("apksigner"), "verify", "--print-certs", str(apk)])
    digests = sorted(set(re.findall(r"certificate SHA-256 digest: ([0-9a-f]{64})", signers)))
    if not digests:
        fail("apksigner reported no signer")
    if args.signer_sha256 and digests != [args.signer_sha256.lower()]:
        fail(f"APK is signed by {', '.join(digests)}, not the expected certificate")

    badging = run([build_tool("aapt2"), "dump", "badging", str(apk)])
    package = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']*)'", badging, re.MULTILINE)
    if not package:
        fail("aapt2 could not read the package line")
    name, code, version_name = package.group(1), int(package.group(2)), package.group(3)
    min_sdk = re.search(r"^(?:minSdkVersion|sdkVersion):'(\d+)'", badging, re.MULTILINE)
    if name != args.package:
        fail(f"APK package is {name}, expected {args.package}")
    if not 1 <= code <= MAX_VERSION_CODE:
        fail(f"version code {code} is out of range")
    if args.previous_version_code is not None and code <= args.previous_version_code:
        fail(f"version code {code} must be larger than the published {args.previous_version_code}")
    if not VERSION_NAME.fullmatch(version_name):
        fail(f"version name {version_name!r} is not usable")

    notes = None
    if args.notes_file:
        notes = args.notes_file.read_text(encoding="utf-8").replace("\r\n", "\n").strip()
        if len(notes) > MAX_NOTES_CHARS:
            fail(f"release notes are longer than {MAX_NOTES_CHARS} characters")

    digest = hashlib.sha256()
    with apk.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)

    feed = {
        "schema_version": 1,
        "channel": args.channel,
        "package_name": name,
        "version_code": code,
        "version_name": version_name,
        "apk_url": args.apk_url,
        "size_bytes": size,
        "sha256": digest.hexdigest(),
    }
    if notes:
        feed["release_notes"] = notes
    if min_sdk:
        feed["min_sdk"] = int(min_sdk.group(1))

    text = json.dumps(feed, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        args.output.write_text(text, encoding="utf-8")
        print(f"Wrote {args.output} for {name} {version_name} ({code}), signer {digests[0]}", file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
