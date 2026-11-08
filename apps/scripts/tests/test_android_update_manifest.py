import hashlib
import json
import os
import unittest
from pathlib import Path

from support import (
    MANIFEST, OTHER_SIGNER, SIGNER, ScratchCase, aapt2_output, apksigner_output, asset_url, make_sdk,
)

FEED_URL = "https://example.org/downloads/android-development.json"
DIRECT_APK_URL = "https://example.org/downloads/shelfarr-android-development-3.apk"
RELEASE_URL = asset_url("release", "2026.11.8.1", 12)
# A real debug build kept from an earlier preview, when this machine still has it.
REAL_APK = Path("/home/pedro/.local/share/agent-reports/shelfarr/android-navigation-update-20261108/Shelfarr-development-3.apk")


class ManifestCase(ScratchCase):
    def setUp(self):
        super().setUp()
        self.sdk = make_sdk(self.dir)
        self.apk = self.dir / "app.apk"
        self.apk.write_bytes(b"PK\x03\x04 not really an APK, but the tools are stubs" * 50)
        self.tools(apksigner_output(SIGNER), aapt2_output())

    def tools(self, signers: str, badging: str, exit_code: int = 0) -> None:
        (self.dir / "apksigner.out").write_text(signers)
        (self.dir / "aapt2.out").write_text(badging)
        self.tool_env = {
            "ANDROID_HOME": str(self.sdk),
            "STUB_APKSIGNER": str(self.dir / "apksigner.out"),
            "STUB_AAPT2": str(self.dir / "aapt2.out"),
            "STUB_APKSIGNER_EXIT": str(exit_code),
        }

    def generate(self, *arguments):
        return self.run_script(MANIFEST, "--apk", self.apk, *arguments, env=self.tool_env)

    def catalog_entry(self, *extra, url=RELEASE_URL, channel="release", package="org.shelfarr.app"):
        output = self.dir / "entry.json"
        result = self.generate(
            "--catalog-entry", "--apk-url", url, "--channel", channel, "--package", package,
            "--signer-sha256", SIGNER, "--output", output, *extra,
        )
        return result, output

    def assertRefused(self, result, text):
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn(text, result.stderr)


class DirectFeedTest(ManifestCase):
    def setUp(self):
        super().setUp()
        self.tools(apksigner_output(SIGNER), aapt2_output("org.shelfarr.app.debug", 3, "2026.11.8.1-debug"))

    def direct(self, *extra, apk_url=DIRECT_APK_URL):
        return self.generate("--feed-url", FEED_URL, "--apk-url", apk_url, "--channel", "development",
                             "--package", "org.shelfarr.app.debug", *extra)

    def test_writes_the_schema_1_feed_as_before_plus_api_generations(self):
        result = self.direct("--signer-sha256", SIGNER.upper(), "--previous-version-code", "2")
        self.assertEqual(result.returncode, 0, result.stderr)
        feed = json.loads(result.stdout)
        self.assertEqual(feed, {
            "schema_version": 1,
            "channel": "development",
            "package_name": "org.shelfarr.app.debug",
            "version_code": 3,
            "version_name": "2026.11.8.1-debug",
            "apk_url": DIRECT_APK_URL,
            "size_bytes": self.apk.stat().st_size,
            "sha256": hashlib.sha256(self.apk.read_bytes()).hexdigest(),
            "min_sdk": 26,
            "consumer_api_versions": [1],
        })

    def test_keeps_the_feed_directory_rule(self):
        self.assertRefused(self.direct(apk_url="https://example.org/elsewhere/a.apk"), "inside the feed's directory")
        self.assertRefused(self.direct(apk_url="https://cdn.example.org/downloads/a.apk"), "feed's origin")
        # A GitHub release asset is only for catalog entries.
        self.assertRefused(self.direct(apk_url=asset_url("development", "2026.11.8.1", 3)), "feed's origin")
        self.assertRefused(self.direct(apk_url="https://example.org/downloads/a.apk?x=1"), "query")
        self.assertRefused(self.direct(apk_url="https://example.org/downloads/%2e%2e/a.apk"), "encoded separators")

    def test_needs_a_feed_url(self):
        result = self.generate("--apk-url", DIRECT_APK_URL, "--package", "org.shelfarr.app.debug")
        self.assertRefused(result, "needs --feed-url")

    def test_still_refuses_a_version_that_does_not_grow_and_a_wrong_signer(self):
        self.assertRefused(self.direct("--previous-version-code", "3"), "must be larger")
        self.assertRefused(self.direct("--signer-sha256", OTHER_SIGNER), "not the expected certificate")

    def test_writes_the_output_file_whole_and_readable(self):
        output = self.dir / "feed.json"
        result = self.direct("--output", output, "--consumer-api", "2", "--consumer-api", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(output.read_text())["consumer_api_versions"], [1, 2])
        self.assertEqual(output.stat().st_mode & 0o777, 0o644)
        self.assertEqual([p.name for p in self.dir.glob(".feed.json.*")], [])


class CatalogEntryTest(ManifestCase):
    def test_writes_a_catalog_entry_for_a_github_release_asset(self):
        notes = self.dir / "notes.txt"
        notes.write_text("Faster sync.\r\n")
        result, output = self.catalog_entry("--expect-version-code", "12", "--expect-version-name", "2026.11.8.1",
                                            "--consumer-api", "1", "--notes-file", notes)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(output.read_text()), {
            "channel": "release",
            "package_name": "org.shelfarr.app",
            "version_code": 12,
            "version_name": "2026.11.8.1",
            "apk_url": RELEASE_URL,
            "size_bytes": self.apk.stat().st_size,
            "sha256": hashlib.sha256(self.apk.read_bytes()).hexdigest(),
            "release_notes": "Faster sync.",
            "min_sdk": 26,
            "consumer_api_versions": [1],
        })

    def test_a_development_build_may_be_debuggable(self):
        self.tools(apksigner_output(SIGNER), aapt2_output("org.shelfarr.app.debug", 4, "2026.11.8.1-debug", debuggable=True))
        result, _ = self.catalog_entry(url=asset_url("development", "2026.11.8.1", 4), channel="development",
                                       package="org.shelfarr.app.debug")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_requires_a_signer_and_exactly_that_signer(self):
        result = self.generate("--catalog-entry", "--apk-url", RELEASE_URL, "--channel", "release", "--package", "org.shelfarr.app")
        self.assertRefused(result, "needs --signer-sha256")
        self.tools(apksigner_output(SIGNER, OTHER_SIGNER), aapt2_output())
        self.assertRefused(self.catalog_entry()[0], "not the expected certificate")
        self.tools(apksigner_output(OTHER_SIGNER), aapt2_output())
        self.assertRefused(self.catalog_entry()[0], "not the expected certificate")
        self.tools(apksigner_output(SIGNER, v2=False), aapt2_output())
        self.assertRefused(self.catalog_entry()[0], "v2 or v3")
        self.tools("DOES NOT VERIFY\n", aapt2_output(), exit_code=1)
        self.assertRefused(self.catalog_entry()[0], "apksigner failed")

    def test_refuses_metadata_servers_or_phones_would_not_accept(self):
        cases = [
            (aapt2_output(package="org.shelfarr.app.debug"), "expected org.shelfarr.app"),
            (aapt2_output(name="0.1.1"), "not a calendar version"),
            (aapt2_output(name="2026.13.1"), "not a calendar version"),
            (aapt2_output(code=0), "out of range"),
            (aapt2_output(min_sdk=None), "no minimum SDK"),
            (aapt2_output(debuggable=True), "must not be debuggable"),
            (aapt2_output(test_only=True), "testOnly"),
            ("nothing useful\n", "could not read the package line"),
        ]
        for badging, message in cases:
            with self.subTest(message):
                self.tools(apksigner_output(SIGNER), badging)
                self.assertRefused(self.catalog_entry()[0], message)

    def test_checks_the_expected_version(self):
        self.assertRefused(self.catalog_entry("--expect-version-code", "13")[0], "expected 13")
        self.assertRefused(self.catalog_entry("--expect-version-name", "2026.11.8.2")[0], "expected '2026.11.8.2'")
        self.assertRefused(self.catalog_entry("--previous-version-code", "12")[0], "must be larger")

    def test_channel_and_package_must_belong_together(self):
        result, _ = self.catalog_entry(channel="development", url=asset_url("development", "2026.11.8.1", 12))
        self.assertRefused(result, "the development channel is the org.shelfarr.app.debug package")

    def test_api_generations_must_be_positive_distinct_numbers(self):
        self.assertRefused(self.catalog_entry("--consumer-api", "0")[0], "from 1 to 1000")
        self.assertRefused(self.catalog_entry("--consumer-api", "1", "--consumer-api", "1")[0], "must not repeat")

    def test_only_release_assets_of_the_catalog_repository(self):
        cases = [
            ("https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/android-catalog-v1/a.apk", "mutable"),
            ("https://github.com/someone/shelfarr/releases/download/android-release-v2026.11.8.1/a.apk", "release asset of"),
            ("https://github.com/Pedro-Revez-Silva/shelfarr/raw/main/a.apk", "release asset of"),
            ("https://github.com:8443/Pedro-Revez-Silva/shelfarr/releases/download/t/a.apk", "release asset of"),
            ("https://objects.githubusercontent.com/Pedro-Revez-Silva/shelfarr/releases/download/t/a.apk", "release asset of"),
            ("http://github.com/Pedro-Revez-Silva/shelfarr/releases/download/t/a.apk", "https"),
            (RELEASE_URL + "?token=1", "query"),
            ("https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/t/a%41.apk", "percent"),
            ("https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/t/../a.apk", "clean path"),
            ("https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/t/a.zip", "ending in .apk"),
        ]
        for url, message in cases:
            with self.subTest(url):
                self.assertRefused(self.catalog_entry(url=url)[0], message)
        result = self.generate("--catalog-entry", "--feed-url", FEED_URL, "--apk-url", RELEASE_URL,
                               "--package", "org.shelfarr.app", "--channel", "release", "--signer-sha256", SIGNER)
        self.assertRefused(result, "--feed-url is for a direct feed")

    def test_a_custom_catalog_keeps_apks_on_its_origin(self):
        custom = ("--catalog-url", "https://apps.example.org/shelfarr/catalog.json")
        ok, _ = self.catalog_entry(*custom, url="https://apps.example.org/shelfarr/release/12.apk")
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertRefused(self.catalog_entry(*custom, url=RELEASE_URL)[0], "catalog's origin")


@unittest.skipUnless(REAL_APK.is_file(), "no real APK kept on this machine")
class RealApkTest(ManifestCase):
    """The real bytes of an earlier build; the SDK tools are still stubs here."""

    def test_size_and_digest_come_from_the_real_file(self):
        self.apk = REAL_APK
        self.tools(apksigner_output(SIGNER), aapt2_output("org.shelfarr.app.debug", 3, "2026.11.8.3-debug"))
        result, output = self.catalog_entry(url=asset_url("development", "2026.11.8.3", 3), channel="development",
                                            package="org.shelfarr.app.debug")
        self.assertEqual(result.returncode, 0, result.stderr)
        written = json.loads(output.read_text())
        self.assertEqual(written["size_bytes"], os.path.getsize(REAL_APK))
        self.assertEqual(written["sha256"], hashlib.sha256(REAL_APK.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
