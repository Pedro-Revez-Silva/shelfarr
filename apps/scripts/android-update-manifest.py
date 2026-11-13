#!/usr/bin/env python3
"""Describes a signed Android APK for the in-app updater, after checking it.

The APK is checked first: its signature with apksigner, its package, version and
minimum SDK with aapt2, then its size and SHA-256. Nothing is uploaded. Needs
ANDROID_HOME (build-tools) and java.

Two outputs:

  Direct feed (default): the schema 1 feed a phone reads from a fixed publisher
  directory. The APK must be published on the feed's origin, inside its directory.

    apps/scripts/android-update-manifest.py \\
      --apk app-debug.apk \\
      --feed-url https://example.org/downloads/android-development.json \\
      --apk-url https://example.org/downloads/shelfarr-android-development-3.apk \\
      --channel development --package org.shelfarr.app.debug \\
      --signer-sha256 <64 hex> --previous-version-code 2 \\
      --notes-file notes.txt --output android-development.json

  Catalog entry (--catalog-entry): one release for the publisher catalog that
  Shelfarr servers read (apps/scripts/android-update-catalog.py adds it). With a
  catalog published as a GitHub release asset, the APK must be an asset of
  another release of the same repository; otherwise it must be on the catalog's
  origin. The signer is required, and the version name must be a calendar version.

    apps/scripts/android-update-manifest.py --catalog-entry \\
      --apk shelfarr.apk \\
      --apk-url https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/android-release-v2026.11.8.1/shelfarr-android-release-2026.11.8.1-12.apk \\
      --channel release --package org.shelfarr.app --signer-sha256 <64 hex> \\
      --expect-version-code 12 --expect-version-name 2026.11.8.1 \\
      --consumer-api 1 --output entry.json
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
MAX_API_VERSION = 1000
MAX_API_VERSIONS = 16
MAX_URL_CHARS = 2048
VERSION_NAME = re.compile(r"[0-9A-Za-z][0-9A-Za-z._+-]{0,63}")
# The server's calendar version rule (AndroidUpdates::ReleaseFields::CALVER).
CALVER = re.compile(r"(?P<year>20\d{2})\.(?P<month>0?[1-9]|1[0-2])\.\d{1,6}(?:[.+-][0-9A-Za-z._+-]*)?")
SHA256 = re.compile(r"[0-9a-f]{64}")
BAD_URL_TEXT = re.compile(r"[\\@#?\s]|%2e|%2f|%5c|%00|%40|%23|%3f", re.IGNORECASE)
CHANNEL_PACKAGES = {"release": "org.shelfarr.app", "development": "org.shelfarr.app.debug"}
OFFICIAL_CATALOG_URL = (
    "https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/android-catalog-v1/android-catalog.json"
)
GITHUB_HOST = "github.com"
GITHUB_ASSET_PATH = re.compile(
    r"/(?P<owner>[A-Za-z0-9-]{1,39})/(?P<repo>[A-Za-z0-9_.-]{1,100})/releases/download/"
    r"(?P<tag>[A-Za-z0-9_.+-]{1,128})/(?P<name>[A-Za-z0-9_.+-]{1,255})"
)


class PolicyError(ValueError):
    """Metadata that must not be published."""


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


def clean_https(url: str, suffix: str):
    """Parses an https URL with a clean path ending in suffix, or raises PolicyError."""
    if not isinstance(url, str) or not url or len(url) > MAX_URL_CHARS:
        raise PolicyError("URL is missing or too long")
    if any(ord(character) <= 0x20 or ord(character) >= 0x7f for character in url):
        raise PolicyError("URL must contain only printable ASCII characters")
    if BAD_URL_TEXT.search(url):
        raise PolicyError(f"{url} must not contain credentials, a query, a fragment or encoded separators")
    parts = urlsplit(url)
    if parts.scheme != "https" or not parts.hostname:
        raise PolicyError(f"{url} must be an absolute https URL")
    segments = parts.path.split("/")[1:]
    if not parts.path.startswith("/") or any(s in ("", ".", "..") for s in segments) or not parts.path.endswith(suffix):
        raise PolicyError(f"{url} must be a clean path ending in {suffix}")
    return parts


def check_url(url: str, feed: str, suffix: str):
    """The direct-feed rule: the APK on the feed's origin, inside its directory."""
    try:
        parts = clean_https(url, suffix)
        if feed:
            base = urlsplit(feed)
            directory = base.path.rsplit("/", 1)[0] + "/"
            if (parts.scheme, parts.hostname, parts.port) != (base.scheme, base.hostname, base.port):
                raise PolicyError("the APK must be on the feed's origin")
            if not parts.path.startswith(directory):
                raise PolicyError(f"the APK must be inside the feed's directory, {directory}")
    except PolicyError as error:
        fail(str(error))
    return parts


def github_release_asset(parts):
    """(owner, repo, tag, name) when parts name a GitHub release asset, else None."""
    if parts.netloc != GITHUB_HOST:
        return None
    match = GITHUB_ASSET_PATH.fullmatch(parts.path)
    return match.groupdict() if match else None


def check_catalog_url(url: str):
    parts = clean_https(url, ".json")
    if "%" in url:
        raise PolicyError(f"{url} must not contain percent escapes")
    return parts


def check_catalog_apk_url(url: str, catalog_url: str) -> None:
    """Where a catalog may send servers for an APK.

    A catalog that is itself a GitHub release asset may only name assets of other
    releases of the same repository: the catalog's own release is rewritten on
    every publication, while APK releases never change. Any other catalog keeps
    its APKs on its own origin, as servers require.
    """
    catalog = check_catalog_url(catalog_url)
    parts = clean_https(url, ".apk")
    if "%" in url:
        raise PolicyError(f"{url} must not contain percent escapes")
    catalog_asset = github_release_asset(catalog)
    if catalog_asset:
        asset = github_release_asset(parts)
        if not asset or (asset["owner"], asset["repo"]) != (catalog_asset["owner"], catalog_asset["repo"]):
            raise PolicyError(
                f"the APK must be a release asset of github.com/{catalog_asset['owner']}/{catalog_asset['repo']}"
            )
        if asset["tag"] == catalog_asset["tag"]:
            raise PolicyError("the APK must not be an asset of the catalog's own, mutable, release")
    elif (parts.scheme, parts.hostname, parts.port) != (catalog.scheme, catalog.hostname, catalog.port):
        raise PolicyError("the APK must be on the catalog's origin")


def check_api_versions(values) -> list:
    if not isinstance(values, list) or not 1 <= len(values) <= MAX_API_VERSIONS:
        raise PolicyError(f"consumer API generations must be a list of 1 to {MAX_API_VERSIONS} numbers")
    if any(type(v) is not int or not 1 <= v <= MAX_API_VERSION for v in values):
        raise PolicyError(f"consumer API generations must be whole numbers from 1 to {MAX_API_VERSION}")
    if len(set(values)) != len(values):
        raise PolicyError("consumer API generations must not repeat")
    return sorted(values)


def check_calver(name: str) -> None:
    if not (VERSION_NAME.fullmatch(name) and CALVER.fullmatch(name)):
        raise PolicyError(f"version name {name!r} is not a calendar version such as 2026.11.8.1")


def inspect_apk(apk: Path, strict: bool) -> dict:
    """Signers, package line and SDK of an APK, read with the SDK's own tools."""
    try:
        size = apk.stat().st_size
    except OSError as error:
        fail(f"cannot read the APK: {error.strerror}")
    if not apk.is_file() or not 0 < size <= MAX_APK_BYTES:
        fail(f"APK size {size} is outside 1..{MAX_APK_BYTES}")

    signers = run([build_tool("apksigner"), "verify", "--verbose", "--print-certs", str(apk)])
    digests = sorted(set(re.findall(r"certificate SHA-256 digest: ([0-9a-f]{64})", signers)))
    if not digests:
        fail("apksigner reported no signer")
    if strict and not re.search(r"^Verified using v[23] scheme \(APK Signature Scheme v[23]\): true$", signers, re.MULTILINE):
        fail("the APK must carry an APK Signature Scheme v2 or v3 signature")

    badging = run([build_tool("aapt2"), "dump", "badging", str(apk)])
    package = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']*)'", badging, re.MULTILINE)
    if not package:
        fail("aapt2 could not read the package line")
    min_sdk = re.search(r"^(?:minSdkVersion|sdkVersion):'(\d+)'", badging, re.MULTILINE)
    return {
        "size": size,
        "digests": digests,
        "package": package.group(1),
        "version_code": int(package.group(2)),
        "version_name": package.group(3),
        "min_sdk": int(min_sdk.group(1)) if min_sdk else None,
        "debuggable": re.search(r"^application-debuggable$", badging, re.MULTILINE) is not None,
        "test_only": re.search(r"^testOnly='-?[1-9]\d*'$", badging, re.MULTILINE) is not None,
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def read_notes(path: Path):
    if not path:
        return None
    try:
        notes = path.read_text(encoding="utf-8").replace("\r\n", "\n").strip()
    except (OSError, UnicodeDecodeError) as error:
        fail(f"cannot read the release notes: {error}")
    if len(notes) > MAX_NOTES_CHARS:
        fail(f"release notes are longer than {MAX_NOTES_CHARS} characters")
    return notes or None


def write_output(text: str, output: Path) -> None:
    """Replaces output in one step, so a reader never sees half a file."""
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    try:
        with open(temporary, "x", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--catalog-entry", action="store_true", help="write a publisher catalog entry instead of a direct feed")
    parser.add_argument("--feed-url", help="direct feed: the shelfarrUpdateFeedUrl the app was built with")
    parser.add_argument("--catalog-url", default=OFFICIAL_CATALOG_URL, help="catalog entry: the catalog it will be listed in")
    parser.add_argument("--apk-url", required=True, help="where the APK will be published")
    parser.add_argument("--channel", default="development", choices=sorted(CHANNEL_PACKAGES))
    parser.add_argument("--package", required=True, help="expected application ID, e.g. org.shelfarr.app.debug")
    parser.add_argument("--signer-sha256", help="expected signing certificate SHA-256 (required for a catalog entry)")
    parser.add_argument("--previous-version-code", type=int, help="the version code currently published; the new one must be larger")
    parser.add_argument("--expect-version-code", type=int, help="fail unless the APK has exactly this version code")
    parser.add_argument("--expect-version-name", help="fail unless the APK has exactly this version name")
    parser.add_argument(
        "--consumer-api", type=int, action="append", metavar="N",
        help="a consumer API generation the build speaks; repeat for several (default: 1)",
    )
    parser.add_argument("--notes-file", type=Path, help="plain-text release notes, at most 4000 characters")
    parser.add_argument("--output", type=Path, help="write here instead of stdout")
    args = parser.parse_args()

    try:
        api_versions = check_api_versions(args.consumer_api or [1])
    except PolicyError as error:
        fail(str(error))
    signer = (args.signer_sha256 or "").strip().lower()
    if args.signer_sha256 is not None and not SHA256.fullmatch(signer):
        fail("--signer-sha256 must be 64 hex characters")

    if args.catalog_entry:
        if args.feed_url:
            fail("--feed-url is for a direct feed; a catalog entry takes --catalog-url")
        if not signer:
            fail("a catalog entry needs --signer-sha256, so every published build has the same signer")
        if CHANNEL_PACKAGES[args.channel] != args.package:
            fail(f"the {args.channel} channel is the {CHANNEL_PACKAGES[args.channel]} package, not {args.package}")
        try:
            check_catalog_apk_url(args.apk_url, args.catalog_url)
        except PolicyError as error:
            fail(str(error))
    else:
        if not args.feed_url:
            fail("a direct feed needs --feed-url (or use --catalog-entry)")
        check_url(args.feed_url, "", ".json")
        check_url(args.apk_url, args.feed_url, ".apk")

    facts = inspect_apk(args.apk, strict=args.catalog_entry)
    digests = facts["digests"]
    if signer and digests != [signer]:
        fail(f"APK is signed by {', '.join(digests)}, not the expected certificate")

    name, code, version_name = facts["package"], facts["version_code"], facts["version_name"]
    if name != args.package:
        fail(f"APK package is {name}, expected {args.package}")
    if not 1 <= code <= MAX_VERSION_CODE:
        fail(f"version code {code} is out of range")
    if args.expect_version_code is not None and code != args.expect_version_code:
        fail(f"APK version code is {code}, expected {args.expect_version_code}")
    if args.previous_version_code is not None and code <= args.previous_version_code:
        fail(f"version code {code} must be larger than the published {args.previous_version_code}")
    if not VERSION_NAME.fullmatch(version_name):
        fail(f"version name {version_name!r} is not usable")
    if args.expect_version_name is not None and version_name != args.expect_version_name:
        fail(f"APK version name is {version_name!r}, expected {args.expect_version_name!r}")
    min_sdk = facts["min_sdk"]
    if min_sdk is not None and not 1 <= min_sdk <= 1000:
        fail(f"minimum SDK {min_sdk} is out of range")

    if args.catalog_entry:
        try:
            check_calver(version_name)
        except PolicyError as error:
            fail(str(error))
        if min_sdk is None:
            fail("aapt2 reported no minimum SDK")
        if facts["test_only"]:
            fail("the APK is marked testOnly; Android would refuse to install it as an update")
        if args.channel == "release" and facts["debuggable"]:
            fail("a release build must not be debuggable")

    notes = read_notes(args.notes_file)
    feed = {} if args.catalog_entry else {"schema_version": 1}
    feed.update({
        "channel": args.channel,
        "package_name": name,
        "version_code": code,
        "version_name": version_name,
        "apk_url": args.apk_url,
        "size_bytes": facts["size"],
        "sha256": sha256_file(args.apk),
    })
    if notes:
        feed["release_notes"] = notes
    if min_sdk is not None:
        feed["min_sdk"] = min_sdk
    feed["consumer_api_versions"] = api_versions

    text = json.dumps(feed, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        write_output(text, args.output)
        print(f"Wrote {args.output} for {name} {version_name} ({code}), signer {digests[0]}", file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
