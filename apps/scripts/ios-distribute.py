#!/usr/bin/env python3
"""Sign an iPhone/iPad archive with isolated, temporary signing material."""

import argparse
import base64
import binascii
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile


BUNDLE_ID = "org.shelfarr.app"
METHODS = ("app-store-connect", "release-testing")
UUID_PATTERN = r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}"


class DistributionError(Exception):
    """A safe diagnostic: never includes signing material or a command line."""


def version_plan(version, build, method, upload=False):
    if not re.fullmatch(r"20\d{2}\.(?:[1-9]|1[0-2])\.(?:0|[1-9]\d{0,5})", version):
        raise DistributionError("Use a three-part calendar version, such as 2026.11.9")
    if not re.fullmatch(r"[1-9]\d{0,3}(?:\.(?:0|[1-9]\d?)){0,2}", build):
        raise DistributionError("Build must have 1–3 numeric parts: at most 4, 2 and 2 digits")
    if method not in METHODS or upload and method != "app-store-connect":
        raise DistributionError("TestFlight upload requires the app-store-connect method")
    return {"bundle_id": BUNDLE_ID, "version": version, "build": build,
            "method": method, "upload_requested": upload, "consumer_api_versions": [1]}


def required(env, name):
    value = env.get(name, "")
    if not value:
        raise DistributionError(f"Configure {name} in the ios-distribution environment")
    return value


def decode_secret(env, name, maximum):
    value = required(env, name)
    if len(value) > maximum * 2:
        raise DistributionError(f"{name} exceeds its size limit")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        raise DistributionError(f"{name} must be one line of valid base64") from None
    if not decoded or len(decoded) > maximum:
        raise DistributionError(f"{name} has an invalid size")
    return decoded


def validate_profile(profile, team, method, now=None):
    """Validate decoded CMS data without emitting entitlements or device IDs."""
    now = now or datetime.now(timezone.utc)
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise DistributionError("IOS_TEAM_ID must be the ten-character Apple team ID")
    if not isinstance(profile, dict):
        raise DistributionError("The provisioning profile must be a property list")
    identifier = profile.get("UUID")
    if not isinstance(identifier, str) or not re.fullmatch(UUID_PATTERN, identifier):
        raise DistributionError("The provisioning profile has an invalid UUID")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime) or (expiry.replace(tzinfo=timezone.utc) if expiry.tzinfo is None else expiry) <= now:
        raise DistributionError("The provisioning profile is expired or has no expiry")
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict) or profile.get("TeamIdentifier") != [team]:
        raise DistributionError("The provisioning profile belongs to another Apple team")
    if (entitlements.get("application-identifier") != f"{team}.{BUNDLE_ID}" or
            entitlements.get("com.apple.developer.team-identifier") != team):
        raise DistributionError("Use an explicit profile for this team and org.shelfarr.app")
    if entitlements.get("get-task-allow") is not False or profile.get("ProvisionsAllDevices"):
        raise DistributionError("Use a distribution profile, not development or enterprise signing")
    devices = profile.get("ProvisionedDevices")
    if method == "app-store-connect" and devices is not None:
        raise DistributionError("TestFlight needs an App Store Connect provisioning profile")
    if method == "release-testing" and (not isinstance(devices, list) or not devices or
                                        not all(isinstance(device, str) and device for device in devices)):
        raise DistributionError("Release testing needs a profile containing the registered iPad")
    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not certificates or not all(isinstance(c, bytes) and c for c in certificates):
        raise DistributionError("The provisioning profile contains no signing certificates")
    return {"uuid": identifier, "expires_at": expiry.isoformat(),
            "certificate_sha1s": [hashlib.sha1(c).hexdigest().upper() for c in certificates]}


def export_options(team, uuid, method):
    if method not in METHODS:
        raise DistributionError("Unsupported export method")
    return {"method": method, "destination": "export", "teamID": team,
            "signingStyle": "manual", "signingCertificate": "Apple Distribution",
            "provisioningProfiles": {BUNDLE_ID: uuid}, "stripSwiftSymbols": True,
            "manageAppVersionAndBuildNumber": False, "uploadSymbols": True}


def build_environment(env):
    # SwiftPM can dump its environment on failure. Never pass signing or GitHub
    # secrets to Xcode, package resolution, project generation or log-producing tools.
    allowed = ("HOME", "PATH", "LANG", "LC_ALL", "TMPDIR", "DEVELOPER_DIR")
    return {key: env[key] for key in allowed if key in env}


def validate_credentials(env, upload):
    decode_secret(env, "IOS_CERTIFICATE_P12_BASE64", 256 * 1024)
    decode_secret(env, "IOS_PROVISION_PROFILE_BASE64", 256 * 1024)
    required(env, "IOS_CERTIFICATE_PASSWORD")
    if not re.fullmatch(r"[A-Z0-9]{10}", required(env, "IOS_TEAM_ID")):
        raise DistributionError("IOS_TEAM_ID must be the ten-character Apple team ID")
    if upload:
        key_id = required(env, "APP_STORE_CONNECT_KEY_ID")
        issuer = required(env, "APP_STORE_CONNECT_ISSUER_ID")
        if not re.fullmatch(r"[A-Z0-9]{10}", key_id) or not re.fullmatch(UUID_PATTERN, issuer):
            raise DistributionError("App Store Connect key or issuer identifier is invalid")
        key = decode_secret(env, "APP_STORE_CONNECT_PRIVATE_KEY_BASE64", 32 * 1024)
        if not key.startswith(b"-----BEGIN PRIVATE KEY-----"):
            raise DistributionError("The App Store Connect key must be a PKCS8 private key")


def command(label, argv, *, env, cwd=None, log=None, timeout=180):
    try:
        result = subprocess.run([str(a) for a in argv], cwd=cwd, env=env,
                                capture_output=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise DistributionError(f"{label} could not complete") from None
    if log:
        log.write_bytes(result.stdout + result.stderr)
    if result.returncode:
        raise DistributionError(f"{label} failed; inspect its build log when available")
    return result.stdout


@contextmanager
def signing_material(work, env, clean):
    certificate = work / "signing.p12"
    profile_file = work / "distribution.mobileprovision"
    certificate.write_bytes(decode_secret(env, "IOS_CERTIFICATE_P12_BASE64", 256 * 1024))
    profile_file.write_bytes(decode_secret(env, "IOS_PROVISION_PROFILE_BASE64", 256 * 1024))
    password = required(env, "IOS_CERTIFICATE_PASSWORD")
    team = required(env, "IOS_TEAM_ID")
    raw = command("Profile decoding", ["security", "cms", "-D", "-i", profile_file], env=clean)
    try:
        profile = plistlib.loads(raw)
    except (plistlib.InvalidFileException, ValueError, TypeError, OverflowError):
        raise DistributionError("The provisioning profile is not valid CMS/plist data") from None
    info = validate_profile(profile, team, env["SHELFARR_EXPORT_METHOD"])
    keychain = work / "signing.keychain-db"
    keychain_password = secrets.token_urlsafe(32)
    original = shlex.split(command("Keychain inventory", ["security", "list-keychains", "-d", "user"], env=clean).decode())
    installed = Path(clean["HOME"]) / "Library/MobileDevice/Provisioning Profiles" / f"{info['uuid']}.mobileprovision"
    created_keychain = False
    changed_search = False
    created_profile = False
    try:
        command("Keychain creation", ["security", "create-keychain", "-p", keychain_password, keychain], env=clean)
        created_keychain = True
        command("Keychain settings", ["security", "set-keychain-settings", "-lut", "21600", keychain], env=clean)
        command("Keychain unlock", ["security", "unlock-keychain", "-p", keychain_password, keychain], env=clean)
        command("Certificate import", ["security", "import", certificate, "-k", keychain,
                                       "-P", password, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"], env=clean)
        command("Signing access", ["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                                   "-s", "-k", keychain_password, keychain], env=clean)
        changed_search = True
        command("Keychain selection", ["security", "list-keychains", "-d", "user", "-s", keychain, *original], env=clean)
        identities = command("Signing identity check", ["security", "find-identity", "-v", "-p", "codesigning", keychain], env=clean).decode()
        identities = re.findall(r"\b[0-9A-F]{40}\b", identities)
        matching = set(identities).intersection(info["certificate_sha1s"])
        if len(matching) != 1:
            raise DistributionError("The imported signing identity does not match the provisioning profile")
        installed.parent.mkdir(parents=True, exist_ok=True)
        if installed.is_symlink() or installed.exists() and installed.read_bytes() != profile_file.read_bytes():
            raise DistributionError("A different profile already uses this UUID; it was not replaced")
        if not installed.exists():
            with installed.open("xb") as handle:
                created_profile = True
                handle.write(profile_file.read_bytes())
            installed.chmod(0o600)
        yield team, info["uuid"], matching.pop()
    finally:
        # Attempt every cleanup even if another cleanup command fails.
        failures = []
        if created_profile:
            try:
                if installed.is_symlink() or installed.exists() and installed.read_bytes() != profile_file.read_bytes():
                    failures.append("profile changed by another process")
                else:
                    installed.unlink(missing_ok=True)
            except OSError:
                failures.append("profile")
        if changed_search:
            try:
                current = shlex.split(command("Keychain inventory", ["security", "list-keychains", "-d", "user"], env=clean).decode())
                remaining = [entry for entry in current if Path(entry).resolve() != keychain.resolve()]
                command("Keychain restoration", ["security", "list-keychains", "-d", "user", "-s", *remaining], env=clean)
            except DistributionError:
                failures.append("keychain search list")
        if created_keychain:
            try:
                command("Keychain deletion", ["security", "delete-keychain", keychain], env=clean)
            except DistributionError:
                failures.append("temporary keychain")
        if failures:
            raise DistributionError("Signing cleanup failed: " + ", ".join(failures))


def verify_app(app, plan, team, uuid, clean):
    command("Signature verification", ["codesign", "--verify", "--deep", "--strict", app], env=clean)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    expected = (plan["bundle_id"], plan["version"], plan["build"])
    actual = tuple(info.get(k) for k in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"))
    if actual != expected or set(info.get("UIDeviceFamily", [])) != {1, 2}:
        raise DistributionError("The signed app does not match the requested iPhone/iPad version")
    raw = command("Signed entitlement check", ["codesign", "-d", "--entitlements", ":-", app], env=clean)
    entitlements = plistlib.loads(raw)
    if (entitlements.get("application-identifier") != f"{team}.{BUNDLE_ID}" or
            entitlements.get("com.apple.developer.team-identifier") != team or entitlements.get("get-task-allow") is not False):
        raise DistributionError("The signed app has the wrong identity or development entitlements")
    raw = command("Embedded profile check", ["security", "cms", "-D", "-i", app / "embedded.mobileprovision"], env=clean)
    embedded = validate_profile(plistlib.loads(raw), team, plan["method"])
    if embedded["uuid"] != uuid:
        raise DistributionError("The signed app did not retain the selected provisioning profile")


def distribute(args, env):
    plan = version_plan(args.version, args.build, args.method, args.upload)
    validate_credentials(env, args.upload)
    if platform.system() != "Darwin":
        raise DistributionError("Signing and export require macOS with Xcode")
    clean = build_environment(env)
    required(clean, "HOME")
    temp_root = Path(env.get("RUNNER_TEMP") or env.get("TMPDIR") or Path(clean["HOME"]) / ".cache/agent-tmp")
    temp_root.mkdir(parents=True, exist_ok=True)
    output = Path(args.output).resolve()
    if output.exists():
        raise DistributionError("Choose a new output directory; previous artifacts are never overwritten")
    output.mkdir(parents=True)
    source = Path(__file__).resolve().parents[1] / "ios"
    commit = command("Source revision", ["git", "rev-parse", "HEAD"], cwd=source, env=clean).decode().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise DistributionError("The source revision could not be established")
    plan["source_commit"] = commit
    config = dict(env, SHELFARR_EXPORT_METHOD=args.method)
    with tempfile.TemporaryDirectory(prefix="shelfarr-ios-signing-", dir=temp_root) as scratch:
        work = Path(scratch)
        clean["TMPDIR"] = str(work)
        with signing_material(work, config, clean) as (team, uuid, identity):
            command("Project generation", ["xcodegen", "generate"], cwd=source, env=clean)
            archive = work / "Shelfarr.xcarchive"
            command("Xcode archive", ["xcodebuild", "-project", "Shelfarr.xcodeproj", "-scheme", "Shelfarr",
                    "-configuration", "Release", "-destination", "generic/platform=iOS", "-derivedDataPath", work / "DerivedData",
                    "-archivePath", archive, "archive", "CODE_SIGN_STYLE=Manual", f"DEVELOPMENT_TEAM={team}",
                    f"CODE_SIGN_IDENTITY={identity}", f"PROVISIONING_PROFILE_SPECIFIER={uuid}",
                    f"MARKETING_VERSION={args.version}", f"CURRENT_PROJECT_VERSION={args.build}"],
                    cwd=source, env=clean, log=output / "archive.log", timeout=3600)
            verify_app(archive / "Products/Applications/Shelfarr.app", plan, team, uuid, clean)
            options = work / "ExportOptions.plist"
            options.write_bytes(plistlib.dumps(export_options(team, uuid, args.method)))
            exported = work / "exported"
            command("Xcode export", ["xcodebuild", "-exportArchive", "-archivePath", archive,
                    "-exportPath", exported, "-exportOptionsPlist", options],
                    env=clean, log=output / "export.log", timeout=900)
            ipas = list(exported.glob("*.ipa"))
            if len(ipas) != 1:
                raise DistributionError("Export did not produce exactly one installable IPA")
            unpacked = work / "verified"
            command("IPA extraction", ["ditto", "-x", "-k", ipas[0], unpacked], env=clean)
            apps = list((unpacked / "Payload").glob("*.app"))
            if len(apps) != 1:
                raise DistributionError("Export did not contain exactly one application")
            verify_app(apps[0], plan, team, uuid, clean)
            ipa = output / f"Shelfarr-{args.version}-{args.build}.ipa"
            shutil.copyfile(ipas[0], ipa)
            symbols = archive / "dSYMs"
            if symbols.is_dir():
                command("Symbol packaging", ["ditto", "-c", "-k", "--keepParent", symbols, output / "Shelfarr.dSYM.zip"], env=clean)
            plan.update(ipa=ipa.name, size_bytes=ipa.stat().st_size, sha256=hashlib.sha256(ipa.read_bytes()).hexdigest(),
                        uploaded=False, physical_device_tested=False)
            (output / "distribution.json").write_text(json.dumps(plan, indent=2) + "\n")
            if args.upload:
                key_id = required(env, "APP_STORE_CONNECT_KEY_ID")
                issuer = required(env, "APP_STORE_CONNECT_ISSUER_ID")
                private_key = decode_secret(env, "APP_STORE_CONNECT_PRIVATE_KEY_BASE64", 32 * 1024)
                (work / f"AuthKey_{key_id}.p8").write_bytes(private_key)
                upload_env = dict(clean, API_PRIVATE_KEYS_DIR=str(work))
                # Upload output is deliberately not stored: it may contain account information.
                command("TestFlight upload", ["xcrun", "altool", "--upload-app", "--type", "ios", "--file", ipa,
                        "--apiKey", key_id, "--apiIssuer", issuer], env=upload_env, timeout=1800)
                plan["uploaded"] = True
            (output / "distribution.json").write_text(json.dumps(plan, indent=2) + "\n")
    return plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "preflight", "distribute"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--method", choices=METHODS, default="app-store-connect")
    parser.add_argument("--upload", action="store_true")
    parser.add_argument("--output", default="apps/ios/build/distribution")
    args = parser.parse_args()
    os.umask(0o077)

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    try:
        if args.command == "distribute":
            result = distribute(args, os.environ)
        else:
            result = version_plan(args.version, args.build, args.method, args.upload)
            if args.command == "preflight":
                validate_credentials(os.environ, args.upload)
        print(json.dumps(result))
        return 0
    except (DistributionError, OSError, ValueError, plistlib.InvalidFileException) as error:
        message = str(error) if isinstance(error, DistributionError) else "Distribution failed while handling build files"
        print(message, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Distribution interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
