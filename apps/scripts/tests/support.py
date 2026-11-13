"""Shared fixtures: the scripts under test, a stub Android SDK and a stub gh."""

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

SCRIPTS = Path(__file__).resolve().parent.parent
MANIFEST = SCRIPTS / "android-update-manifest.py"
CATALOG = SCRIPTS / "android-update-catalog.py"
REPO = "Pedro-Revez-Silva/shelfarr"
CATALOG_URL = f"https://github.com/{REPO}/releases/download/android-catalog-v1/android-catalog.json"
SIGNER = "ab" * 32
OTHER_SIGNER = "cd" * 32
COMMIT = "1" * 40


def load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def asset_url(channel: str, version: str, code: int, repo: str = REPO) -> str:
    return (f"https://github.com/{repo}/releases/download/android-{channel}-v{version}/"
            f"shelfarr-android-{channel}-{version}-{code}.apk")


def entry(code: int = 10, channel: str = "release", version: str = None, apis=(1,), sha: str = None, **extra) -> dict:
    version = version or f"2026.11.{code}"
    package = {"release": "org.shelfarr.app", "development": "org.shelfarr.app.debug"}[channel]
    name = version if channel == "release" else f"{version}-debug"
    result = {
        "channel": channel,
        "package_name": package,
        "version_code": code,
        "version_name": name,
        "apk_url": asset_url(channel, version, code),
        "size_bytes": 1000 + code,
        "sha256": sha or hashlib.sha256(f"{channel}-{code}".encode()).hexdigest(),
        "min_sdk": 26,
        "consumer_api_versions": list(apis),
    }
    result.update(extra)
    return result


def catalog(*entries) -> dict:
    return {"schema_version": 1, "releases": list(entries)}


class ScratchCase(unittest.TestCase):
    """A fresh directory per test, under TMPDIR."""

    def setUp(self):
        self._scratch = tempfile.TemporaryDirectory(prefix="android-publish-test-")
        self.dir = Path(self._scratch.name)
        self.addCleanup(self._scratch.cleanup)

    def write_json(self, name: str, value) -> Path:
        path = self.dir / name
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def run_script(self, script: Path, *arguments, env=None):
        environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "PYTHONDONTWRITEBYTECODE": "1",
            "TMPDIR": str(self.dir),
            "LANG": "C.UTF-8",
        }
        environment.update(env or {})
        return subprocess.run([sys.executable, str(script), *map(str, arguments)],
                              capture_output=True, text=True, env=environment)


def make_sdk(root: Path) -> Path:
    """build-tools/36.0.0 with apksigner and aapt2 that print fixture files."""
    tools = root / "sdk" / "build-tools" / "36.0.0"
    tools.mkdir(parents=True)
    for name, variable in (("apksigner", "STUB_APKSIGNER"), ("aapt2", "STUB_AAPT2")):
        script = tools / name
        script.write_text(textwrap.dedent(f"""\
            #!/bin/sh
            cat "${variable}"
            exit "${{{variable}_EXIT:-0}}"
            """))
        script.chmod(0o755)
    # An older build-tools must not be preferred.
    old = root / "sdk" / "build-tools" / "9.0.0"
    old.mkdir(parents=True)
    for name in ("apksigner", "aapt2"):
        (old / name).write_text("#!/bin/sh\necho old tools >&2\nexit 9\n")
        (old / name).chmod(0o755)
    return root / "sdk"


def apksigner_output(*digests, v2=True) -> str:
    lines = [
        "Verifies",
        "Verified using v1 scheme (JAR signing): false",
        f"Verified using v2 scheme (APK Signature Scheme v2): {'true' if v2 else 'false'}",
        f"Verified using v3 scheme (APK Signature Scheme v3): {'true' if v2 else 'false'}",
        f"Number of signers: {len(digests)}",
    ]
    for number, digest in enumerate(digests, 1):
        lines += [f"Signer #{number} certificate DN: CN=Shelfarr", f"Signer #{number} certificate SHA-256 digest: {digest}"]
    return "\n".join(lines) + "\n"


def aapt2_output(package="org.shelfarr.app", code=12, name="2026.11.8.1", min_sdk=26, debuggable=False, test_only=False) -> str:
    lines = [
        f"package: name='{package}' versionCode='{code}' versionName='{name}' platformBuildVersionName='17'",
        f"minSdkVersion:'{min_sdk}'" if min_sdk else "",
        "targetSdkVersion:'37'",
        "application-label:'Shelfarr'",
    ]
    if debuggable:
        lines.append("application-debuggable")
    if test_only:
        lines.append("testOnly='-1'")
    return "\n".join(line for line in lines if line) + "\n"


GH_STUB = r'''#!/usr/bin/env python3
import json, os, re, shutil, sys
from pathlib import Path

state_path = Path(os.environ["STUB_GH_STATE"])
state = json.loads(state_path.read_text())
argv = sys.argv[1:]
with open(os.environ["STUB_GH_LOG"], "a") as log:
    log.write(json.dumps(argv) + "\n")

def save():
    state_path.write_text(json.dumps(state))

def die(status, text):
    sys.stderr.write(f"gh: {text} (HTTP {status})\n")
    sys.exit(1)

def maybe_fail(call):
    for rule in state.get("fail", []):
        if rule.get("times", 1) > 0 and re.search(rule["match"], call):
            rule["times"] = rule.get("times", 1) - 1
            save()
            die(rule.get("status", 502), "Injected failure")

def view(release):
    return {"tag_name": release["tag"], "draft": release.get("draft", False),
            "prerelease": release.get("prerelease", False),
            "assets": [{"id": a["id"], "name": n, "size": a["size"], "state": a.get("state", "uploaded")}
                       for n, a in release["assets"].items()]}

def find_asset(asset_id):
    for release in state["releases"].values():
        for name, asset in release["assets"].items():
            if asset["id"] == asset_id:
                return release, name, asset
    die(404, "Not Found")

def new_blob(data):
    state["next_id"] += 1
    path = Path(state["blobs"]) / str(state["next_id"])
    path.write_bytes(data)
    return state["next_id"], str(path)

if argv[:1] == ["api"]:
    method, headers, body, path, rest = "GET", [], None, None, argv[1:]
    while rest:
        item = rest.pop(0)
        if item in ("--method", "-X"):
            method = rest.pop(0)
        elif item == "-H":
            headers.append(rest.pop(0))
        elif item == "--input":
            source = rest.pop(0)
            body = json.loads(sys.stdin.read() if source == "-" else Path(source).read_text())
        else:
            path = item
    maybe_fail(f"{method} {path}")
    prefix = f"repos/{state['repo']}/"
    if not path.startswith(prefix):
        die(404, "Not Found")
    route = path[len(prefix):]
    match = re.fullmatch(r"releases/tags/(.+)", route)
    if method == "GET" and match:
        release = state["releases"].get(match.group(1))
        if not release:
            die(404, "Not Found")
        print(json.dumps(view(release)))
        sys.exit(0)
    match = re.fullmatch(r"git/ref/tags/(.+)", route)
    if method == "GET" and match:
        sha = state["tags"].get(match.group(1))
        if not sha:
            die(404, "Not Found")
        print(json.dumps({"object": {"type": "commit", "sha": sha}}))
        sys.exit(0)
    match = re.fullmatch(r"releases/assets/(\d+)", route)
    if match:
        release, name, asset = find_asset(int(match.group(1)))
        if method == "GET":
            assert "Accept: application/octet-stream" in headers
            sys.stdout.buffer.write(Path(asset["blob"]).read_bytes())
        elif method == "DELETE":
            del release["assets"][name]
        elif method == "PATCH":
            if body["name"] in release["assets"]:
                die(422, "Validation Failed")
            release["assets"][body["name"]] = release["assets"].pop(name)
        save()
        sys.exit(0)
    if method == "POST" and route == "releases":
        tag = body["tag_name"]
        if tag in state["releases"]:
            die(422, "Validation Failed")
        state["tags"].setdefault(tag, body["target_commitish"])
        state["releases"][tag] = {"tag": tag, "prerelease": body["prerelease"], "draft": body["draft"],
                                  "make_latest": body["make_latest"], "body": body["body"], "assets": {}}
        save()
        print(json.dumps(view(state["releases"][tag])))
        sys.exit(0)
    die(404, "Not Found")

if argv[:2] == ["release", "upload"]:
    tag, source = argv[2], Path(argv[3])
    assert argv[4:] == ["--repo", state["repo"]], argv
    maybe_fail(f"upload {tag} {source.name}")
    release = state["releases"].get(tag)
    if not release:
        die(404, "Not Found")
    if source.name in release["assets"]:
        sys.stderr.write("asset under the same name already exists\n")
        sys.exit(1)
    data = source.read_bytes()
    asset_id, blob = new_blob(data)
    release["assets"][source.name] = {"id": asset_id, "size": len(data), "blob": blob, "state": "uploaded"}
    save()
    sys.exit(0)

sys.stderr.write(f"unsupported stub call {argv}\n")
sys.exit(2)
'''


class FakeGitHub:
    """A stateful stand-in for the parts of gh the publisher uses."""

    def __init__(self, root: Path, repo: str = REPO):
        self.root = root
        bin_dir = root / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text(GH_STUB)
        (bin_dir / "gh").chmod(0o755)
        (root / "blobs").mkdir()
        self.state_path = root / "gh-state.json"
        self.log_path = root / "gh-log.jsonl"
        self.log_path.write_text("")
        self.save({"repo": repo, "next_id": 100, "blobs": str(root / "blobs"), "releases": {}, "tags": {}, "fail": []})
        self.env = {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}",
            "STUB_GH_STATE": str(self.state_path),
            "STUB_GH_LOG": str(self.log_path),
        }

    def state(self) -> dict:
        return json.loads(self.state_path.read_text())

    def save(self, state: dict) -> None:
        self.state_path.write_text(json.dumps(state))

    def add_release(self, tag: str, commit: str = COMMIT, assets: dict = None, **fields) -> None:
        state = self.state()
        release = {"tag": tag, "assets": {}, **fields}
        for name, data in (assets or {}).items():
            state["next_id"] += 1
            blob = Path(state["blobs"]) / str(state["next_id"])
            blob.write_bytes(data)
            release["assets"][name] = {"id": state["next_id"], "size": len(data), "blob": str(blob), "state": "uploaded"}
        state["releases"][tag] = release
        state["tags"][tag] = commit
        self.save(state)

    def asset(self, tag: str, name: str):
        asset = self.state()["releases"].get(tag, {}).get("assets", {}).get(name)
        return Path(asset["blob"]).read_bytes() if asset else None

    def fail(self, match: str, times: int = 1, status: int = 502) -> None:
        state = self.state()
        state["fail"].append({"match": match, "times": times, "status": status})
        self.save(state)

    def calls(self) -> list:
        return [json.loads(line) for line in self.log_path.read_text().splitlines()]
