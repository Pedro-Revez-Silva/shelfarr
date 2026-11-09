#!/usr/bin/env python3
"""Emulator-only acceptance of audiobook listening durability across abrupt process death.

The requirement: local checkpoints lose no more than five seconds of listening,
survive abrupt process death, keep the time the place was actually heard through
restart and reconnection, and a resume rewinds once without the replay being
saved as new activity.

The device half is tools/audio-durability/AudioDurabilityProbe.kt. It is not in
the app's test sources: compile it into a checkout's androidTest temporarily,
build, then remove the copy:

  mkdir -p app/src/androidTest/java/org/shelfarr/app/audiodurability
  cp tools/audio-durability/AudioDurabilityProbe.kt app/src/androidTest/java/org/shelfarr/app/audiodurability/
  ./gradlew :app:assembleDebug :app:assembleDebugAndroidTest -PshelfarrVersionCode=<n> -PshelfarrVersionName=<name>
  rm -r app/src/androidTest/java/org/shelfarr/app/audiodurability

Everything real except the HTTP server: generated AAC audio downloaded by the
app, decoded by ExoPlayer in PlaybackService behind the production
MediaController/PlaybackController/PlayerViewModel, the real FileProgressStore in
the account folder, and the Keystore session. The fixture server lives in the
instrumented process and dies with it; the reopen stage starts it again at the
same origin and port.

This controller runs outside the device because it kills the app:

  1. installs the APKs on an EMULATOR (it uninstalls the debug package first),
  2. runs the `play` stage and watches logcat for the probe's kill window, which
     the probe opens between two on-disk checkpoints,
  3. SIGKILLs the app's process with `run-as <pkg> kill -9` (no pause, no
     lifecycle callback, no flush), pulls progress.json and the probe's samples,
     and computes what was heard at the instant of death against what was on disk,
  4. waits so the listening time and the sync time are well apart, checking that
     nothing rewrote the file meanwhile,
  5. runs the `reopen` stage in a fresh process, with the pulled file's SHA-256.

  ANDROID_ADB_SERVER_PORT=5190 apps/android/tools/audio-durability-acceptance.py \\
    --serial emulator-5584 --app-apk app-debug.apk --test-apk app-debug-androidTest.apk --out report-dir
"""
import argparse
import hashlib
import json
import subprocess
import sys
import threading
import time
from pathlib import Path

PACKAGE = "org.shelfarr.app.debug"
RUNNER = f"{PACKAGE}.test/androidx.test.runner.AndroidJUnitRunner"
PROBE = "org.shelfarr.app.audiodurability.AudioDurabilityProbe#probe"
LOSS_BOUND_MS = 5_000


class Failure(Exception):
    pass


class Controller:
    def __init__(self, args):
        self.args = args
        self.out = Path(args.out)
        self.out.mkdir(parents=True, exist_ok=True)
        self.adb_base = [args.adb, "-s", args.serial]
        self.result = {"result": "running", "package": PACKAGE, "physical_device_touched": False}

    def event(self, name, **fields):
        line = {"t": time.strftime("%H:%M:%S"), "event": name, **fields}
        with (self.out / "events.jsonl").open("a") as log:
            log.write(json.dumps(line) + "\n")
        print(json.dumps(line), flush=True)

    def record(self, **fields):
        self.result.update(fields)
        (self.out / "result.json").write_text(json.dumps(self.result, indent=2) + "\n")

    def adb(self, *args, timeout=120, check=True, binary=False):
        done = subprocess.run(self.adb_base + list(args), capture_output=True, timeout=timeout)
        if check and done.returncode:
            raise Failure(f"adb {' '.join(args)} exited {done.returncode}: {done.stderr.decode(errors='replace')[-400:]}")
        return done.stdout if binary else done.stdout.decode(errors="replace").replace("\r", "")

    def sh(self, *args, **kwargs):
        return self.adb("shell", *args, **kwargs)

    def save(self, name, data):
        path = self.out / name
        path.write_bytes(data) if isinstance(data, bytes) else path.write_text(data)
        return path

    def pull_private(self, relative, name):
        data = self.adb("exec-out", "run-as", PACKAGE, "cat", relative, binary=True)
        self.save(name, data)
        return data

    def pid(self):
        return self.sh("pidof", PACKAGE, check=False).strip()

    def device_ms(self):
        return int(self.sh("date", "+%s%3N").strip())

    # ------------------------------------------------------------------
    def run(self):
        qemu = (self.sh("getprop", "ro.kernel.qemu").strip(), self.sh("getprop", "ro.boot.qemu").strip())
        if "1" not in qemu:
            raise Failure("Refusing: not an emulator. This test uninstalls the app and kills it.")
        self.record(device=self.sh("getprop", "ro.build.fingerprint").strip(), serial=self.args.serial)
        for apk in (self.args.app_apk, self.args.test_apk):
            self.record(**{f"sha256_{Path(apk).name}": hashlib.sha256(Path(apk).read_bytes()).hexdigest()})
        self.adb("uninstall", PACKAGE, check=False)
        self.adb("uninstall", f"{PACKAGE}.test", check=False)
        self.save("install.txt", self.adb("install", self.args.app_apk) + self.adb("install", self.args.test_apk))
        self.sh("pm", "grant", PACKAGE, "android.permission.POST_NOTIFICATIONS", check=False)
        self.save("package.txt", self.sh("dumpsys", "package", PACKAGE))
        uid = next(line.strip().split("=", 1)[1] for line in self.sh("dumpsys", "package", PACKAGE).splitlines() if line.strip().startswith("appId="))
        self.adb("logcat", "-c", check=False)

        play = self.play(uid)
        self.reopen(play)
        self.record(result="passed")
        self.event("passed")

    def instrument(self, stage, *extra):
        args = ["shell", "am", "instrument", "-w", "-r", "-e", "shelfarrAudioStage", stage,
                "-e", "shelfarrFixturePort", str(self.args.port), *extra, "-e", "class", PROBE, RUNNER]
        log = (self.out / f"instrument-{stage}.txt").open("w")
        return subprocess.Popen(self.adb_base + args, stdout=log, stderr=subprocess.STDOUT), self.out / f"instrument-{stage}.txt"

    def play(self, uid):
        watcher = subprocess.Popen(self.adb_base + ["logcat", "-v", "epoch", "-s", "ADUR:I"], stdout=subprocess.PIPE, text=True)
        lines = []
        process, output = self.instrument("play", "-e", "shelfarrKillAfterCheckpointMs", str(self.args.kill_after_checkpoint_ms))
        window = None
        evidence = {}
        deadline = time.monotonic() + 240
        try:
            while window is None:
                if time.monotonic() > deadline:
                    raise Failure("No kill window within 240s")
                line = watcher.stdout.readline()
                if not line:
                    raise Failure("logcat ended")
                lines.append(line)
                if "ADUR" not in line:
                    continue
                payload = line.split("ADUR", 1)[1].lstrip(" :").strip()
                event = payload.split(" ", 1)[0]
                if event == "playing" and not evidence:
                    # Out-of-process evidence that audio is genuinely being rendered for this app.
                    time.sleep(2)
                    evidence["audio"] = self.sh("dumpsys", "audio")
                    evidence["flinger"] = self.sh("dumpsys", "media.audio_flinger")
                    evidence["session"] = self.sh("dumpsys", "media_session")
                    self.save("dumpsys-audio-play.txt", evidence["audio"])
                    self.save("dumpsys-audio-flinger-play.txt", evidence["flinger"])
                    self.save("dumpsys-media-session-play.txt", evidence["session"])
                    self.save("screen-play.png", self.adb("exec-out", "screencap", "-p", binary=True))
                    started = [l for l in evidence["audio"].splitlines() if "AudioPlaybackConfiguration" in l and f"u/pid:{uid}/" in l and "state:started" in l]
                    if not started:
                        raise Failure(f"Android reports no started audio player for uid {uid}")
                    self.event("audio-started", players=started[:3])
                if event in ("cadence", "kill-window", "generated", "playing"):
                    self.event(f"probe-{event}", payload=json.loads(payload.split(" ", 1)[1]))
                if event == "kill-window":
                    window = json.loads(payload.split(" ", 1)[1])
                if process.poll() is not None:
                    raise Failure(f"The play stage ended before its kill window: {output}")
            pid = window["pid"]
            if self.pid() != str(pid):
                raise Failure(f"Process {pid} is not the app's ({self.pid()})")
            # SIGKILL from outside: no pause, no onStop, no flush. Device clock on both sides.
            killed = self.adb("shell", f"a=$(date +%s%3N); run-as {PACKAGE} kill -9 {pid}; s=$?; echo $a $(date +%s%3N) $s").split()
            before_ms, after_ms = int(killed[0]), int(killed[1])
            if killed[2] != "0":
                raise Failure(f"kill -9 {pid} failed: {killed}")
            self.event("killed", pid=pid, before_ms=before_ms, after_ms=after_ms, window_wall=window["wall"])
            process.wait(timeout=60)
        finally:
            watcher.terminate()
            self.save("logcat-play-ADUR.txt", "".join(lines))
        text = output.read_text()
        if "Process crashed" not in text or "FAILURES!!!" in text or "AssertionError" in text:
            raise Failure(f"The play stage did not end by the kill alone: {output}")
        for _ in range(20):
            if not self.pid():
                break
            time.sleep(0.1)
        if self.pid():
            raise Failure(f"The app survived SIGKILL: {self.pid()}")

        run = json.loads(self.pull_private("files/audio-durability/run.json", "run.json"))
        relative = run["progressFile"].split(f"/{PACKAGE}/", 1)[1]
        progress = self.pull_private(relative, "progress-at-kill.json")
        sha = hashlib.sha256(progress).hexdigest()
        samples = [json.loads(l) for l in self.pull_private("files/audio-durability/play-samples.jsonl", "play-samples.jsonl").decode().splitlines() if l.strip()]
        record = json.loads(progress)["audio-durability-book"]
        disk_pos = round(record["position"]["positionSeconds"] * 1000)
        disk_obs = record["observedAtEpochMs"]

        last = [s for s in samples if s["wall"] <= after_ms][-1]
        if not last["playing"]:
            raise Failure(f"Not playing just before the kill: {last}")
        if after_ms - last["wall"] > 500:
            raise Failure(f"Sampling stopped {after_ms - last['wall']}ms before the kill")
        if last["diskPos"] != disk_pos or last["diskObs"] != disk_obs:
            raise Failure(f"progress.json at death {disk_pos}/{disk_obs} differs from the last sampled {last}")
        # Heard at death, conservatively from the latest moment the kill could have landed.
        heard_at_kill = last["pos"] + (after_ms - last["wall"])
        loss = heard_at_kill - disk_pos
        since_checkpoint = after_ms - disk_obs
        kill = {
            "pid": pid, "kill_before_ms": before_ms, "kill_after_ms": after_ms, "last_sample": last,
            "heard_at_kill_ms": heard_at_kill, "disk_pos_ms": disk_pos, "disk_observed_ms": disk_obs,
            "lost_listening_ms": loss, "ms_since_checkpoint_at_kill": since_checkpoint,
            "pending_at_kill": record.get("pending"), "dirty_at_kill": record.get("dirty", False),
            "progress_sha256": sha,
        }
        self.record(kill=kill)
        self.event("death-state", **kill)
        if loss > LOSS_BOUND_MS:
            raise Failure(f"{loss}ms of listening lost at death (bound {LOSS_BOUND_MS})")
        # A checkpoint write takes milliseconds; 300ms clear of it is between checkpoints.
        if loss < 300 or since_checkpoint < 300:
            raise Failure(f"The kill landed on a checkpoint boundary ({loss}ms, {since_checkpoint}ms); not the experiment asked for")

        # Listening and syncing well apart. Nothing may touch the file meanwhile.
        restarts = []
        end = time.monotonic() + self.args.gap_s
        while time.monotonic() < end:
            if self.pid():
                restarts.append({"t": time.strftime("%H:%M:%S"), "pid": self.pid()})
            time.sleep(1)
        again = hashlib.sha256(self.adb("exec-out", "run-as", PACKAGE, "cat", relative, binary=True)).hexdigest()
        self.record(gap_s=self.args.gap_s, restarts_during_gap=restarts, progress_sha256_after_gap=again)
        if again != sha:
            raise Failure("progress.json changed while the app was dead")
        return {"pid": pid, "kill_after_ms": after_ms, "sha": sha}

    def reopen(self, play):
        process, output = self.instrument(
            "reopen", "-e", "shelfarrKilledPid", str(play["pid"]), "-e", "shelfarrKillWallMs", str(play["kill_after_ms"]),
            "-e", "shelfarrKilledProgressSha256", play["sha"])
        process.wait(timeout=300)
        self.save("logcat-all.txt", self.adb("logcat", "-d", "-v", "epoch", check=False))
        self.save("logcat-crash.txt", self.adb("logcat", "-d", "-b", "crash", check=False))
        text = output.read_text()
        if "OK (1 test)" not in text or "AssumptionViolatedException" in text:
            raise Failure(f"The reopen stage failed: {output}")
        result = json.loads(self.pull_private("files/audio-durability/reopen-result.json", "reopen-result.json"))
        self.pull_private("files/audio-durability/reopen-samples.jsonl", "reopen-samples.jsonl")
        self.record(reopen=result)
        self.event("reopen-passed", savedPos=result["savedPos"], firstReopenPos=result["firstReopenPos"],
                   postPauseRestart=result["postPauseRestart"], postPauseTarget=result["postPauseTarget"])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial", required=True)
    parser.add_argument("--app-apk", required=True)
    parser.add_argument("--test-apk", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--port", type=int, default=48931)
    parser.add_argument("--kill-after-checkpoint-ms", type=int, default=2_000)
    parser.add_argument("--gap-s", type=int, default=20)
    args = parser.parse_args()
    controller = Controller(args)
    try:
        controller.run()
    except Failure as error:
        controller.record(result="failed", failure=str(error))
        controller.event("failed", reason=str(error))
        try:
            controller.save("logcat-all.txt", controller.adb("logcat", "-d", "-v", "epoch", check=False))
            controller.save("logcat-crash.txt", controller.adb("logcat", "-d", "-b", "crash", check=False))
        except Exception:
            pass
        # Keep whatever the probe recorded on the device, for the diagnosis.
        for name in ("run.json", "play-samples.jsonl", "reopen-samples.jsonl", "reopen-result.json"):
            try:
                controller.pull_private(f"files/audio-durability/{name}", name)
            except Exception:
                pass
        sys.exit(1)


if __name__ == "__main__":
    main()
