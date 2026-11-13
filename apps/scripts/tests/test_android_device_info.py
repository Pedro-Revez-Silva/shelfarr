"""Read-only device collection must not be confused with behavioral acceptance."""

import importlib.util
import json
from unittest import mock

from support import ScratchCase, SCRIPTS


SPEC = importlib.util.spec_from_file_location("android_device_info", SCRIPTS / "android-device-info.py")
device_info = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(device_info)


class AndroidDeviceInfoTest(ScratchCase):
    def query(self, devices=None, properties=None, package=None, serial=None):
        devices = devices if devices is not None else "List of devices attached\nPRIVATE-SERIAL\tdevice\n"
        props = {"ro.hardware": "phone-chipset", "ro.kernel.qemu": "0", "ro.boot.qemu": "",
                 "ro.product.manufacturer": "Example", "ro.product.model": "Test Phone",
                 "ro.build.version.release": "15", "ro.build.version.sdk": "35", **(properties or {})}
        details = package if package is not None else """Package [org.shelfarr.app.debug]:
  versionCode=4 minSdk=26
  versionName=2026.11.8.1-debug
  firstInstallTime=2026-11-08 10:00:00
  lastUpdateTime=2026-11-09 10:00:00
"""
        calls = []

        def adb(executable, *args):
            calls.append(args)
            if args == ("devices",):
                return devices
            if args[:2] == ("-s", serial or "PRIVATE-SERIAL"):
                if args[2:4] == ("shell", "getprop"):
                    return props[args[4]] + "\r\n"
                if args[2:] == ("shell", "dumpsys", "package", "org.shelfarr.app.debug"):
                    return details
            self.fail("unexpected ADB operation")

        return adb, calls

    def test_collects_versions_but_never_serials_credentials_or_test_passes(self):
        query, calls = self.query()
        with mock.patch.object(device_info, "adb", side_effect=query):
            report = device_info.collect("adb", "org.shelfarr.app.debug")
        self.assertEqual("physical", report["device_kind"])
        self.assertEqual(4, report["app"]["version_code"])
        self.assertEqual("2026-11-08 10:00:00", report["app"]["first_install_time"])
        self.assertEqual([], report["behavioral_tests_executed"])
        self.assertTrue(report["collection_only"])
        self.assertNotIn("PRIVATE-SERIAL", json.dumps(report))
        self.assertTrue(all(call == ("devices",) or call[2:4] in (("shell", "getprop"), ("shell", "dumpsys")) for call in calls))

    def test_emulators_never_count_as_physical_device_evidence(self):
        for props in ({"ro.kernel.qemu": "1"}, {"ro.boot.qemu": "1"}, {"ro.hardware": "ranchu"}):
            query, _ = self.query(properties=props)
            with self.subTest(properties=props), mock.patch.object(device_info, "adb", side_effect=query):
                self.assertEqual("emulator", device_info.collect("adb", "org.shelfarr.app.debug")["device_kind"])

    def test_missing_hardware_is_unknown_rather_than_claimed_as_physical(self):
        query, _ = self.query(properties={"ro.hardware": ""})
        with mock.patch.object(device_info, "adb", side_effect=query):
            self.assertEqual("unknown", device_info.collect("adb", "org.shelfarr.app.debug")["device_kind"])

    def test_multiple_or_unavailable_devices_need_an_explicit_authorized_selection(self):
        for devices in ("", "PRIVATE-SERIAL\tunauthorized", "A\tdevice\nB\tdevice"):
            query, calls = self.query(devices=devices)
            with self.subTest(devices=devices), mock.patch.object(device_info, "adb", side_effect=query):
                with self.assertRaises(device_info.DeviceInfoError):
                    device_info.collect("adb", "org.shelfarr.app.debug")
            self.assertEqual([("devices",)], calls)

    def test_an_explicit_device_is_checked_against_the_online_inventory(self):
        query, _ = self.query(devices="A\tdevice\nB\tdevice", serial="B")
        with mock.patch.object(device_info, "adb", side_effect=query):
            self.assertEqual(4, device_info.collect("adb", "org.shelfarr.app.debug", serial="B")["app"]["version_code"])

    def test_missing_package_and_malformed_properties_are_rejected(self):
        for options in ({"package": "Unable to find package"}, {"properties": {"ro.hardware": "BAD\x00DATA"}}):
            query, _ = self.query(**options)
            with self.subTest(options=options), mock.patch.object(device_info, "adb", side_effect=query):
                with self.assertRaises(device_info.DeviceInfoError):
                    device_info.collect("adb", "org.shelfarr.app.debug")

    def test_invalid_package_is_rejected_before_any_device_access(self):
        with mock.patch.object(device_info, "adb") as adb:
            with self.assertRaises(device_info.DeviceInfoError):
                device_info.collect("adb", "org.shelfarr.app.debug;reboot")
        adb.assert_not_called()
