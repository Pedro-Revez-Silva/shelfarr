"""Signing-policy, environment isolation and cleanup checks; no Apple secrets."""

import base64
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
from types import SimpleNamespace
from unittest import mock

from support import ScratchCase, SCRIPTS


SCRIPT = SCRIPTS / "ios-distribute.py"
SPEC = importlib.util.spec_from_file_location("ios_distribution", SCRIPT)
distribution = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(distribution)
TEAM = "ABCDE12345"
UUID = "12345678-1234-1234-1234-123456789abc"
CERTIFICATE = b"synthetic-public-certificate"


def profile():
    return {"UUID": UUID, "TeamIdentifier": [TEAM],
            "ExpirationDate": datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=1),
            "DeveloperCertificates": [CERTIFICATE], "Entitlements": {
                "application-identifier": f"{TEAM}.org.shelfarr.app",
                "com.apple.developer.team-identifier": TEAM, "get-task-allow": False}}


class IOSDistributionTest(ScratchCase):
    def test_cli_plan_is_portable_and_does_not_require_or_expose_credentials(self):
        result = self.run_script(SCRIPT, "plan", "--version", "2026.11.9", "--build", "5")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"bundle_id": "org.shelfarr.app"', result.stdout)
        self.assertIn('"upload_requested": false', result.stdout)

    def test_versions_cannot_inject_paths_or_unusable_apple_versions(self):
        for version, build in (("2026.11.9.1", "5"), ("2026.13.1", "5"),
                               ("2026.11.9", "../5"), ("2026.11.9", "5;echo"),
                               ("2026.11.9", "10000"), ("2026.11.9", "5.100")):
            with self.subTest(version=version, build=build):
                result = self.run_script(SCRIPT, "plan", "--version", version, "--build", build)
                self.assertNotEqual(0, result.returncode)

    def test_registered_device_export_cannot_be_uploaded_as_testflight(self):
        with self.assertRaises(distribution.DistributionError):
            distribution.version_plan("2026.11.9", "5", "release-testing", upload=True)

    def test_a_distribution_profile_must_match_team_app_expiry_and_method(self):
        mutations = [
            {"TeamIdentifier": ["OTHER12345"]},
            {"UUID": "-" * 36},
            {"ExpirationDate": datetime(2000, 1, 1)},
            {"ExpirationDate": "tomorrow"},
            {"ProvisionsAllDevices": True},
            {"ProvisionedDevices": ["synthetic-ipad"]},
            {"DeveloperCertificates": []},
        ]
        for mutation in mutations:
            candidate = {**profile(), **mutation}
            with self.subTest(mutation=list(mutation)):
                with self.assertRaises(distribution.DistributionError):
                    distribution.validate_profile(candidate, TEAM, "app-store-connect")
        for name, value in (("application-identifier", f"{TEAM}.*"),
                            ("application-identifier", f"{TEAM}.another.app"),
                            ("com.apple.developer.team-identifier", "OTHER12345"),
                            ("get-task-allow", True), ("get-task-allow", None)):
            candidate = profile()
            candidate["Entitlements"][name] = value
            with self.subTest(entitlement=name, value=value):
                with self.assertRaises(distribution.DistributionError):
                    distribution.validate_profile(candidate, TEAM, "app-store-connect")

    def test_valid_profiles_report_no_private_device_or_account_fields(self):
        original = profile()
        info = distribution.validate_profile(original, TEAM, "app-store-connect")
        self.assertEqual(UUID, info["uuid"])
        self.assertEqual([hashlib.sha1(CERTIFICATE).hexdigest().upper()], info["certificate_sha1s"])
        self.assertNotIn("Entitlements", info)
        original["ProvisionedDevices"] = ["synthetic-ipad"]
        self.assertEqual(info, distribution.validate_profile(original, TEAM, "release-testing"))

    def test_release_testing_requires_registered_devices(self):
        for devices in (None, [], [None], [""]):
            with self.subTest(devices=devices):
                candidate = {**profile(), "ProvisionedDevices": devices}
                with self.assertRaises(distribution.DistributionError):
                    distribution.validate_profile(candidate, TEAM, "release-testing")

    def test_export_never_rewrites_versions_or_selects_another_profile(self):
        options = distribution.export_options(TEAM, UUID, "app-store-connect")
        self.assertEqual({"org.shelfarr.app": UUID}, options["provisioningProfiles"])
        self.assertEqual("export", options["destination"])
        self.assertFalse(options["manageAppVersionAndBuildNumber"])

    def test_swiftpm_and_xcode_do_not_inherit_signing_or_github_secrets(self):
        env = {"HOME": "/private-home", "PATH": "/usr/bin", "TMPDIR": str(self.dir),
               "IOS_CERTIFICATE_PASSWORD": "synthetic-password", "GH_TOKEN": "synthetic-token",
               "APP_STORE_CONNECT_PRIVATE_KEY_BASE64": "synthetic-key", "GITHUB_TOKEN": "another-token"}
        clean = distribution.build_environment(env)
        self.assertEqual({"HOME": "/private-home", "PATH": "/usr/bin", "TMPDIR": str(self.dir)}, clean)

    def test_bad_base64_errors_do_not_echo_input(self):
        with self.assertRaises(distribution.DistributionError) as caught:
            distribution.decode_secret({"PRIVATE": "synthetic-secret!!"}, "PRIVATE", 1024)
        self.assertNotIn("synthetic-secret", str(caught.exception))

    def test_export_does_not_require_upload_credentials_but_upload_checks_them_before_building(self):
        env, _, _, _, _, _ = self.signing_fixture()
        distribution.validate_credentials(env, upload=False)
        with self.assertRaisesRegex(distribution.DistributionError, "APP_STORE_CONNECT_KEY_ID"):
            distribution.validate_credentials(env, upload=True)
        env.update(APP_STORE_CONNECT_KEY_ID="ABCDE67890", APP_STORE_CONNECT_ISSUER_ID=UUID,
                   APP_STORE_CONNECT_PRIVATE_KEY_BASE64=base64.b64encode(b"-----BEGIN PRIVATE KEY-----\nsynthetic").decode())
        distribution.validate_credentials(env, upload=True)
        env["APP_STORE_CONNECT_PRIVATE_KEY_BASE64"] = base64.b64encode(b"wrong file").decode()
        with self.assertRaisesRegex(distribution.DistributionError, "PKCS8"):
            distribution.validate_credentials(env, upload=True)

    def test_tool_failures_do_not_echo_the_command_or_its_output(self):
        with self.assertRaises(distribution.DistributionError) as caught:
            distribution.command("Test tool", [sys.executable, "-c", "print('synthetic-secret');exit(1)"], env={})
        self.assertNotIn("synthetic-secret", str(caught.exception))

    def signing_fixture(self, candidate=None):
        raw = plistlib.dumps(candidate or profile())
        env = {"IOS_TEAM_ID": TEAM, "IOS_CERTIFICATE_PASSWORD": "synthetic-password",
               "IOS_CERTIFICATE_P12_BASE64": base64.b64encode(b"synthetic-p12").decode(),
               "IOS_PROVISION_PROFILE_BASE64": base64.b64encode(raw).decode(),
               "SHELFARR_EXPORT_METHOD": "app-store-connect"}
        clean = {"HOME": str(self.dir / "home"), "PATH": "/usr/bin"}
        installed = Path(clean["HOME"]) / "Library/MobileDevice/Provisioning Profiles" / f"{UUID}.mobileprovision"
        labels = []

        def command(label, argv, **kwargs):
            labels.append(label)
            if label == "Profile decoding":
                return raw
            if label == "Keychain inventory":
                return b'"/existing/login.keychain-db"\n'
            if label == "Signing identity check":
                return hashlib.sha1(CERTIFICATE).hexdigest().upper().encode()
            return b""

        return env, clean, installed, labels, command, raw

    def test_failed_build_restores_keychains_and_removes_only_its_own_profile(self):
        env, clean, installed, labels, command, _ = self.signing_fixture()
        with mock.patch.object(distribution, "command", side_effect=command):
            with self.assertRaisesRegex(distribution.DistributionError, "synthetic build failure"):
                with distribution.signing_material(self.dir, env, clean):
                    self.assertTrue(installed.exists())
                    raise distribution.DistributionError("synthetic build failure")
        self.assertFalse(installed.exists())
        self.assertEqual(["Keychain restoration", "Keychain deletion"], labels[-2:])

    def test_existing_identical_profile_is_preserved(self):
        env, clean, installed, _, command, raw = self.signing_fixture()
        installed.parent.mkdir(parents=True)
        installed.write_bytes(raw)
        with mock.patch.object(distribution, "command", side_effect=command):
            with distribution.signing_material(self.dir, env, clean):
                pass
        self.assertEqual(raw, installed.read_bytes())

    def test_existing_different_profile_is_never_overwritten(self):
        env, clean, installed, labels, command, _ = self.signing_fixture()
        installed.parent.mkdir(parents=True)
        installed.write_bytes(b"original profile")
        with mock.patch.object(distribution, "command", side_effect=command):
            with self.assertRaisesRegex(distribution.DistributionError, "not replaced"):
                with distribution.signing_material(self.dir, env, clean):
                    self.fail("must not yield")
        self.assertEqual(b"original profile", installed.read_bytes())
        self.assertEqual("Keychain deletion", labels[-1])

    def test_a_cleanup_failure_does_not_skip_other_cleanup(self):
        env, clean, installed, labels, command, _ = self.signing_fixture()

        def failing_restore(label, argv, **kwargs):
            result = command(label, argv, **kwargs)
            if label == "Keychain restoration":
                raise distribution.DistributionError("synthetic restore failure")
            return result

        with mock.patch.object(distribution, "command", side_effect=failing_restore):
            with self.assertRaisesRegex(distribution.DistributionError, "cleanup failed"):
                with distribution.signing_material(self.dir, env, clean):
                    pass
        self.assertFalse(installed.exists())
        self.assertEqual("Keychain deletion", labels[-1])

    def test_cleanup_preserves_profiles_and_keychains_changed_by_another_process(self):
        env, clean, installed, _, command, _ = self.signing_fixture()
        inventories = 0
        restored = []

        def concurrent_changes(label, argv, **kwargs):
            nonlocal inventories
            result = command(label, argv, **kwargs)
            if label == "Keychain inventory":
                inventories += 1
                if inventories > 1:
                    return f'"{self.dir}/signing.keychain-db"\n"/another/new.keychain-db"\n'.encode()
            if label == "Keychain restoration":
                restored.extend(argv[5:])
            return result

        with mock.patch.object(distribution, "command", side_effect=concurrent_changes):
            with self.assertRaisesRegex(distribution.DistributionError, "profile changed"):
                with distribution.signing_material(self.dir, env, clean):
                    installed.write_bytes(b"profile replaced by Xcode")
        self.assertEqual(b"profile replaced by Xcode", installed.read_bytes())
        self.assertEqual(["/another/new.keychain-db"], restored)

    def test_an_unrelated_certificate_cannot_sign_the_profile(self):
        env, clean, installed, labels, command, _ = self.signing_fixture()

        def wrong_identity(label, argv, **kwargs):
            result = command(label, argv, **kwargs)
            return b"A" * 40 if label == "Signing identity check" else result

        with mock.patch.object(distribution, "command", side_effect=wrong_identity):
            with self.assertRaisesRegex(distribution.DistributionError, "does not match"):
                with distribution.signing_material(self.dir, env, clean):
                    self.fail("must not yield")
        self.assertFalse(installed.exists())
        self.assertEqual("Keychain deletion", labels[-1])

    def test_signed_app_identity_device_families_and_embedded_profile_are_checked(self):
        app = self.dir / "Shelfarr.app"
        app.mkdir()
        info = {"CFBundleIdentifier": "org.shelfarr.app", "CFBundleShortVersionString": "2026.11.9",
                "CFBundleVersion": "5", "UIDeviceFamily": [1, 2]}
        plan = distribution.version_plan("2026.11.9", "5", "app-store-connect")
        original = profile()

        def command(label, argv, **kwargs):
            if label == "Signed entitlement check":
                return plistlib.dumps(original["Entitlements"])
            if label == "Embedded profile check":
                return plistlib.dumps(original)
            return b""

        with mock.patch.object(distribution, "command", side_effect=command):
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            distribution.verify_app(app, plan, TEAM, UUID, {})
            for key, bad in (("CFBundleIdentifier", "another.app"), ("CFBundleVersion", "4"),
                             ("CFBundleShortVersionString", "0.1.0"), ("UIDeviceFamily", [1])):
                candidate = copy.deepcopy(info)
                candidate[key] = bad
                (app / "Info.plist").write_bytes(plistlib.dumps(candidate))
                with self.subTest(key=key):
                    with self.assertRaises(distribution.DistributionError):
                        distribution.verify_app(app, plan, TEAM, UUID, {})
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            original["UUID"] = "abcdefab-1234-1234-1234-123456789abc"
            with self.assertRaisesRegex(distribution.DistributionError, "selected provisioning profile"):
                distribution.verify_app(app, plan, TEAM, UUID, {})

    def distribution_fixture(self, upload=False, wrong_export=False, fail_upload=False):
        env, clean, installed, labels, signing_command, _ = self.signing_fixture()
        env.update(clean, RUNNER_TEMP=str(self.dir / "scratch"))
        if upload:
            env.update(APP_STORE_CONNECT_KEY_ID="ABCDE67890", APP_STORE_CONNECT_ISSUER_ID=UUID,
                       APP_STORE_CONNECT_PRIVATE_KEY_BASE64=base64.b64encode(b"-----BEGIN PRIVATE KEY-----\nsynthetic").decode())
        args = SimpleNamespace(version="2026.11.9", build="5", method="app-store-connect",
                               upload=upload, output=str(self.dir / "output"))
        build_environments = []

        def app_at(path, wrong=False):
            path.mkdir(parents=True)
            info = {"CFBundleIdentifier": distribution.BUNDLE_ID, "CFBundleShortVersionString": args.version,
                    "CFBundleVersion": "4" if wrong else args.build, "UIDeviceFamily": [1, 2]}
            (path / "Info.plist").write_bytes(plistlib.dumps(info))

        def command(label, argv, **kwargs):
            build_environments.append(kwargs["env"])
            result = signing_command(label, argv, **kwargs)
            if kwargs.get("log"):
                kwargs["log"].write_text("synthetic build log\n")
            if label == "Source revision":
                return b"b" * 40
            if label == "Xcode archive":
                app_at(Path(argv[argv.index("-archivePath") + 1]) / "Products/Applications/Shelfarr.app")
            if label == "Xcode export":
                exported = Path(argv[argv.index("-exportPath") + 1])
                exported.mkdir()
                (exported / "Shelfarr.ipa").write_bytes(b"synthetic verified IPA")
            if label == "IPA extraction":
                app_at(Path(argv[-1]) / "Payload/Shelfarr.app", wrong=wrong_export)
            if label == "Signed entitlement check":
                return plistlib.dumps(profile()["Entitlements"])
            if label == "Embedded profile check":
                return plistlib.dumps(profile())
            if label == "TestFlight upload" and fail_upload:
                raise distribution.DistributionError("synthetic upload failure")
            return result

        return env, args, installed, labels, build_environments, command

    def test_complete_export_verifies_artifacts_and_removes_signing_material(self):
        env, args, installed, labels, environments, command = self.distribution_fixture()
        with mock.patch.object(distribution.platform, "system", return_value="Darwin"), \
                mock.patch.object(distribution, "command", side_effect=command):
            result = distribution.distribute(args, env)
        self.assertFalse(result["uploaded"])
        self.assertEqual("b" * 40, result["source_commit"])
        output = Path(args.output)
        ipa = output / result["ipa"]
        self.assertEqual(hashlib.sha256(ipa.read_bytes()).hexdigest(), result["sha256"])
        self.assertEqual(result, json.loads((output / "distribution.json").read_text()))
        self.assertEqual(2, labels.count("Signature verification"))
        self.assertEqual(2, labels.count("Embedded profile check"))
        self.assertFalse(installed.exists())
        self.assertEqual([], list((self.dir / "scratch").iterdir()))
        for child_env in environments:
            self.assertNotIn("IOS_CERTIFICATE_PASSWORD", child_env)
            self.assertNotIn("IOS_CERTIFICATE_P12_BASE64", child_env)

    def test_wrong_exported_version_never_becomes_an_installable_artifact(self):
        env, args, installed, _, _, command = self.distribution_fixture(wrong_export=True)
        with mock.patch.object(distribution.platform, "system", return_value="Darwin"), \
                mock.patch.object(distribution, "command", side_effect=command):
            with self.assertRaisesRegex(distribution.DistributionError, "requested iPhone/iPad version"):
                distribution.distribute(args, env)
        self.assertEqual([], list(Path(args.output).glob("*.ipa")))
        self.assertFalse(installed.exists())
        self.assertEqual([], list((self.dir / "scratch").iterdir()))

    def test_failed_upload_keeps_the_verified_ipa_and_manifest_but_no_signing_secrets(self):
        env, args, installed, _, environments, command = self.distribution_fixture(upload=True, fail_upload=True)
        with mock.patch.object(distribution.platform, "system", return_value="Darwin"), \
                mock.patch.object(distribution, "command", side_effect=command):
            with self.assertRaisesRegex(distribution.DistributionError, "synthetic upload failure"):
                distribution.distribute(args, env)
        report = json.loads((Path(args.output) / "distribution.json").read_text())
        self.assertFalse(report["uploaded"])
        self.assertTrue((Path(args.output) / report["ipa"]).exists())
        self.assertFalse(installed.exists())
        self.assertEqual([], list((self.dir / "scratch").iterdir()))
        for child_env in environments:
            self.assertNotIn("APP_STORE_CONNECT_PRIVATE_KEY_BASE64", child_env)
