#!/usr/bin/env python3
"""Emulator-only acceptance of Shelfarr's real in-app Android update.

An older published APK downloads a newer one from its fixed update feed, and the
person's taps go through the app's Update card, Android's "Install unknown apps"
switch and Android's installer confirmation. Nothing installs the new version
with adb: the update is the app's own PackageInstaller session. The controller
runs outside the device because the update kills the app and its instrumentation.

Before and after, instrumentation seeds and verifies synthetic data:

  * the seed test APK must be compiled against the OLD app's sources
    (tools/upgrade-seed/UpgradeSeedTest.kt copied into them, as
    upgrade-preservation.sh does); it signs in to a local fixture server that it
    then closes, so the account stays offline;
  * the verify test APK must be compiled against the NEW app's exact sources,
    so its UpgradePreservationTest#verify calls only what the new app has.

The feed is only read. The controller stops if the feed, the APK's bytes, the
version Android's UI shows or the version Android installs differ from what was
expected. It refuses anything that is not an emulator, and it needs a package
that is not installed yet. Every UI decision is taken from a fresh accessibility
snapshot (uiautomator XML) saved with a screenshot under --out.

  ANDROID_ADB_SERVER_PORT=5190 apps/android/tools/in-app-update-acceptance.py \\
    --serial emulator-5584 --old-apk Shelfarr-development-3.apk --old-version-code 3 \\
    --seed-test-apk seed-3-test.apk --verify-test-apk verify-4-test.apk \\
    --feed-url https://example.org/downloads/android-development.json \\
    --expect-version-code 4 --expect-sha256 <64 hex> --out report-dir
"""
import argparse
import hashlib
import json
import re
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

PACKAGE = "org.shelfarr.app.debug"
ACTIVITY = f"{PACKAGE}/org.shelfarr.app.ui.MainActivity"
RUNNER = f"{PACKAGE}.test/androidx.test.runner.AndroidJUnitRunner"
INSTALLERS = ("com.google.android.packageinstaller", "com.android.packageinstaller")


class Failure(Exception):
    pass


class Controller:
    def __init__(self, args):
        self.args = args
        self.out = Path(args.out)
        self.out.mkdir(parents=True, exist_ok=True)
        (self.out / "ui").mkdir(exist_ok=True)
        self.adb_base = [args.adb, "-s", args.serial]
        self.step = 0
        self.result = {"result": "running", "package": PACKAGE, "physical_device_touched": False}

    # -- bookkeeping -------------------------------------------------------
    def event(self, name, **fields):
        line = {"t": time.strftime("%H:%M:%S"), "event": name, **fields}
        with (self.out / "events.jsonl").open("a") as log:
            log.write(json.dumps(line) + "\n")
        print(json.dumps(line), flush=True)

    def record(self, **fields):
        self.result.update(fields)
        (self.out / "result.json").write_text(json.dumps(self.result, indent=2) + "\n")

    # -- adb ---------------------------------------------------------------
    def adb(self, *args, timeout=120, check=True, binary=False):
        done = subprocess.run(self.adb_base + list(args), capture_output=True, timeout=timeout)
        if check and done.returncode:
            raise Failure(f"adb {' '.join(args)} exited {done.returncode}: {done.stderr.decode(errors='replace')[-400:]}")
        return done.stdout if binary else done.stdout.decode(errors="replace").replace("\r", "")

    def sh(self, *args, **kwargs):
        return self.adb("shell", *args, **kwargs)

    def save(self, name, text):
        (self.out / name).write_text(text)
        return text

    def package_info(self, name):
        dump = self.save(name, self.sh("dumpsys", "package", PACKAGE))
        section = dump.split("Packages:", 1)[-1]
        fields = {}
        for key in ("versionCode", "versionName", "firstInstallTime", "lastUpdateTime", "installerPackageName"):
            match = re.search(rf"^\s*{key}=(\S+(?: \d\d:\d\d:\d\d)?)", section, re.M)
            if match:
                fields[key] = match.group(1)
        if "versionCode" in fields:
            fields["versionCode"] = int(fields["versionCode"])
        return fields

    def installed_apk_sha256(self):
        path = self.sh("pm", "path", PACKAGE).strip().splitlines()
        base = [p[len("package:"):] for p in path if p.endswith("/base.apk")]
        if len(base) != 1:
            raise Failure(f"Unexpected package paths: {path}")
        return self.sh("sha256sum", base[0]).split()[0]

    def instrument(self, name, test, *extra, timeout=300):
        text = self.save(name, self.sh("am", "instrument", "-w", "-r", *extra, "-e", "class", test, RUNNER, timeout=timeout))
        # am instrument exits 0 even when a test fails, crashes or is skipped.
        passed = re.search(r"^OK \(1 test\)$", text, re.M) and not re.search(
            r"FAILURES|INSTRUMENTATION_FAILED|Process crashed|INSTRUMENTATION_STATUS_CODE: -[234]", text
        )
        if not passed:
            raise Failure(f"{test} did not pass; see {name}")
        self.event("instrumentation_passed", test=test)

    def install(self, apk, *flags):
        text = self.adb("install", *flags, str(apk), timeout=300)
        if "Success" not in text:
            raise Failure(f"Installing {apk} failed: {text}")

    # -- the feed ----------------------------------------------------------
    def check_feed(self, stage):
        request = urllib.request.Request(self.args.feed_url, headers={"Cache-Control": "no-cache", "User-Agent": "shelfarr-acceptance"})
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
        self.save(f"feed-{stage}.json", body.decode())
        feed = json.loads(body)
        problems = []
        if feed.get("package_name") != PACKAGE:
            problems.append(f"package {feed.get('package_name')}")
        if feed.get("version_code") != self.args.expect_version_code:
            problems.append(f"version_code {feed.get('version_code')}")
        if feed.get("sha256") != self.args.expect_sha256:
            problems.append(f"sha256 {feed.get('sha256')}")
        if problems:
            raise Failure(f"The live feed changed at {stage}: {', '.join(problems)}; refusing to continue")
        self.event("feed_as_expected", stage=stage, version_code=feed["version_code"], version_name=feed["version_name"], sha256=feed["sha256"])
        return feed

    def check_feed_apk(self, feed):
        # Read-only: fetch the announced APK and compare it with the expected bytes.
        digest = hashlib.sha256()
        size = 0
        with urllib.request.urlopen(urllib.request.Request(feed["apk_url"], headers={"User-Agent": "shelfarr-acceptance"}), timeout=120) as response:
            while chunk := response.read(1 << 20):
                digest.update(chunk)
                size += len(chunk)
        if digest.hexdigest() != self.args.expect_sha256 or size != feed["size_bytes"]:
            raise Failure(f"The feed's APK is {digest.hexdigest()} ({size} bytes), not the expected one")
        self.event("feed_apk_as_expected", url=feed["apk_url"], sha256=digest.hexdigest(), size_bytes=size)

    # -- the UI --------------------------------------------------------------
    def snapshot(self, label):
        """A fresh accessibility tree and screenshot. Returns the tree's nodes."""
        self.step += 1
        stem = self.out / "ui" / f"{self.step:03d}-{label}"
        xml = None
        for _ in range(5):
            text = self.sh("uiautomator", "dump", "/sdcard/window.xml", check=False, timeout=60)
            if "dumped to" in text:
                xml = self.sh("cat", "/sdcard/window.xml")
                break
            time.sleep(1)
        stem.with_suffix(".png").write_bytes(self.adb("exec-out", "screencap", "-p", binary=True))
        if xml is None:
            self.event("snapshot_unavailable", label=label)
            return []
        stem.with_suffix(".xml").write_text(xml)
        nodes = []
        for node in ET.fromstring(xml).iter("node"):
            bounds = [int(v) for v in re.findall(r"\d+", node.get("bounds", ""))]
            nodes.append({k: node.get(k, "") for k in ("text", "content-desc", "resource-id", "class", "package", "checkable", "checked", "clickable", "enabled")} | {"bounds": bounds})
        return nodes

    @staticmethod
    def find(nodes, pattern, package=None):
        for node in nodes:
            if package and not node["package"].startswith(package):
                continue
            if any(re.search(pattern, node[key]) for key in ("text", "content-desc")) and len(node["bounds"]) == 4:
                return node
        return None

    @staticmethod
    def texts(nodes):
        return [n["text"] or n["content-desc"] for n in nodes if n["text"] or n["content-desc"]]

    def tap(self, node, why):
        left, top, right, bottom = node["bounds"]
        x, y = (left + right) // 2, (top + bottom) // 2
        self.event("tap", why=why, text=node["text"] or node["content-desc"], package=node["package"], x=x, y=y, step=self.step)
        self.sh("input", "tap", str(x), str(y))

    def wait_for(self, label, condition, timeout, interval=2.0):
        """Snapshots until condition(nodes) is truthy; the matching snapshot is kept."""
        deadline = time.monotonic() + timeout
        while True:
            nodes = self.snapshot(label)
            found = condition(nodes)
            if found:
                return nodes, found
            if time.monotonic() > deadline:
                raise Failure(f"Timed out waiting for {label}; last screen: {self.texts(nodes)[:40]}")
            # Keep only the final snapshot of a wait, so each saved one marks a decision.
            stem = self.out / "ui" / f"{self.step:03d}-{label}"
            for suffix in (".png", ".xml"):
                stem.with_suffix(suffix).unlink(missing_ok=True)
            self.step -= 1
            time.sleep(interval)

    def scroll_to(self, label, condition, attempts=8):
        for _ in range(attempts):
            nodes = self.snapshot(label)
            found = condition(nodes)
            if found:
                return nodes, found
            self.sh("input", "swipe", "540", "1500", "540", "600", "400")
            time.sleep(1)
        raise Failure(f"Couldn't find {label} by scrolling")

    def next_prompt(self, nodes):
        """What the screen asks for between "Install update" and Android's confirmation."""
        if any(n["package"] in INSTALLERS for n in nodes):
            return "installer", next((n for n in nodes if n["package"] in INSTALLERS and re.fullmatch(r"(?i)update", n["text"])), None)
        for kind, pattern, package in (
            ("switch", r"^Allow from this source$", "com.android.settings"),
            ("open-settings", r"^Open Android settings$", PACKAGE),
            ("install", r"^Install update$", PACKAGE),
            ("show-prompt", r"^Show prompt$", PACKAGE),
        ):
            node = self.find(nodes, pattern, package)
            if node:
                return kind, node
        return None

    # -- the experiment -------------------------------------------------------
    def run(self):
        a = self.args
        if "1" not in (self.sh("getprop", "ro.kernel.qemu").strip(), self.sh("getprop", "ro.boot.qemu").strip()):
            raise Failure("Refusing: not an emulator")
        if self.sh("getprop", "sys.boot_completed").strip() != "1":
            raise Failure("The emulator hasn't finished booting")
        if f"package:{PACKAGE}\n" in self.sh("pm", "list", "packages", PACKAGE) + "\n":
            raise Failure(f"{PACKAGE} is already installed; use a fresh emulator")

        feed = self.check_feed("preflight")
        self.check_feed_apk(feed)
        self.record(feed_preflight=feed)

        # Animations off, so accessibility dumps settle; this emulator only.
        for key in ("window_animation_scale", "transition_animation_scale", "animator_duration_scale"):
            self.sh("settings", "put", "global", key, "0")

        self.install(a.old_apk)
        self.install(a.seed_test_apk, "-t")
        before = self.package_info("package-before.txt")
        if before.get("versionCode") != a.old_version_code:
            raise Failure(f"Installed old version is {before}")
        self.record(package_before=before)
        self.instrument("seed-result.txt", "org.shelfarr.app.upgrade.UpgradeSeedTest#seed", "-e", "shelfarrUpgradeStage", "seed")
        self.record(seed_passed=True)
        self.save("appops-before.txt", self.sh("appops", "get", PACKAGE, "REQUEST_INSTALL_PACKAGES"))

        self.sh("am", "start", "-W", "-n", ACTIVITY)
        _, tab = self.wait_for("library-opened", lambda n: self.find(n, r"^Settings$", PACKAGE), 60)
        self.tap(tab, "open Settings")

        # The Update card is at the foot of Settings.
        card = r"^(Update available|Check for updates|Try again|Checking for updates…|Up to date.*)$"
        nodes, _ = self.scroll_to("update-card", lambda n: self.find(n, card, PACKAGE))
        if not self.find(nodes, r"^Update available$", PACKAGE):
            button = self.find(nodes, r"^(Check for updates|Try again)$", PACKAGE)
            if button:
                self.tap(button, "check for updates")
            nodes, _ = self.wait_for("update-available", lambda n: self.find(n, r"^Update available$", PACKAGE), 120)
        shown = self.find(nodes, r"^Version ", PACKAGE)
        if not shown or shown["text"] != f"Version {feed['version_name']}":
            raise Failure(f"The Update card offers {shown and shown['text']}, not {feed['version_name']}")
        self.event("update_offered", version=shown["text"])

        self.check_feed("before-download")
        nodes, download = self.wait_for("download-button", lambda n: self.find(n, r"^Download · ", PACKAGE), 20)
        self.tap(download, "download the update")
        time.sleep(2)
        self.snapshot("downloading")
        nodes, install = self.wait_for(
            "ready-to-install",
            lambda n: self.find(n, r"^Install update$", PACKAGE) or self.find(n, r"^Try again · ", PACKAGE),
            a.download_timeout,
            interval=5,
        )
        if install["text"] != "Install update":
            raise Failure(f"The download failed: {self.texts(nodes)}")
        self.tap(install, "install the update")

        # Android asks once for "Install unknown apps", then shows its installer confirmation.
        granted = False
        confirmed = False
        deadline = time.monotonic() + 180
        while not confirmed:
            if time.monotonic() > deadline:
                raise Failure("The installation never reached Android's confirmation")
            nodes, (kind, node) = self.wait_for("next-prompt", self.next_prompt, 90)
            if kind == "installer":
                if node is None:
                    raise Failure(f"Android's installer has no Update button: {self.texts(nodes)}")
                self.record(installer_prompt=self.texts(nodes))
                self.check_feed("before-confirm")
                self.tap(node, "confirm Android's update prompt")
                confirmed = True
            elif kind == "switch":
                switch = next((n for n in nodes if n["checkable"] == "true" and n["package"] == "com.android.settings"), None)
                if switch and switch["checked"] == "true":
                    granted = True
                else:
                    self.tap(node, "allow this app to install apps")
                    after, _ = self.wait_for(
                        "permission-allowed",
                        lambda n: any(x["checkable"] == "true" and x["checked"] == "true" and x["package"] == "com.android.settings" for x in n),
                        20,
                    )
                    granted = True
                    self.record(permission_screen=self.texts(after))
                self.save("appops-after-grant.txt", self.sh("appops", "get", PACKAGE, "REQUEST_INSTALL_PACKAGES"))
                self.event("back", why="return to Shelfarr")
                self.sh("input", "keyevent", "KEYCODE_BACK")
                time.sleep(2)
            elif kind == "open-settings":
                if granted:
                    raise Failure("Shelfarr still asks for the install permission after it was allowed")
                self.tap(node, "open Android's install permission")
            elif kind == "install":
                self.tap(node, "install the update")
            elif kind == "show-prompt":
                self.tap(node, "show Android's prompt again")
            time.sleep(3)
        self.record(permission_granted_through_ui=granted)

        # The app and its process are replaced; wait for Android to finish.
        deadline = time.monotonic() + 180
        while True:
            info = self.package_info("package-during.txt")
            if info.get("versionCode") == a.expect_version_code:
                break
            if info.get("versionCode") not in (a.old_version_code, a.expect_version_code):
                raise Failure(f"Android installed an unexpected version: {info}")
            if time.monotonic() > deadline:
                self.snapshot("install-timeout")
                raise Failure("Android didn't finish installing the update")
            time.sleep(2)
        self.snapshot("after-install")
        after = self.package_info("package-after.txt")
        sha = self.installed_apk_sha256()
        self.record(package_after=after, installed_apk_sha256=sha)
        if after["firstInstallTime"] != before["firstInstallTime"]:
            raise Failure("The update reinstalled the app instead of updating it")
        if not after["lastUpdateTime"] > before["lastUpdateTime"]:
            raise Failure("The package's update time didn't advance")
        if sha != a.expect_sha256:
            raise Failure(f"Android installed {sha}, not the expected APK")
        self.event("updated_in_place", **after, installed_apk_sha256=sha)

        # Only the test package changes now; the app keeps the data the update kept.
        self.install(a.verify_test_apk, "-r", "-t")
        if self.package_info("package-after-verifier-install.txt") != after:
            raise Failure("Installing the verifier changed the app package")
        self.instrument(
            "verify-result.txt", "org.shelfarr.app.upgrade.UpgradePreservationTest#verify",
            "-e", "shelfarrUpgradeStage", "verify", "-e", "shelfarrExpectVersionCode", str(a.expect_version_code),
        )
        self.record(verify_passed=True)

        # The updated app, opened by a person: still signed in, Settings shows its state.
        self.sh("am", "start", "-W", "-n", ACTIVITY)
        _, tab = self.wait_for("updated-app-opened", lambda n: self.find(n, r"^Settings$", PACKAGE), 60)
        self.tap(tab, "open Settings in the updated app")
        self.scroll_to("updated-update-card", lambda n: self.find(n, r"(?i)update|up to date", PACKAGE))
        self.check_feed("after")
        self.record(result="passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial", required=True)
    parser.add_argument("--old-apk", required=True)
    parser.add_argument("--old-version-code", type=int, required=True)
    parser.add_argument("--seed-test-apk", required=True)
    parser.add_argument("--verify-test-apk", required=True)
    parser.add_argument("--feed-url", required=True)
    parser.add_argument("--expect-version-code", type=int, required=True)
    parser.add_argument("--expect-sha256", required=True)
    parser.add_argument("--download-timeout", type=int, default=600)
    parser.add_argument("--out", required=True)
    controller = Controller(parser.parse_args())
    try:
        controller.run()
    except BaseException as error:
        controller.event("failed", error=str(error))
        controller.record(result="failed", error=str(error))
        try:
            controller.snapshot("failure")
        except Exception:
            pass
        raise
    finally:
        try:
            controller.save("logcat.txt", controller.adb("logcat", "-d", timeout=60, check=False))
        except Exception:
            pass
    print("In-app update acceptance passed:", controller.out)


if __name__ == "__main__":
    sys.exit(main())
