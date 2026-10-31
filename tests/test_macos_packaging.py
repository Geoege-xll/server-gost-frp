"""macOS manifests, mocked VPS packaging and two-stage menu; no host services."""
import hashlib
import io
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import tarfile
import tempfile
import time
import unittest
import zipfile

from test_deployment import ROOT, bash, release


def mac_release_fixture(directory, component, tag, missing=None):
    repo, prefix = {"gost": ("go-gost/gost", "gost"), "frpc": ("fatedier/frp", "frp")}[component]
    assets = []
    for architecture in ("amd64", "arm64"):
        name = f"{prefix}_{tag.lstrip('v')}_darwin_{architecture}.tar.gz"
        path = Path(directory) / name
        with tarfile.open(path, "w:gz") as archive:
            data = f"inert fixture {component} {architecture}".encode()
            entry = tarfile.TarInfo(f"release/{component}")
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
        assets.append({"name": name,
                       "browser_download_url": f"https://github.com/{repo}/releases/download/{tag}/{name}",
                       "digest": None if architecture == missing else "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()})
    metadata = Path(directory) / (component + "-release.json")
    metadata.write_text(json.dumps({"tag_name": tag, "assets": assets}), encoding="utf-8")
    return metadata


class MacPackagingTests(unittest.TestCase):
    def test_manifest_pins_both_architectures_and_no_servy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gost = mac_release_fixture(root, "gost", "v3.3.2")
            frp = mac_release_fixture(root, "frpc", "v0.71.1")
            output = root / "components.json"
            for scheme, version, extra in (("gost", "v3.3.2", []), ("frp", "v0.71.1", [frp])):
                with self.subTest(scheme=scheme):
                    release.macos_manifest(output, scheme, version, gost, *extra)
                    data = json.loads(output.read_text())
                    self.assertEqual(data["platform"], "macos")
                    self.assertEqual(data["architectures"], ["amd64", "arm64"])
                    self.assertEqual(data["scheme"], scheme)
                    self.assertEqual(data["mode"], "offline")
                    self.assertEqual(data["tunnelVersion"], version)
                    expected = [("gost", "amd64"), ("gost", "arm64")]
                    if scheme == "frp":
                        expected += [("frpc", "amd64"), ("frpc", "arm64")]
                    self.assertEqual([(c["id"], c["architecture"]) for c in data["components"]], expected)
                    for component in data["components"]:
                        self.assertNotIn("latest", component["url"])
                        self.assertEqual(len(component["sha256"]), 64)
                        self.assertIn("_darwin_", component["asset"])

    def test_manifest_invalid_sources_abort_without_output(self):
        cases = ("scheme", "missing-frp", "extra-frp", "version", "old-gost", "old-frp", "digest-amd64", "digest-arm64", "foreign-url", "prerelease")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                gost = mac_release_fixture(root, "gost", "v3.3.1" if case == "old-gost" else "v3.3.2",
                                           missing=case[7:] if case.startswith("digest-") else None)
                frp = mac_release_fixture(root, "frpc", "v0.71.0" if case == "old-frp" else "v0.71.1")
                if case in ("foreign-url", "prerelease"):
                    data = json.loads(gost.read_text())
                    if case == "foreign-url":
                        data["assets"][0]["browser_download_url"] = "https://example.org/file.tar.gz"
                    else:
                        data["prerelease"] = True
                    gost.write_text(json.dumps(data))
                scheme = "bad" if case == "scheme" else "gost" if case == "extra-frp" else "frp"
                extra = [] if case == "missing-frp" else [frp]
                output = root / "components.json"
                with self.assertRaises(ValueError):
                    release.macos_manifest(output, scheme,
                                           "v0.72.0" if case == "version" else "v0.71.1", gost, *extra)
                self.assertFalse(output.exists())

    def test_mac_template_injection_preserves_lf_and_rejects_shell_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            conf = root / "client.conf"
            conf.write_text("VPS_PUBLIC_IP=VPS_PUBLIC_IP_PLACEHOLDER\nGOST_PASS=GOST_PASS_PLACEHOLDER\n")
            shell = root / "setup.sh"
            shell.write_bytes(b"#!/bin/bash\r\n# template\r\n")
            release.inject(root, ["VPS_PUBLIC_IP=203.0.113.1", "GOST_PASS=abc_123"])
            self.assertEqual(conf.read_text(), "VPS_PUBLIC_IP=203.0.113.1\nGOST_PASS=abc_123\n")
            self.assertNotIn(b"\r", shell.read_bytes())
            for unsafe in ("x;id", "$(id)", "x\ny", "'quote"):
                with self.assertRaises(ValueError):
                    release.inject(root, ["GOST_PASS=" + unsafe])
            conf.write_text("TOKEN=TOKEN_PLACEHOLDER\n")
            with self.assertRaises(ValueError):
                release.inject(root, [])

    @unittest.skipUnless(shutil.which("zip") and shutil.which("unzip"), "zip/unzip not installed")
    def test_offline_package_for_both_schemes(self):
        for scheme in ("gost", "frp"):
            with self.subTest(scheme=scheme), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                work = root / "work"
                work.mkdir()
                certs = root / "certs"
                certs.mkdir()
                for name in ("ca.crt", "client.crt", "client.key", "ca.key", "server.key"):
                    (certs / name).write_text("inert fixture")
                gost = mac_release_fixture(root, "gost", "v3.3.2")
                frp = mac_release_fixture(root, "frpc", "v0.71.1")
                shutil.copyfile(gost if scheme == "gost" else frp, work / "core-release.json")
                template = ROOT / ("01_Pure_GOST_v3/macos_client_gost_v3" if scheme == "gost" else "02_FRP_GOST/macos_client_frp_gost")
                result = bash('''
source "$1"
REPO_ROOT=$2
WORK_DIR=$3/work
FIXTURES=$3
SCHEME=$4
CORE_TAG=$5
PUBLIC_IP=203.0.113.1
AUTH_TOKEN=token_test
RELAY_USER=relay_test
RELAY_PASS=relay_secret
GOST_USER=user_test
GOST_PASS=socks_secret
release_info() {
    [ "$1" = go-gost/gost ] || exit 98
    cp "$FIXTURES/gost-release.json" "$3"
    printf 'v3.3.2\\n'
}
https_get() {
    printf '%s\\n' "$1" >> "$WORK_DIR/downloads"
    cp "$FIXTURES/${1##*/}" "$2"
}
build_macos_package "$6" client.zip "$FIXTURES/certs"
''', ROOT / "lib/deploy.sh", ROOT, root, scheme, "v3.3.2" if scheme == "gost" else "v0.71.1", template)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue((work / "downloads").exists())
                with zipfile.ZipFile(work / "client.zip") as archive:
                    names = archive.namelist()
                    self.assertIn("macos_client.sh", names)
                    self.assertIn("setup_macos.sh", names)
                    self.assertIn("uninstall_macos.sh", names)
                    self.assertIn("client.key", names)
                    for forbidden in ("ca.key", "server.key", "gost.exe", "frpc.exe", "windows_components.ps1", "SOCKS5账号密码.txt"):
                        self.assertNotIn(forbidden, names)
                    self.assertFalse(any("servy" in name.lower() for name in names))
                    manifest = json.loads(archive.read("components.json"))
                    self.assertEqual(manifest["mode"], "offline")
                    self.assertEqual(manifest["scheme"], scheme)
                    conf = archive.read("client.conf").decode()
                    self.assertIn("GOST_USER=user_test\n", conf)
                    self.assertIn("GOST_PASS=socks_secret\n", conf)
                    self.assertNotIn("PLACEHOLDER", conf)
                    self.assertEqual(len(conf.splitlines()), 6)
                    for private in ("client.conf", "client.key"):
                        self.assertEqual((archive.getinfo(private).external_attr >> 16) & 0o777, 0o600)
                    for name in names:
                        if name.endswith(".sh"):
                            self.assertNotIn(b"\r", archive.read(name))
                            self.assertNotIn(b"_PLACEHOLDER", archive.read(name))
                    hashes = archive.read("offline-sha256.txt").decode().splitlines()
                    expected = [f"bin/{arch}/{component}" for component in (["gost", "frpc"] if scheme == "frp" else ["gost"]) for arch in ("amd64", "arm64")]
                    self.assertEqual([line.split("  ")[1] for line in hashes], expected)
                    for line in hashes:
                        digest, name = line.split("  ")
                        self.assertEqual(hashlib.sha256(archive.read(name)).hexdigest(), digest)
                    self.assertIn("Package mode: offline", archive.read("VERSIONS.txt").decode())

    def test_invalid_mac_metadata_aborts_before_download_or_zip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            work.mkdir()
            metadata = mac_release_fixture(root, "gost", "v3.3.2", missing="arm64")
            shutil.copyfile(metadata, work / "core-release.json")
            certs = root / "certs"
            certs.mkdir()
            for name in ("ca.crt", "client.crt", "client.key"):
                (certs / name).write_text("inert fixture")
            result = bash('''
source "$1"
REPO_ROOT=$2
WORK_DIR=$3/work
SCHEME=gost
CORE_TAG=v3.3.2
download_asset() { printf SHOULD_NOT_DOWNLOAD; exit 97; }
build_macos_package "$REPO_ROOT/01_Pure_GOST_v3/macos_client_gost_v3" client.zip "$3/certs"
printf SHOULD_NOT_INSTALL
''', ROOT / "lib/deploy.sh", ROOT, root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("SHA-256 digest missing", result.stderr)
            self.assertNotIn("SHOULD_NOT", result.stdout)
            self.assertFalse((work / "client.zip").exists())

    def test_mac_package_does_not_install_sevenzip(self):
        result = bash('''
source "$1"
CLIENT_PLATFORM=mac
apt-get() { printf '%s\\n' "$*"; }
apt-cache() { return 99; }
command() {
    case "$*" in '-v 7z'|'-v 7zz') return 1 ;; *) builtin command "$@" ;; esac
}
install_dependencies install
''', ROOT / "lib/deploy.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("7zip", result.stdout)

    def test_mac_frps_does_not_allow_rdp(self):
        result = bash('source "$1"; CLIENT_PLATFORM=mac; render_frps_server /etc/frp token', ROOT / "lib/deploy.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('proxyBindAddr = "127.0.0.1"', result.stdout)
        self.assertIn('allowPorts = [{ single = 10001 }]', result.stdout)
        self.assertIn('maxPortsPerClient = 1', result.stdout)
        self.assertNotIn("33389", result.stdout)

    def test_client_flags_reject_invalid_or_upgrade_use(self):
        for args in (("--client",), ("--client", "linux"), ("--upgrade", "--client", "mac"), ("--client", "windows", "--upgrade")):
            result = subprocess.run(["bash", str(ROOT / "install.sh"), "gost", *args], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("--client", result.stderr)
        for client in ("windows", "mac", "macos"):
            result = subprocess.run(["bash", str(ROOT / "install.sh"), "frp", "--client", client, "--help"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_package_names_and_platform_choices(self):
        for scheme, suffix in (("gost", "gost_v3"), ("frp", "frp_gost")):
            for client, prefix in (("windows", "windows"), ("mac", "macos")):
                result = bash('source "$1"; client_package_name "$2" "$3"', ROOT / "lib/deploy.sh", scheme, client)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), f"{prefix}_{suffix}_pkg.zip")
        for choice, expected in (("1", "windows"), ("2", "mac"), ("macos", "mac"), ("", None), ("3", None)):
            result = bash('source "$1"; client_platform_from_choice "$2"', ROOT / "lib/deploy.sh", choice)
            self.assertEqual(result.returncode == 0, expected is not None)
            if expected:
                self.assertEqual(result.stdout.strip(), expected)

    @unittest.skipUnless(os.name == "posix", "requires POSIX pseudo-terminal")
    def test_interactive_menu_selects_scheme_then_platform(self):
        import pty
        for first, scheme in (("1", "gost"), ("2", "frp")):
            for second, client in (("1", "windows"), ("2", "mac")):
                with self.subTest(scheme=scheme, client=client), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    (root / "lib").mkdir()
                    shutil.copyfile(ROOT / "install.sh", root / "install.sh")
                    (root / "lib/release.py").write_text("# harmless menu fixture\n")
                    (root / "lib/deploy.sh").write_text(f'''source '{ROOT}/lib/deploy.sh'
deploy_main() {{
    printf 'TEST_SCHEME=%s\\n' "$1"
    local selected
    selected=$(select_client_platform)
    printf 'TEST_CLIENT=%s\\n' "$selected"
}}
''')
                    pid, fd = pty.fork()
                    if pid == 0:
                        os.execv("/bin/bash", ["/bin/bash", str(root / "install.sh")])
                    output = bytearray()
                    status = None
                    try:
                        os.write(fd, (first + "\n" + second + "\n").encode())
                        deadline = time.monotonic() + 10
                        while time.monotonic() < deadline:
                            if select.select([fd], [], [], 0.1)[0]:
                                try:
                                    chunk = os.read(fd, 65536)
                                except OSError:
                                    break
                                if not chunk:
                                    break
                                output.extend(chunk)
                        done, status = os.waitpid(pid, os.WNOHANG)
                        if not done:
                            os.kill(pid, signal.SIGTERM)
                            os.waitpid(pid, 0)
                            self.fail("interactive menu did not exit")
                    finally:
                        os.close(fd)
                    self.assertTrue(os.WIFEXITED(status), output.decode())
                    self.assertEqual(os.WEXITSTATUS(status), 0, output.decode())
                    text = output.decode()
                    self.assertIn("TEST_SCHEME=" + scheme, text)
                    self.assertIn("TEST_CLIENT=" + client, text)
                    self.assertLess(text.index("TEST_SCHEME="), text.index("请选择住宅机系统"))


if __name__ == "__main__":
    unittest.main()
