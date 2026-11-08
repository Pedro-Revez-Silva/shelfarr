#!/usr/bin/env python3
"""Maintains the publisher catalog that Shelfarr servers read Android builds from.

  {"schema_version": 1, "releases": [<entry>, ...]}

An entry is what `android-update-manifest.py --catalog-entry` writes: the feed's
release fields plus the consumer API generations the build speaks. Servers pick, per
channel, the highest version code that shares a generation with them, so a server
that only speaks generation 1 keeps finding the newest generation-1 build after
newer builds move on.

Local commands (no network):

  check CATALOG                    validate a catalog
  next --previous CATALOG ...      would this channel/version code/name be accepted?
  add --entry E --previous CATALOG --output OUT
                                   add one release (prints "added" or "unchanged")
  verify-file --entry E --file APK the file is exactly the entry's bytes

GitHub commands (through an authenticated `gh`; never print the token):

  github-fetch                     download the current catalog; exit 3 when absent
  github-publish-apk               create the APK's release at a commit and upload it
                                   once; an existing asset must match, never replaced
  github-promote                   replace the catalog asset, keeping the previous one

Every rule is fail-closed: a malformed earlier catalog, a version that goes back, or a
release that changes content under the same version code stops the publication.
"""

import argparse
import importlib.util
import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit

# The shared URL, version and API rules live in the feed generator. Loading it must
# not leave compiled files in the checkout.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("android_update_manifest", Path(__file__).with_name("android-update-manifest.py"))
manifest = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(manifest)

SCHEMA_VERSION = 1
# The server refuses a catalog above 1 MiB (AndroidUpdates::Catalog::MAX_BYTES).
MAX_CATALOG_BYTES = 1024 * 1024
# Kept well under the server's own limit on listed releases.
MAX_RELEASES = 100
DEFAULT_KEEP = 2
CATALOG_TAG = "android-catalog-v1"
CATALOG_NAME = "android-catalog.json"
ABSENT = 3

REQUIRED_FIELDS = {
    "channel", "package_name", "version_code", "version_name", "apk_url",
    "size_bytes", "sha256", "consumer_api_versions",
}
OPTIONAL_FIELDS = {"min_sdk", "release_notes"}
FIELD_ORDER = [
    "channel", "package_name", "version_code", "version_name", "apk_url",
    "size_bytes", "sha256", "min_sdk", "release_notes", "consumer_api_versions",
]
REPO = re.compile(r"[A-Za-z0-9-]{1,39}/[A-Za-z0-9_.-]{1,100}")
TAG = re.compile(r"[A-Za-z0-9_.+-]{1,128}")
ASSET_NAME = re.compile(r"[A-Za-z0-9_.+-]{1,255}")
COMMIT = re.compile(r"[0-9a-f]{40}")


class CatalogError(ValueError):
    pass


class GitHubError(RuntimeError):
    pass


class NotFound(GitHubError):
    """GitHub answered 404: the release, tag or asset does not exist."""


def fail(message: str) -> None:
    sys.exit(f"error: {message}")


# --- Reading -------------------------------------------------------------------------

def _no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CatalogError(f"duplicate key {key!r}")
        result[key] = value
    return result


def _no_constants(name):
    raise CatalogError(f"{name} is not JSON")


def parse_json(data: bytes, what: str):
    if len(data) > MAX_CATALOG_BYTES:
        raise CatalogError(f"{what} is larger than {MAX_CATALOG_BYTES} bytes")
    try:
        text = data.decode("utf-8")
        return json.loads(text, object_pairs_hook=_no_duplicate_keys, parse_constant=_no_constants)
    except UnicodeDecodeError:
        raise CatalogError(f"{what} is not UTF-8") from None
    except (json.JSONDecodeError, RecursionError) as error:
        raise CatalogError(f"{what} is not valid JSON: {error}") from None


def read_capped(path: Path, what: str) -> bytes:
    try:
        with path.open("rb") as stream:
            data = stream.read(MAX_CATALOG_BYTES + 1)
    except OSError as error:
        raise CatalogError(f"cannot read {what}: {error.strerror}") from None
    return data


def _text(entry: dict, key: str, limit: int) -> str:
    value = entry.get(key)
    if not isinstance(value, str) or not value or len(value) > limit:
        raise CatalogError(f"{key} is missing or not a short string")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        raise CatalogError(f"{key} is not valid text") from None
    return value


def _whole(entry: dict, key: str, low: int, high: int) -> int:
    value = entry.get(key)
    if type(value) is not int or not low <= value <= high:
        raise CatalogError(f"{key} must be a whole number from {low} to {high}")
    return value


def validate_entry(entry, catalog_url: str) -> dict:
    """One release, checked as strictly as the server and the app check it, or stricter."""
    if not isinstance(entry, dict):
        raise CatalogError("a release must be an object")
    keys = set(entry)
    missing = REQUIRED_FIELDS - keys
    unknown = keys - REQUIRED_FIELDS - OPTIONAL_FIELDS
    if missing:
        raise CatalogError(f"a release is missing {', '.join(sorted(missing))}")
    if unknown:
        raise CatalogError(f"a release has unknown fields {', '.join(sorted(unknown))}")

    channel = _text(entry, "channel", 64)
    package = _text(entry, "package_name", 255)
    if manifest.CHANNEL_PACKAGES.get(channel) != package:
        raise CatalogError(f"unknown channel and package {channel!r} / {package!r}")
    code = _whole(entry, "version_code", 1, manifest.MAX_VERSION_CODE)
    name = _text(entry, "version_name", 64)
    try:
        manifest.check_calver(name)
        manifest.check_catalog_apk_url(_text(entry, "apk_url", manifest.MAX_URL_CHARS), catalog_url)
        apis = manifest.check_api_versions(entry.get("consumer_api_versions"))
    except manifest.PolicyError as error:
        raise CatalogError(f"{channel} {code}: {error}") from None
    if apis != entry["consumer_api_versions"]:
        raise CatalogError(f"{channel} {code}: consumer_api_versions must be sorted")
    _whole(entry, "size_bytes", 1, manifest.MAX_APK_BYTES)
    if not isinstance(entry.get("sha256"), str) or not manifest.SHA256.fullmatch(entry["sha256"]):
        raise CatalogError(f"{channel} {code}: sha256 must be 64 lowercase hex characters")
    if "min_sdk" in entry:
        _whole(entry, "min_sdk", 1, 1000)
    if "release_notes" in entry:
        notes = entry["release_notes"]
        if not isinstance(notes, str) or not notes.strip() or len(notes) > manifest.MAX_NOTES_CHARS:
            raise CatalogError(f"{channel} {code}: release_notes must be non-blank text of at most {manifest.MAX_NOTES_CHARS} characters")
        _text(entry, "release_notes", manifest.MAX_NOTES_CHARS)
    return {key: entry[key] for key in FIELD_ORDER if key in entry}


def check_unique(releases: list) -> None:
    """No two releases may share a version, a label, a URL or the same bytes."""
    seen = {}
    for release in releases:
        identities = {
            "version code": (release["package_name"], release["version_code"]),
            "version name": (release["package_name"], release["version_name"]),
            "APK URL": release["apk_url"],
            "SHA-256": release["sha256"],
        }
        for kind, identity in identities.items():
            if (kind, identity) in seen:
                raise CatalogError(f"two releases share the {kind} {identity!r}")
            seen[(kind, identity)] = release


def validate_catalog(document, catalog_url: str) -> list:
    if not isinstance(document, dict) or set(document) != {"schema_version", "releases"}:
        raise CatalogError("a catalog must be an object with exactly schema_version and releases")
    if type(document["schema_version"]) is not int or document["schema_version"] != SCHEMA_VERSION:
        raise CatalogError(f"catalog schema_version is not {SCHEMA_VERSION}")
    entries = document["releases"]
    if not isinstance(entries, list):
        raise CatalogError("catalog releases must be a list")
    if len(entries) > MAX_RELEASES:
        raise CatalogError(f"catalog lists more than {MAX_RELEASES} releases")
    releases = [validate_entry(entry, catalog_url) for entry in entries]
    check_unique(releases)
    return releases


def load_catalog(path: Path, catalog_url: str) -> list:
    return validate_catalog(parse_json(read_capped(path, "the catalog"), "the catalog"), catalog_url)


def load_entry(path: Path, catalog_url: str) -> dict:
    return validate_entry(parse_json(read_capped(path, "the entry"), "the entry"), catalog_url)


def previous_releases(args) -> list:
    if args.no_previous:
        return []
    return load_catalog(args.previous, args.catalog_url)


# --- Building ------------------------------------------------------------------------

def serialize(releases: list) -> str:
    text = json.dumps({"schema_version": SCHEMA_VERSION, "releases": releases}, indent=2, ensure_ascii=False) + "\n"
    if len(text.encode("utf-8")) > MAX_CATALOG_BYTES:
        raise CatalogError(f"the catalog would be larger than {MAX_CATALOG_BYTES} bytes")
    return text


def order(releases: list) -> list:
    return sorted(releases, key=lambda r: (r["channel"] != "release", r["channel"], -r["version_code"]))


def retain(releases: list, keep: int) -> list:
    """The newest `keep` releases of each channel, package and API generation set.

    A build line that a newer generation replaced stays listed, so servers that
    only speak the older generation still find its newest builds.
    """
    lines = {}
    for release in sorted(releases, key=lambda r: -r["version_code"]):
        line = (release["channel"], release["package_name"], tuple(release["consumer_api_versions"]))
        kept = lines.setdefault(line, [])
        if len(kept) < keep:
            kept.append(release)
    return order([release for kept in lines.values() for release in kept])


def admit(releases: list, channel: str, package: str, code: int, name: str):
    """'present' when exactly this version is listed, 'new' when it may be added."""
    same_package = [r for r in releases if r["package_name"] == package]
    listed = next((r for r in same_package if r["version_code"] == code), None)
    if listed:
        if listed["version_name"] != name or listed["channel"] != channel:
            raise CatalogError(f"version code {code} is already published as {listed['version_name']}")
        return "present"
    highest = max((r["version_code"] for r in same_package), default=0)
    if code <= highest:
        raise CatalogError(f"version code {code} must be larger than every published {package} build (highest {highest})")
    if any(r["version_name"] == name for r in same_package):
        raise CatalogError(f"version name {name} is already published with another version code")
    return "new"


def add(releases: list, entry: dict, keep: int):
    status = admit(releases, entry["channel"], entry["package_name"], entry["version_code"], entry["version_name"])
    if status == "present":
        listed = next(r for r in releases if r["package_name"] == entry["package_name"] and r["version_code"] == entry["version_code"])
        if listed != entry:
            changed = sorted(k for k in set(listed) | set(entry) if listed.get(k) != entry.get(k))
            raise CatalogError(f"version code {entry['version_code']} is already published with different {', '.join(changed)}")
        return order(releases), "unchanged"
    combined = releases + [entry]
    check_unique(combined)
    kept = retain(combined, keep)
    if entry not in kept:
        raise CatalogError("the new release would not be kept")
    if len(kept) > MAX_RELEASES:
        raise CatalogError(f"the catalog would list more than {MAX_RELEASES} releases")
    return kept, "added"


def sha256_file(path: Path) -> str:
    return manifest.sha256_file(path)


def verify_file(entry: dict, path: Path) -> None:
    try:
        size = path.stat().st_size
    except OSError as error:
        raise CatalogError(f"cannot read {path.name}: {error.strerror}") from None
    if size != entry["size_bytes"]:
        raise CatalogError(f"{path.name} is {size} bytes, the entry says {entry['size_bytes']}")
    if sha256_file(path) != entry["sha256"]:
        raise CatalogError(f"{path.name} does not match the entry's SHA-256")


# --- GitHub --------------------------------------------------------------------------

def gh(arguments: list, *, stdin: bytes = None, retries: int = 0) -> bytes:
    """Runs gh with an argument list, never through a shell. A 404 raises NotFound;
    any other failure (network, authentication, rate limit) raises GitHubError, so
    a missing catalog is never confused with one that could not be read."""
    attempt = 0
    while True:
        result = subprocess.run(["gh", *arguments], input=stdin, capture_output=True)
        if result.returncode == 0:
            return result.stdout
        message = result.stderr.decode("utf-8", "replace").strip()
        if re.search(r"\(HTTP 404\)", message):
            raise NotFound(f"gh {' '.join(arguments[:3])}: not found")
        attempt += 1
        if attempt > retries:
            raise GitHubError(f"gh {arguments[0]} {arguments[1] if len(arguments) > 1 else ''} failed: {message[:300]}")
        time.sleep(2 * attempt)


def api_json(path: str, method: str = "GET", body: dict = None):
    arguments = ["api", "--method", method, path]
    stdin = None
    if body is not None:
        arguments += ["--input", "-"]
        stdin = json.dumps(body).encode("utf-8")
    output = gh(arguments, stdin=stdin, retries=2 if method == "GET" else 0)
    return json.loads(output) if output.strip() else None


def get_release(repo: str, tag: str):
    try:
        release = api_json(f"repos/{repo}/releases/tags/{tag}")
    except NotFound:
        return None
    if not isinstance(release, dict) or not isinstance(release.get("assets"), list):
        raise GitHubError(f"unexpected answer for release {tag}")
    if release.get("draft"):
        raise GitHubError(f"release {tag} is a draft; publish or delete it first")
    return release


def assets_by_name(release: dict) -> dict:
    return {asset.get("name"): asset for asset in release["assets"] if isinstance(asset, dict)}


def tag_commit(repo: str, tag: str):
    try:
        ref = api_json(f"repos/{repo}/git/ref/tags/{tag}")
    except NotFound:
        return None
    target = ref.get("object", {}) if isinstance(ref, dict) else {}
    for _ in range(5):
        if target.get("type") == "commit":
            return target.get("sha")
        if target.get("type") != "tag":
            break
        target = api_json(f"repos/{repo}/git/tags/{target.get('sha')}").get("object", {})
    raise GitHubError(f"tag {tag} does not point at a commit")


def download_asset(repo: str, asset: dict, destination: Path, limit: int) -> None:
    if asset.get("state") != "uploaded":
        raise GitHubError(f"asset {asset.get('name')} is not completely uploaded")
    size = asset.get("size")
    if type(size) is not int or not 0 < size <= limit:
        raise GitHubError(f"asset {asset.get('name')} has an unexpected size")
    data = gh(["api", "--method", "GET", "-H", "Accept: application/octet-stream",
               f"repos/{repo}/releases/assets/{int(asset['id'])}"], retries=2)
    if len(data) != size:
        raise GitHubError(f"asset {asset.get('name')} downloaded {len(data)} of {size} bytes")
    with open(destination, "wb") as stream:
        stream.write(data)


def upload_asset(repo: str, tag: str, source: Path, name: str) -> None:
    """Uploads source as name; gh refuses if the name exists (no --clobber)."""
    with tempfile.TemporaryDirectory() as directory:
        staged = Path(directory, name)
        shutil.copyfile(source, staged)
        gh(["release", "upload", tag, str(staged), "--repo", repo])


def create_release(repo: str, tag: str, commit: str, title: str, body: str, prerelease: bool) -> None:
    api_json(f"repos/{repo}/releases", "POST", {
        "tag_name": tag, "target_commitish": commit, "name": title, "body": body,
        "draft": False, "prerelease": prerelease, "make_latest": "false",
    })


def ensure_release(repo: str, tag: str, commit: str, title: str, body: str, prerelease: bool,
                   create: bool, pinned: bool = True) -> dict:
    release = get_release(repo, tag)
    if release is None:
        if not create:
            raise GitHubError(f"release {tag} does not exist")
        existing = tag_commit(repo, tag)
        if pinned and existing and existing != commit:
            raise GitHubError(f"tag {tag} already points at {existing}, not {commit}")
        create_release(repo, tag, commit, title, body, prerelease)
        release = get_release(repo, tag)
        if release is None:
            raise GitHubError(f"release {tag} was not created")
    return release


def require_repo(repo: str) -> None:
    if not REPO.fullmatch(repo or "") or ".." in repo:
        fail("--repo must be owner/name")


def require_catalog_location(args) -> None:
    """The GitHub commands act on the release the catalog URL names, nothing else."""
    require_repo(args.repo)
    location = manifest.github_release_asset(urlsplit(args.catalog_url))
    if not location or (f"{location['owner']}/{location['repo']}", location["tag"], location["name"]) != (args.repo, args.tag, args.name):
        fail(f"--catalog-url must be https://github.com/{args.repo}/releases/download/{args.tag}/{args.name}")


def catalog_names(name: str):
    stem = name[:-len(".json")]
    return name, f"{stem}.previous.json", f"{stem}.next.json"


def github_fetch(args) -> int:
    require_catalog_location(args)
    main, previous, upcoming = catalog_names(args.name)
    release = get_release(args.repo, args.tag)
    if release is None:
        print(f"absent: there is no {args.tag} release", file=sys.stderr)
        return ABSENT
    assets = assets_by_name(release)
    if main not in assets:
        if previous in assets or upcoming in assets:
            raise GitHubError(
                f"{args.tag} has {previous} or {upcoming} but no {main}: a promotion was interrupted. "
                f"See docs/android-publishing.md before publishing again"
            )
        print(f"absent: {args.tag} has no {main}", file=sys.stderr)
        return ABSENT
    download_asset(args.repo, assets[main], args.output, MAX_CATALOG_BYTES)
    load_catalog(args.output, args.catalog_url)
    print(sha256_file(args.output))
    return 0


def github_publish_apk(args) -> int:
    require_repo(args.repo)
    if not COMMIT.fullmatch(args.target_sha):
        fail("--target-sha must be a full commit SHA")
    entry = load_entry(args.entry, args.catalog_url)
    verify_file(entry, args.file)
    asset_url = manifest.github_release_asset(urlsplit(entry["apk_url"]))
    if not asset_url or f"{asset_url['owner']}/{asset_url['repo']}" != args.repo:
        fail(f"the entry's apk_url is not a release asset of {args.repo}")
    tag, name = asset_url["tag"], asset_url["name"]
    notes = args.notes_file.read_text(encoding="utf-8") if args.notes_file else ""

    release = ensure_release(args.repo, tag, args.target_sha, args.title, notes, args.prerelease, create=True)
    commit = tag_commit(args.repo, tag)
    if commit != args.target_sha:
        raise GitHubError(f"release {tag} is at {commit}, not the tested commit {args.target_sha}")

    assets = assets_by_name(release)
    if any(asset_name != name and asset_name.lower().endswith(".apk") for asset_name in assets):
        # Catalog retention forgets old labels; their immutable releases do not.
        # A label still identifies exactly one APK, even at the same source SHA.
        raise GitHubError(f"release {tag} already contains another APK; choose a new calendar version")

    with tempfile.TemporaryDirectory() as directory:
        check = Path(directory, "published.apk")
        asset = assets.get(name)
        if asset and asset.get("state") != "uploaded":
            # A failed upload is never listed in a catalog; start it over.
            gh(["api", "--method", "DELETE", f"repos/{args.repo}/releases/assets/{int(asset['id'])}"])
            asset = None
        if asset:
            download_asset(args.repo, asset, check, manifest.MAX_APK_BYTES)
            try:
                verify_file(entry, check)
            except CatalogError as error:
                raise GitHubError(f"{tag} already has a different {name} ({error}); it is never replaced") from None
            print("present")
            return 0
        upload_asset(args.repo, tag, args.file, name)
        asset = assets_by_name(get_release(args.repo, tag) or {"assets": []}).get(name)
        if not asset:
            raise GitHubError(f"{name} is not listed on {tag} after uploading")
        download_asset(args.repo, asset, check, manifest.MAX_APK_BYTES)
        verify_file(entry, check)
    print("uploaded")
    return 0


def github_promote(args) -> int:
    """Publishes the catalog: upload as .next, verify, keep the old one as .previous,
    then rename .next into place. At every step either the old or the new catalog
    survives under a known name."""
    require_catalog_location(args)
    if not COMMIT.fullmatch(args.target_sha):
        fail("--target-sha must be a full commit SHA")
    if bool(args.previous_sha256) == bool(args.allow_new):
        fail("give exactly one of --previous-sha256 or --allow-new")
    if args.previous_sha256 and not manifest.SHA256.fullmatch(args.previous_sha256):
        fail("--previous-sha256 must be 64 lowercase hex characters")
    load_catalog(args.file, args.catalog_url)
    expected = sha256_file(args.file)
    main, previous, upcoming = catalog_names(args.name)

    body = ("The Android publisher catalog that Shelfarr servers read. It is replaced on every "
            "Android publication; APKs live in their own android-<channel>-v<version> releases.")
    release = ensure_release(args.repo, args.tag, args.target_sha, "Android catalog", body, True,
                             create=bool(args.allow_new), pinned=False)
    assets = assets_by_name(release)

    with tempfile.TemporaryDirectory() as directory:
        current = Path(directory, "current.json")
        if main in assets:
            if args.allow_new:
                raise GitHubError(f"{args.tag} already has {main}; publish against it instead of --allow-new")
            download_asset(args.repo, assets[main], current, MAX_CATALOG_BYTES)
            if sha256_file(current) != args.previous_sha256:
                raise GitHubError(f"{main} changed since it was read; start the publication again")
        elif not args.allow_new or previous in assets or upcoming in assets:
            raise GitHubError(f"{args.tag} has no {main} to replace; see docs/android-publishing.md")

        if upcoming in assets:
            gh(["api", "--method", "DELETE", f"repos/{args.repo}/releases/assets/{int(assets[upcoming]['id'])}"])
        upload_asset(args.repo, args.tag, args.file, upcoming)
        assets = assets_by_name(get_release(args.repo, args.tag))
        if upcoming not in assets:
            raise GitHubError(f"{upcoming} is not listed after uploading")
        download_asset(args.repo, assets[upcoming], current, MAX_CATALOG_BYTES)
        if sha256_file(current) != expected:
            raise GitHubError(f"{upcoming} does not match what was uploaded")

        if previous in assets:
            gh(["api", "--method", "DELETE", f"repos/{args.repo}/releases/assets/{int(assets[previous]['id'])}"])
        if main in assets:
            api_json(f"repos/{args.repo}/releases/assets/{int(assets[main]['id'])}", "PATCH", {"name": previous})
        api_json(f"repos/{args.repo}/releases/assets/{int(assets[upcoming]['id'])}", "PATCH", {"name": main})

        assets = assets_by_name(get_release(args.repo, args.tag))
        if main not in assets:
            raise GitHubError(f"{main} is not listed after promotion")
        download_asset(args.repo, assets[main], current, MAX_CATALOG_BYTES)
        if sha256_file(current) != expected:
            raise GitHubError(f"{main} does not match the new catalog after promotion")
    print("promoted")
    return 0


# --- Command line --------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--catalog-url", default=manifest.OFFICIAL_CATALOG_URL,
                        help="where the catalog is published; decides where APKs may be (default: the official one)")
    commands = parser.add_subparsers(dest="command", required=True)

    def with_previous(command):
        group = command.add_mutually_exclusive_group(required=True)
        group.add_argument("--previous", type=Path, help="the catalog as currently published")
        group.add_argument("--no-previous", action="store_true", help="there is no catalog yet")

    check = commands.add_parser("check")
    check.add_argument("catalog", type=Path)

    plan = commands.add_parser("next")
    with_previous(plan)
    plan.add_argument("--channel", required=True, choices=sorted(manifest.CHANNEL_PACKAGES))
    plan.add_argument("--version-code", required=True, type=int)
    plan.add_argument("--version-name", required=True)

    adding = commands.add_parser("add")
    with_previous(adding)
    adding.add_argument("--entry", required=True, type=Path)
    adding.add_argument("--output", required=True, type=Path)
    adding.add_argument("--keep", type=int, default=DEFAULT_KEEP, help="releases kept per channel and API set (default 2)")

    verify = commands.add_parser("verify-file")
    verify.add_argument("--entry", required=True, type=Path)
    verify.add_argument("--file", required=True, type=Path)

    fetch = commands.add_parser("github-fetch")
    fetch.add_argument("--repo", required=True)
    fetch.add_argument("--tag", default=CATALOG_TAG)
    fetch.add_argument("--name", default=CATALOG_NAME)
    fetch.add_argument("--output", required=True, type=Path)

    publish = commands.add_parser("github-publish-apk")
    publish.add_argument("--repo", required=True)
    publish.add_argument("--target-sha", required=True)
    publish.add_argument("--entry", required=True, type=Path)
    publish.add_argument("--file", required=True, type=Path)
    publish.add_argument("--title", required=True)
    publish.add_argument("--notes-file", type=Path)
    publish.add_argument("--prerelease", action="store_true")

    promote = commands.add_parser("github-promote")
    promote.add_argument("--repo", required=True)
    promote.add_argument("--tag", default=CATALOG_TAG)
    promote.add_argument("--name", default=CATALOG_NAME)
    promote.add_argument("--file", required=True, type=Path)
    promote.add_argument("--target-sha", required=True)
    promote.add_argument("--previous-sha256")
    promote.add_argument("--allow-new", action="store_true", help="create the catalog; refused if one exists")

    args = parser.parse_args()
    for value in (getattr(args, "tag", None), getattr(args, "name", None)):
        if value is not None and not (TAG.fullmatch(value) and ASSET_NAME.fullmatch(value)):
            fail(f"{value!r} is not a usable release tag or asset name")
    if getattr(args, "name", None) and not args.name.endswith(".json"):
        fail("--name must end in .json")

    try:
        manifest.check_catalog_url(args.catalog_url)
        if args.command == "check":
            releases = load_catalog(args.catalog, args.catalog_url)
            print(f"{len(releases)} releases", file=sys.stderr)
        elif args.command == "next":
            package = manifest.CHANNEL_PACKAGES[args.channel]
            if not 1 <= args.version_code <= manifest.MAX_VERSION_CODE:
                raise CatalogError(f"version code {args.version_code} is out of range")
            manifest.check_calver(args.version_name)
            print(admit(previous_releases(args), args.channel, package, args.version_code, args.version_name))
        elif args.command == "add":
            if not 1 <= args.keep <= 10:
                raise CatalogError("--keep must be from 1 to 10")
            releases, status = add(previous_releases(args), load_entry(args.entry, args.catalog_url), args.keep)
            manifest.write_output(serialize(releases), args.output)
            print(status)
        elif args.command == "verify-file":
            verify_file(load_entry(args.entry, args.catalog_url), args.file)
            print("verified")
        elif args.command == "github-fetch":
            sys.exit(github_fetch(args))
        elif args.command == "github-publish-apk":
            sys.exit(github_publish_apk(args))
        elif args.command == "github-promote":
            sys.exit(github_promote(args))
    except (CatalogError, manifest.PolicyError, GitHubError) as error:
        fail(str(error))


if __name__ == "__main__":
    main()
