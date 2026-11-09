"""Fixture instrumentation must refuse a personal phone before changing anything."""

import json
import os
import shutil
import subprocess

from support import ScratchCase, SCRIPTS


class AndroidSmokeTargetTest(ScratchCase):
    def smoke(self, kernel="", boot="", fail=False, gradle_status=0):
        scripts = self.dir / "apps/scripts"
        scripts.mkdir(parents=True)
        android = self.dir / "apps/android"
        android.mkdir()
        script = scripts / "android-reader-smoke.sh"
        shutil.copyfile(SCRIPTS / script.name, script)
        commands = self.dir / "commands.jsonl"
        binary = self.dir / "bin"
        binary.mkdir()
        adb = binary / "adb"
        adb.write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TEST_COMMANDS'], 'a') as log:
    log.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[1:3] == ['shell', 'getprop']:
    if os.environ['TEST_ADB_FAIL'] == '1': sys.exit(1)
    print(os.environ['TEST_KERNEL'] if sys.argv[-1]=='ro.kernel.qemu' else os.environ['TEST_BOOT'])
""")
        adb.chmod(0o755)
        gradle = android / "gradlew"
        gradle.write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TEST_COMMANDS'], 'a') as log:
    log.write(json.dumps(['gradle']+sys.argv[1:])+'\\n')
sys.exit(int(os.environ['TEST_GRADLE_STATUS']))
""")
        gradle.chmod(0o755)
        env = {"PATH": str(binary) + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"),
               "TEST_COMMANDS": str(commands), "TEST_KERNEL": kernel, "TEST_BOOT": boot,
               "TEST_ADB_FAIL": "1" if fail else "0", "TEST_GRADLE_STATUS": str(gradle_status)}
        result = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)
        calls = [json.loads(line) for line in commands.read_text().splitlines()]
        return result, calls

    def test_a_physical_phone_is_refused_before_log_clear_or_install(self):
        result, calls = self.smoke(kernel="0", boot="0")
        self.assertEqual(2, result.returncode)
        self.assertIn("Refusing fixture instrumentation", result.stderr)
        self.assertEqual([["shell", "getprop", "ro.kernel.qemu"], ["shell", "getprop", "ro.boot.qemu"]], calls)

    def test_unknown_or_inaccessible_devices_are_also_refused(self):
        result, calls = self.smoke(fail=True)
        self.assertEqual(2, result.returncode)
        self.assertFalse(any(call[0] in ("gradle", "logcat") for call in calls))

    def test_the_ci_emulator_still_runs_the_real_suite_and_collects_diagnostics(self):
        result, calls = self.smoke(kernel="1\r")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn(["gradle", "--no-daemon", ":app:connectedDebugAndroidTest"], calls)
        self.assertIn(["logcat", "-d"], calls)

    def test_the_legacy_emulator_property_is_supported(self):
        result, calls = self.smoke(boot="1")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn(["gradle", "--no-daemon", ":app:connectedDebugAndroidTest"], calls)

    def test_instrumentation_failure_is_not_hidden_by_log_collection(self):
        result, calls = self.smoke(kernel="1", gradle_status=7)
        self.assertEqual(7, result.returncode)
        self.assertIn(["logcat", "-d"], calls)
