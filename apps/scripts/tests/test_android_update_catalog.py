import argparse
import hashlib
import json
import os
import unittest

from support import (
    CATALOG, CATALOG_URL, COMMIT, REPO, FakeGitHub, ScratchCase, asset_url, catalog, entry, load,
)

module = load(CATALOG, "android_update_catalog")


class LocalCase(ScratchCase):
    def cli(self, *arguments, env=None):
        return self.run_script(CATALOG, *arguments, env=env)

    def assertRefused(self, result, text):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(text, result.stderr)

    def add(self, previous, new_entry, *extra):
        entry_path = self.write_json("entry.json", new_entry)
        output = self.dir / "out.json"
        source = ["--no-previous"] if previous is None else ["--previous", self.write_json("previous.json", previous)]
        result = self.cli("add", *source, "--entry", entry_path, "--output", output, *extra)
        written = json.loads(output.read_text()) if output.exists() else None
        return result, written


class ValidationTest(LocalCase):
    def check(self, document):
        path = self.dir / "catalog.json"
        path.write_bytes(document if isinstance(document, bytes) else json.dumps(document).encode())
        return self.cli("check", path)

    def test_accepts_a_well_formed_catalog(self):
        result = self.check(catalog(entry(10), entry(11, apis=(1, 2)), entry(3, channel="development")))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_custom_publisher_urls_are_readable_by_the_ruby_consumer(self):
        catalog_url = "https://apps.example.org/catalog.json"
        for path in ("é.apk", "a\x00.apk", "a\x7f.apk"):
            with self.subTest(path=path):
                invalid = dict(entry(10), apk_url=f"https://apps.example.org/{path}")
                with self.assertRaisesRegex(module.CatalogError, "printable ASCII"):
                    module.validate_entry(invalid, catalog_url)

    def test_refuses_malformed_documents(self):
        cases = [
            (b'{"schema_version": 1, "releases": [], "releases": []}', "duplicate key"),
            (b'{"schema_version": 1, "releases": [NaN]}', "not JSON"),
            (b"\xff\xfe", "not UTF-8"),
            (b"[]", "exactly schema_version and releases"),
            ({"schema_version": 2, "releases": []}, "schema_version is not 1"),
            ({"schema_version": True, "releases": []}, "schema_version is not 1"),
            ({"schema_version": 1, "releases": {}}, "must be a list"),
            ({"schema_version": 1, "releases": [], "extra": 1}, "exactly schema_version"),
            (catalog(*[entry(code) for code in range(1, 102)]), "more than 100"),
            (b" " * (1024 * 1024 + 1), "larger than"),
        ]
        for document, message in cases:
            with self.subTest(message):
                self.assertRefused(self.check(document), message)

    def test_refuses_bad_releases(self):
        cases = [
            (entry(10, version_code=True), "version_code must be a whole number"),
            (entry(10, version_code=10.0), "version_code must be a whole number"),
            (entry(10, version_code=2_100_000_001), "version_code must be a whole number"),
            (dict(entry(10), channel="beta"), "unknown channel"),
            (dict(entry(10), package_name="org.shelfarr.app.debug"), "unknown channel and package"),
            (dict(entry(10), version_name="1.2.3"), "not a calendar version"),
            (dict(entry(10), sha256="AB" * 32), "lowercase hex"),
            (dict(entry(10), size_bytes=0), "size_bytes"),
            (dict(entry(10), min_sdk=0), "min_sdk"),
            (dict(entry(10), release_notes="  "), "non-blank"),
            (dict(entry(10), release_notes="x" * 4001), "at most 4000"),
            (dict(entry(10), consumer_api_versions=[]), "1 to 16"),
            (dict(entry(10), consumer_api_versions=[2, 1]), "must be sorted"),
            (dict(entry(10), consumer_api_versions=[1, 1]), "must not repeat"),
            (dict(entry(10), consumer_api_versions=[1001]), "from 1 to 1000"),
            (dict(entry(10), apk_url="https://example.org/a.apk"), "release asset of"),
            (dict(entry(10), apk_url=asset_url("release", "x", 10).replace("android-release-vx", "android-catalog-v1")), "mutable"),
            (dict(entry(10), extra=1), "unknown fields extra"),
            ({k: v for k, v in entry(10).items() if k != "consumer_api_versions"}, "missing consumer_api_versions"),
        ]
        for release, message in cases:
            with self.subTest(message):
                self.assertRefused(self.check(catalog(release)), message)

    def test_refuses_two_releases_with_the_same_identity(self):
        cases = [
            (entry(10), entry(10, sha="0" * 64), "version code"),
            (entry(10), dict(entry(11), version_name=entry(10)["version_name"]), "version name"),
            (entry(10), dict(entry(11), apk_url=entry(10)["apk_url"]), "APK URL"),
            (entry(10), entry(11, sha=entry(10)["sha256"]), "SHA-256"),
        ]
        for first, second, message in cases:
            with self.subTest(message):
                self.assertRefused(self.check(catalog(first, second)), f"share the {message}")


class AddTest(LocalCase):
    def test_starts_a_catalog_only_when_told_there_is_none(self):
        result, written = self.add(None, entry(10))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "added")
        self.assertEqual(written, catalog(entry(10)))
        output = self.dir / "out.json"
        self.assertEqual(output.stat().st_mode & 0o777, 0o644)
        result = self.cli("add", "--entry", self.write_json("e.json", entry(10)), "--output", output)
        self.assertRefused(result, "one of the arguments --previous --no-previous is required")

    def test_republishing_the_same_release_changes_nothing(self):
        previous = catalog(entry(11), entry(10))
        result, written = self.add(previous, entry(11))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "unchanged")
        self.assertEqual(written, previous)

    def test_a_published_version_never_changes(self):
        previous = catalog(entry(11), entry(10))
        for changed, field in [
            (entry(11, sha="0" * 64), "sha256"),
            (dict(entry(11), size_bytes=5), "size_bytes"),
            (dict(entry(11), release_notes="New notes"), "release_notes"),
            (entry(11, apis=(1, 2)), "consumer_api_versions"),
        ]:
            with self.subTest(field):
                result, _ = self.add(previous, changed)
                self.assertRefused(result, f"already published with different {field}")
        result, _ = self.add(previous, dict(entry(11), version_name="2026.11.99", apk_url=asset_url("release", "2026.11.99", 11)))
        self.assertRefused(result, "already published as 2026.11.11")

    def test_version_codes_only_grow_within_a_package(self):
        previous = catalog(entry(20, apis=(1, 2)), entry(15))
        self.assertRefused(self.add(previous, entry(19))[0], "larger than every published org.shelfarr.app build (highest 20)")
        self.assertRefused(self.add(previous, entry(12))[0], "highest 20")
        # The development app is a separate package with its own codes.
        result, _ = self.add(previous, entry(3, channel="development"))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_retained_labels_urls_and_bytes_are_not_reused(self):
        previous = catalog(entry(10))
        reused_label = dict(entry(11), version_name=entry(10)["version_name"])
        self.assertRefused(self.add(previous, reused_label)[0], "version name 2026.11.10 is already published")
        reused_bytes = entry(11, sha=entry(10)["sha256"])
        self.assertRefused(self.add(previous, reused_bytes)[0], "share the SHA-256")

    def test_keeps_the_newest_two_of_each_api_line(self):
        previous = catalog(entry(12), entry(11), entry(4, channel="development"), entry(3, channel="development"))
        _, written = self.add(previous, entry(13))
        self.assertEqual([r["version_code"] for r in written["releases"]], [13, 12, 4, 3])

        # A generation-2 build starts its own line; generation-1 servers keep the old one.
        _, written = self.add(written, entry(20, apis=(2,)))
        _, written = self.add(written, entry(21, apis=(2,)))
        _, written = self.add(written, entry(22, apis=(2,)))
        codes = [(r["version_code"], r["consumer_api_versions"]) for r in written["releases"] if r["channel"] == "release"]
        self.assertEqual(codes, [(22, [2]), (21, [2]), (13, [1]), (12, [1])])

        result, written = self.add(written, entry(23, apis=(1, 2)), "--keep", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        codes = [r["version_code"] for r in written["releases"] if r["channel"] == "release"]
        self.assertEqual(codes, [23, 22, 13])

    def test_a_malformed_previous_catalog_stops_the_publication(self):
        path = self.dir / "previous.json"
        path.write_text('{"schema_version": 1, "releases": [{"channel": "release"}]}')
        output = self.dir / "out.json"
        output.write_text("untouched")
        result = self.cli("add", "--previous", path, "--entry", self.write_json("e.json", entry(10)), "--output", output)
        self.assertRefused(result, "missing")
        self.assertEqual(output.read_text(), "untouched")
        missing = self.cli("add", "--previous", self.dir / "nope.json", "--entry", self.dir / "e.json", "--output", output)
        self.assertRefused(missing, "cannot read the catalog")

    def test_refuses_to_grow_past_the_size_limits(self):
        previous = catalog(*[entry(code, version=f"2026.1.{code}", apis=(code,)) for code in range(1, 101)])
        self.assertRefused(self.add(previous, entry(101, apis=(101,)))[0], "more than 100")
        # Long notes in four-byte characters reach 1 MiB before 100 releases.
        notes = "\U0001F4DA" * 4000
        releases = []
        while True:
            candidate = entry(len(releases) + 1, apis=(len(releases) + 1,), release_notes=notes)
            try:
                module.serialize(releases + [candidate])
            except module.CatalogError:
                break
            releases.append(candidate)
        self.assertLess(len(releases), 100)
        full = self.dir / "full.json"
        full.write_text(module.serialize(releases), encoding="utf-8")
        self.assertEqual(self.cli("check", full).returncode, 0)
        code = len(releases) + 1
        extra = self.write_json("extra.json", entry(code, apis=(code,), release_notes=notes))
        result = self.cli("add", "--previous", full, "--entry", extra, "--output", self.dir / "out.json")
        self.assertRefused(result, "larger than")


class NextAndVerifyTest(LocalCase):
    def plan(self, previous, code, name, channel="release"):
        return self.cli("next", "--previous", self.write_json("p.json", previous), "--channel", channel,
                        "--version-code", code, "--version-name", name)

    def test_plans_a_new_version_before_building(self):
        previous = catalog(entry(10))
        self.assertEqual(self.plan(previous, 11, "2026.11.8.1").stdout.strip(), "new")
        self.assertEqual(self.plan(previous, 10, "2026.11.10").stdout.strip(), "present")
        self.assertRefused(self.plan(previous, 9, "2026.11.8.1"), "highest 10")
        self.assertRefused(self.plan(previous, 11, "2026.11.10"), "already published")
        self.assertRefused(self.plan(previous, 11, "v2026.11.8"), "not a calendar version")
        self.assertRefused(self.plan(previous, 0, "2026.11.8.1"), "out of range")
        result = self.cli("next", "--no-previous", "--channel", "development", "--version-code", "1",
                          "--version-name", "2026.11.8.1-debug")
        self.assertEqual(result.stdout.strip(), "new", result.stderr)

    def test_verifies_a_file_against_its_entry(self):
        data = b"apk bytes"
        apk = self.dir / "a.apk"
        apk.write_bytes(data)
        good = self.write_json("good.json", entry(10, size_bytes=len(data), sha=hashlib.sha256(data).hexdigest()))
        self.assertEqual(self.cli("verify-file", "--entry", good, "--file", apk).returncode, 0)
        wrong_size = self.write_json("size.json", entry(10, size_bytes=99, sha=hashlib.sha256(data).hexdigest()))
        self.assertRefused(self.cli("verify-file", "--entry", wrong_size, "--file", apk), "the entry says 99")
        wrong_hash = self.write_json("hash.json", entry(10, size_bytes=len(data)))
        self.assertRefused(self.cli("verify-file", "--entry", wrong_hash, "--file", apk), "SHA-256")


class GitHubCase(LocalCase):
    def setUp(self):
        super().setUp()
        self.github = FakeGitHub(self.dir)

    def gh_cli(self, *arguments):
        return self.cli("--catalog-url", CATALOG_URL, *arguments, env=self.github.env)

    def fetch(self):
        output = self.dir / "fetched.json"
        return self.gh_cli("github-fetch", "--repo", REPO, "--output", output), output


class FetchTest(GitHubCase):
    def test_tells_a_missing_release_or_asset_from_a_failure(self):
        result, _ = self.fetch()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("there is no android-catalog-v1 release", result.stderr)

        self.github.add_release("android-catalog-v1", assets={"notes.txt": b"x"})
        result, _ = self.fetch()
        self.assertEqual(result.returncode, 3, result.stderr)

        self.github.fail(r"GET .*releases/tags/android-catalog-v1", times=5, status=502)
        result, _ = self.fetch()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("HTTP 502", result.stderr)

        self.github.fail(r"GET .*releases/tags/android-catalog-v1", times=5, status=401)
        self.assertEqual(self.fetch()[0].returncode, 1)

    def test_retries_a_transient_failure(self):
        body = json.dumps(catalog(entry(10))).encode()
        self.github.add_release("android-catalog-v1", assets={"android-catalog.json": body})
        self.github.fail(r"GET .*releases/tags/android-catalog-v1", times=1)
        result, output = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), hashlib.sha256(body).hexdigest())
        self.assertEqual(output.read_bytes(), body)

    def test_a_malformed_published_catalog_fails_closed(self):
        self.github.add_release("android-catalog-v1", assets={"android-catalog.json": b'{"schema_version": 1}'})
        result, _ = self.fetch()
        self.assertRefused(result, "exactly schema_version and releases")

    def test_an_interrupted_promotion_is_not_mistaken_for_no_catalog(self):
        body = json.dumps(catalog(entry(10))).encode()
        self.github.add_release("android-catalog-v1", assets={"android-catalog.next.json": body, "android-catalog.previous.json": body})
        result, _ = self.fetch()
        self.assertRefused(result, "a promotion was interrupted")

    def test_only_reads_the_release_the_catalog_url_names(self):
        result = self.cli("github-fetch", "--repo", "someone/fork", "--output", self.dir / "x.json", env=self.github.env)
        self.assertRefused(result, "--catalog-url must be https://github.com/someone/fork/releases/download/android-catalog-v1/android-catalog.json")
        self.assertEqual(self.github.calls(), [])


class PublishApkTest(GitHubCase):
    def setUp(self):
        super().setUp()
        self.apk = self.dir / "signed.apk"
        self.apk.write_bytes(b"signed apk bytes" * 100)
        data = self.apk.read_bytes()
        self.entry = entry(12, version="2026.11.8.1", size_bytes=len(data), sha=hashlib.sha256(data).hexdigest())
        self.entry_path = self.write_json("entry.json", self.entry)
        self.tag = "android-release-v2026.11.8.1"
        self.name = "shelfarr-android-release-2026.11.8.1-12.apk"
        self.notes = self.dir / "notes.txt"
        self.notes.write_text("Notes")

    def publish(self, commit=COMMIT):
        return self.gh_cli("github-publish-apk", "--repo", REPO, "--target-sha", commit, "--entry", self.entry_path,
                           "--file", self.apk, "--title", "Shelfarr for Android 2026.11.8.1", "--notes-file", self.notes)

    def test_creates_the_release_at_the_tested_commit_and_uploads_once(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "uploaded")
        state = self.github.state()
        self.assertEqual(state["tags"][self.tag], COMMIT)
        release = state["releases"][self.tag]
        self.assertEqual((release["make_latest"], release["draft"], release["prerelease"], release["body"]), ("false", False, False, "Notes"))
        self.assertEqual(self.github.asset(self.tag, self.name), self.apk.read_bytes())

        again = self.publish()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(again.stdout.strip(), "present")
        uploads = [call for call in self.github.calls() if call[:2] == ["release", "upload"]]
        self.assertEqual(len(uploads), 1)

    def test_never_replaces_a_different_published_apk(self):
        self.github.add_release(self.tag, assets={self.name: b"other bytes" * 100})
        result = self.publish()
        self.assertRefused(result, "it is never replaced")
        self.assertEqual(self.github.asset(self.tag, self.name), b"other bytes" * 100)

    def test_a_pruned_label_cannot_publish_another_apk_even_at_the_same_commit(self):
        previous_name = "shelfarr-android-release-2026.11.8.1-10.apk"
        self.github.add_release(self.tag, assets={previous_name: b"previous signed APK"})
        self.assertRefused(self.publish(), "already contains another APK; choose a new calendar version")
        self.assertEqual(self.github.asset(self.tag, previous_name), b"previous signed APK")
        self.assertIsNone(self.github.asset(self.tag, self.name))
        self.assertFalse(any(call[:2] == ["release", "upload"] for call in self.github.calls()))

    def test_refuses_a_release_or_tag_at_another_commit(self):
        self.github.add_release(self.tag, commit="2" * 40)
        self.assertRefused(self.publish(), "not the tested commit")
        state = self.github.state()
        del state["releases"][self.tag]
        self.github.save(state)
        self.assertRefused(self.publish(), f"tag {self.tag} already points at {'2' * 40}")

    def test_restarts_an_incomplete_upload(self):
        self.github.add_release(self.tag, assets={self.name: b"partial"})
        state = self.github.state()
        state["releases"][self.tag]["assets"][self.name]["state"] = "starter"
        self.github.save(state)
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.github.asset(self.tag, self.name), self.apk.read_bytes())

    def test_a_failed_upload_fails_the_step_and_a_rerun_completes_it(self):
        self.github.fail(r"^upload ")
        self.assertRefused(self.publish(), "HTTP 502")
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "uploaded")

    def test_the_file_must_match_its_entry(self):
        self.apk.write_bytes(b"tampered")
        self.assertRefused(self.publish(), "the entry says")
        self.assertEqual(self.github.calls(), [])


class PromoteTest(GitHubCase):
    def promote(self, document, *source):
        path = self.write_json("new-catalog.json", document)
        return self.gh_cli("github-promote", "--repo", REPO, "--file", path, "--target-sha", COMMIT, *source)

    def current(self, name="android-catalog.json"):
        data = self.github.asset("android-catalog-v1", name)
        return json.loads(data) if data else None

    def test_creates_the_catalog_only_when_allowed(self):
        self.assertRefused(self.promote(catalog(entry(10)), "--previous-sha256", "0" * 64), "does not exist")
        result = self.promote(catalog(entry(10)), "--allow-new")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.current(), catalog(entry(10)))
        release = self.github.state()["releases"]["android-catalog-v1"]
        self.assertEqual((release["prerelease"], release["make_latest"]), (True, "false"))
        self.assertRefused(self.promote(catalog(entry(11)), "--allow-new"), "already has android-catalog.json")

    def test_replaces_the_catalog_and_keeps_the_previous_one(self):
        old = json.dumps(catalog(entry(10))).encode()
        self.github.add_release("android-catalog-v1", assets={"android-catalog.json": old, "android-catalog.previous.json": b"{}",
                                                              "android-catalog.next.json": b"stale"})
        result = self.promote(catalog(entry(11), entry(10)), "--previous-sha256", hashlib.sha256(old).hexdigest())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.current(), catalog(entry(11), entry(10)))
        self.assertEqual(self.github.asset("android-catalog-v1", "android-catalog.previous.json"), old)
        self.assertIsNone(self.github.asset("android-catalog-v1", "android-catalog.next.json"))

    def test_refuses_when_the_catalog_changed_since_it_was_read(self):
        old = json.dumps(catalog(entry(10))).encode()
        self.github.add_release("android-catalog-v1", assets={"android-catalog.json": old})
        self.assertRefused(self.promote(catalog(entry(11)), "--previous-sha256", "0" * 64), "changed since it was read")
        self.assertEqual(self.github.asset("android-catalog-v1", "android-catalog.json"), old)

    def test_refuses_an_invalid_catalog_before_touching_github(self):
        self.assertRefused(self.promote({"schema_version": 1, "releases": [{}]}, "--allow-new"), "missing")
        self.assertEqual(self.github.calls(), [])

    def test_an_interruption_leaves_both_catalogs_and_blocks_the_next_run(self):
        old = json.dumps(catalog(entry(10))).encode()
        self.github.add_release("android-catalog-v1", assets={"android-catalog.json": old})
        self.github.fail(r"PATCH .*releases/assets/\d+", times=1)
        # The first rename (current to previous) fails: nothing has moved yet.
        self.assertRefused(self.promote(catalog(entry(11), entry(10)), "--previous-sha256", hashlib.sha256(old).hexdigest()), "HTTP 502")
        self.assertEqual(self.github.asset("android-catalog-v1", "android-catalog.json"), old)
        self.assertEqual(self.fetch()[0].returncode, 0)

        # Now the second rename fails: the old catalog is kept as .previous, the new as .next.
        new = catalog(entry(11), entry(10))
        original = module.api_json

        def flaky(path, method="GET", body=None):
            if method == "PATCH" and body == {"name": "android-catalog.json"}:
                raise module.GitHubError("injected")
            return original(path, method, body)

        saved = {key: os.environ.get(key) for key in self.github.env}
        os.environ.update(self.github.env)
        self.addCleanup(lambda: [os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v) for k, v in saved.items()])
        module.api_json = flaky
        self.addCleanup(setattr, module, "api_json", original)
        args = argparse.Namespace(
            repo=REPO, tag="android-catalog-v1", name="android-catalog.json", catalog_url=CATALOG_URL,
            file=self.write_json("new.json", new), target_sha=COMMIT,
            previous_sha256=hashlib.sha256(old).hexdigest(), allow_new=False,
        )
        with self.assertRaises(module.GitHubError):
            module.github_promote(args)
        self.assertIsNone(self.github.asset("android-catalog-v1", "android-catalog.json"))
        self.assertEqual(self.github.asset("android-catalog-v1", "android-catalog.previous.json"), old)
        self.assertEqual(json.loads(self.github.asset("android-catalog-v1", "android-catalog.next.json")), new)
        self.assertRefused(self.fetch()[0], "a promotion was interrupted")



class PublicationFlowTest(GitHubCase):
    """The workflow's publish job, command by command, for a first and a second build."""

    def publish_build(self, code, version, create=False):
        apk = self.dir / f"{code}.apk"
        apk.write_bytes(f"build {code}".encode() * 64)
        data = apk.read_bytes()
        built = entry(code, version=version, size_bytes=len(data), sha=hashlib.sha256(data).hexdigest())
        entry_path = self.write_json(f"entry-{code}.json", built)

        current = self.dir / "current.json"
        fetched = self.gh_cli("github-fetch", "--repo", REPO, "--output", current)
        self.assertEqual(fetched.returncode, 3 if create else 0, fetched.stderr)
        previous = ["--no-previous"] if create else ["--previous", current]
        promote = ["--allow-new"] if create else ["--previous-sha256", fetched.stdout.strip()]

        new_catalog = self.dir / f"catalog-{code}.json"
        added = self.gh_cli("add", *previous, "--entry", entry_path, "--output", new_catalog)
        self.assertEqual(added.stdout.strip(), "added", added.stderr)
        published = self.gh_cli("github-publish-apk", "--repo", REPO, "--target-sha", COMMIT, "--entry", entry_path,
                                "--file", apk, "--title", f"Shelfarr for Android {version}")
        self.assertEqual(published.returncode, 0, published.stderr)
        promoted = self.gh_cli("github-promote", "--repo", REPO, "--file", new_catalog, "--target-sha", COMMIT, *promote)
        self.assertEqual(promoted.returncode, 0, promoted.stderr)
        return built

    def test_first_and_second_publication(self):
        first = self.publish_build(10, "2026.11.8.1", create=True)
        second = self.publish_build(11, "2026.11.8.2")
        published = json.loads(self.github.asset("android-catalog-v1", "android-catalog.json"))
        self.assertEqual(published, catalog(second, first))
        self.assertEqual(json.loads(self.github.asset("android-catalog-v1", "android-catalog.previous.json")), catalog(first))
        tags = sorted(self.github.state()["releases"])
        self.assertEqual(tags, ["android-catalog-v1", "android-release-v2026.11.8.1", "android-release-v2026.11.8.2"])
        # The APK releases were never touched again.
        uploads = [call[2] for call in self.github.calls() if call[:2] == ["release", "upload"]]
        self.assertEqual(uploads.count("android-release-v2026.11.8.1"), 1)

if __name__ == "__main__":
    unittest.main()
