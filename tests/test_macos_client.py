"""macOS fixture/static tests only: no downloads, official binaries, sudo or launchd mutation."""
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "lib/macos_client.sh"
TEMPLATES = {
    "gost": ROOT / "01_Pure_GOST_v3/macos_client_gost_v3",
    "frp": ROOT / "02_FRP_GOST/macos_client_frp_gost",
}
IS_MAC = sys.platform == "darwin"
CONF = ("VPS_PUBLIC_IP=203.0.113.7\nTOKEN=token_test\nRELAY_USER=relay_test\n"
        "RELAY_PASS=relay_secret\nGOST_USER=socks_test\nGOST_PASS=socks_secret\n")


def shell(code, *args):
    return subprocess.run(["/bin/bash", "-c", 'set -euo pipefail\nsource "$1"\n' + code,
                           "test", str(HELPER), *map(str, args)],
                          cwd="/", capture_output=True, text=True,
                          env=dict(os.environ, LC_ALL="C"))


def manifest(scheme="gost", mode="offline"):
    data = {"schemaVersion": 1, "platform": "macos", "scheme": scheme, "mode": mode,
            "tunnelVersion": "v3.3.2" if scheme == "gost" else "v0.71.1",
            "architectures": ["amd64", "arm64"], "components": []}
    for component in ["gost"] + (["frpc"] if scheme == "frp" else []):
        repo, tag, prefix = (("go-gost/gost", "v3.3.2", "gost") if component == "gost"
                             else ("fatedier/frp", "v0.71.1", "frp"))
        for arch in ("amd64", "arm64"):
            asset = f"{prefix}_{tag[1:]}_darwin_{arch}.tar.gz"
            data["components"].append({"id": component, "architecture": arch, "repo": repo,
                "version": tag, "asset": asset,
                "url": f"https://github.com/{repo}/releases/download/{tag}/{asset}", "sha256": "a" * 64})
    return data


class PureHelperTests(unittest.TestCase):
    def test_source_has_no_actions(self):
        result = shell("printf definitions-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "definitions-only")
        self.assertEqual(result.stderr, "")

    def test_bash32_syntax(self):
        for script in [HELPER] + [file for folder in TEMPLATES.values() for file in folder.glob("*.sh")]:
            result = subprocess.run(["/bin/bash", "-n", str(script)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        text = HELPER.read_text()
        for forbidden in ("declare -A", "mapfile", "readarray", "${value,,}"):
            self.assertNotIn(forbidden, text)
        self.assertIsNone(re.search(r"\$[A-Za-z_][A-Za-z_0-9]*[^\x00-\x7f]", text))

    def test_help_without_config_from_unrelated_directory(self):
        for scheme, folder in TEMPLATES.items():
            with self.subTest(scheme=scheme), tempfile.TemporaryDirectory() as temporary:
                package = Path(temporary).resolve() / "package with spaces"
                shutil.copytree(folder, package)
                shutil.copyfile(HELPER, package / "macos_client.sh")
                for name in ("setup_macos.sh", "uninstall_macos.sh"):
                    result = subprocess.run(["/bin/bash", str(package / name), "--help"], cwd="/",
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("macOS 12+", result.stdout)
                    self.assertIn("10001", result.stdout)
                    self.assertFalse((package / "client.conf").exists())
                self.assertEqual(sorted(p.name for p in package.iterdir()),
                                 sorted([p.name for p in folder.iterdir()] + ["macos_client.sh"]))

    def test_architecture_native_and_rosetta(self):
        for machine, arm64, expected in (("arm64", "1", "arm64"), ("x86_64", "1", "arm64"),
                                        ("x86_64", "0", "amd64"), ("x86_64", "unknown", "amd64"),
                                        ("aarch64", "1", "arm64"), ("ppc", "0", None)):
            with self.subTest(machine=machine, arm64=arm64):
                result = shell('mc_arch "$2" "$3"', machine, arm64)
                self.assertEqual(result.returncode == 0, expected is not None, result.stderr)
                if expected:
                    self.assertEqual(result.stdout.strip(), expected)

    def test_version_minimum(self):
        for version, minimum, valid in (("v3.3.2", "3.3.2", True), ("3.3.1", "3.3.2", False),
                                         ("v3.4", "3.3.2", True), ("v3.3", "3.3.2", False),
                                         ("v0.71.1", "0.71.1", True), ("0.72.0", "0.71.1", True),
                                         ("v0.72", "0.71.1", True), ("v0.71", "0.71.1", False),
                                         ("v0.71.1-rc1", "0.71.1", False), ("latest", "3.3.2", False)):
            result = shell('mc_version "$2" "$3"', version, minimum)
            self.assertEqual(result.returncode == 0, valid, result.stderr)

    def test_conf_exact_injected_values_not_shell(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary).resolve() / "client.conf"
            config.write_text(CONF)
            result = shell('mc_read_conf "$2"; printf "%s|%s|%s|%s|%s|%s" '
                           '"$MC_IP" "$MC_TOKEN" "$MC_RELAY_USER" "$MC_RELAY_PASS" "$MC_GOST_USER" "$MC_GOST_PASS"', config)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "203.0.113.7|token_test|relay_test|relay_secret|socks_test|socks_secret")
            invalid = [CONF.replace("203.0.113.7", ip) for ip in ("::1", "127.1", "256.0.0.1", "1.2.3.04")]
            invalid += [CONF.replace("socks_secret", secret) for secret in
                        ("$(touch /tmp/MUST_NOT_EXECUTE)", "bad;command", '"quoted"', "GOST_PASS_PLACEHOLDER", "")]
            invalid += [CONF + "GOST_PASS=duplicate\n", CONF + "EXTRA=value\n", CONF.replace("TOKEN=token_test\n", ""),
                        CONF + "\n", CONF.replace("\n", "\r\n")]
            for text in invalid:
                config.write_text(text)
                result = shell('mc_read_conf "$2"', config)
                self.assertNotEqual(result.returncode, 0, text)
            self.assertNotIn("eval ", HELPER.read_text())
            self.assertNotRegex(HELPER.read_text(), r"(?:source|\.)\s+[^\n]*client\.conf")

    def test_symlink_ancestors_rejected_without_globbing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / "real").mkdir()
            (root / "link").symlink_to(root / "real", target_is_directory=True)
            self.assertNotEqual(shell('mc_no_links "$2"', root / "link/file").returncode, 0)
            self.assertEqual(shell('mc_no_links "$2"', root / "literal*[brackets]/file").returncode, 0)

    def test_config_rendering_and_credential_scope(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary).resolve() / "client.conf"
            config.write_text(CONF)
            for scheme in ("gost", "frp"):
                result = shell('mc_read_conf "$2"; mc_render_gost "$3"', config, scheme)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('addr: "127.0.0.1:10000"', result.stdout)
                self.assertIn('username: "socks_test"', result.stdout)
                self.assertIn('password: "socks_secret"', result.stdout)
                self.assertNotIn("33389", result.stdout)
                self.assertNotIn("3389", result.stdout)
                if scheme == "gost":
                    self.assertEqual(len(re.findall(r"listener:\n\s+type: rtcp\n\s+chain: relay-chain", result.stdout)), 1)
                    for required in ('addr: "203.0.113.7:9000"', 'addr: "127.0.0.1:10001"', "secure: true",
                                     'serverName: "203.0.113.7"', "type: mtls", 'caFile: "config/certs/ca.crt"'):
                        self.assertIn(required, result.stdout)
                else:
                    self.assertNotIn("rtcp", result.stdout)
            frpc = shell('mc_read_conf "$2"; mc_render_frpc', config)
            self.assertEqual(frpc.returncode, 0, frpc.stderr)
            self.assertEqual(frpc.stdout.count("[[proxies]]"), 1)
            for required in ('transport.wireProtocol = "v2"', "transport.tcpMux = true", "remotePort = 10001",
                             'transport.tls.serverName = "203.0.113.7"', 'auth.token = "token_test"'):
                self.assertIn(required, frpc.stdout)
            self.assertNotIn("33389", frpc.stdout)
            record = shell('mc_read_conf "$2"; mc_credentials gost', config)
            for value in ("socks_test", "socks_secret", "127.0.0.1:10000", "127.0.0.1:10001", "不对公网开放"):
                self.assertIn(value, record.stdout)
            for secret in ("token_test", "relay_secret", "client.key"):
                self.assertNotIn(secret, record.stdout)

    def test_launchd_rendering(self):
        for scheme in ("gost", "frp"):
            for component in ["gost"] + (["frpc"] if scheme == "frp" else []):
                runtime = f"/Library/Application Support/ResidentialTunnel/{scheme}"
                result = shell('mc_render_plist "$2" "$3" "$4" localuser', scheme, component, runtime)
                self.assertEqual(result.returncode, 0, result.stderr)
                data = plistlib.loads(result.stdout.encode())
                self.assertEqual(data["Label"], f"org.residentialtunnel.{scheme}.{component}")
                self.assertEqual(data["UserName"], "localuser")
                self.assertEqual(data["WorkingDirectory"], runtime)
                self.assertEqual(data["ProgramArguments"], [f"{runtime}/bin/{component}",
                    "-C" if component == "gost" else "-c", "config/gost.yaml" if component == "gost" else "config/frpc.toml"])
                self.assertTrue(data["KeepAlive"])
                self.assertTrue(data["RunAtLoad"])
                self.assertEqual(data["ThrottleInterval"], 10)
                self.assertEqual(data["Umask"], 0o77)
                self.assertNotIn("root", data["UserName"])

    def test_loaded_service_snapshot_ownership(self):
        with tempfile.TemporaryDirectory() as temporary:
            snapshot = Path(temporary).resolve() / "snapshot"
            good = ("system/org.residentialtunnel.gost.gost = {\n"
                    "\tpath = /Library/LaunchDaemons/org.residentialtunnel.gost.gost.plist\n"
                    "\tprogram = /Library/Application Support/ResidentialTunnel/gost/bin/gost\n"
                    "\tusername = localuser\n\tpid = 123\n\tstate = running\n}\n")
            for text, valid in ((good, True), (good.replace("username = localuser", "username = root"), False),
                                (good.replace("/bin/gost", "/bin/other"), False), (good + "\tusername = localuser\n", False)):
                snapshot.write_text(text)
                result = shell('mc_validate_snapshot "$2" '
                               '"/Library/Application Support/ResidentialTunnel/gost/bin/gost" localuser '
                               '"/Library/LaunchDaemons/org.residentialtunnel.gost.gost.plist"', snapshot)
                self.assertEqual(result.returncode == 0, valid, result.stderr)

    def test_static_mutation_order_and_scoped_lifecycle(self):
        text = HELPER.read_text()
        install = text[text.index("mc_install() {"):text.index("mc_uninstall() {")]
        for operation in ("mc_read_conf", "mc_manifest", "mc_services_preflight", "mc_prepare_components", "mc_prepare_config", "plutil -lint"):
            self.assertLess(install.index(operation), install.index("mc_stop_services"))
        self.assertLess(install.index("mc_stop_services"), install.index('/bin/mv "$MC_WORK/prepared"'))
        self.assertLess(install.index("MC_TRANSACTION=1"), install.index("mc_stop_services"))
        self.assertIn("mc_rollback", text)
        self.assertIn('MC_KEEP_WORK=1', text)
        self.assertIn('mc_owned_runtime "$MC_RUNTIME"', text)
        self.assertIn('/bin/mkdir -m 700 "$MC_BASE/.installer.lock"', text)
        self.assertIn('mc_validate_snapshot "$MC_WORK/snapshot-$id"', text)
        self.assertIn('/usr/bin/dscl /Local/Default', text)
        self.assertIn('[ "$MC_UID" -ge 501 ]', text)
        self.assertIn('/usr/sbin/chown -R "$MC_UID:$MC_GID"', text)
        self.assertIn('/bin/chmod 600 "$prepared/config/', text)
        for forbidden in ("pkill", "killall", "spctl", "xattr", "pmset", "systemsetup", "socketfilterfw", "dscl -create", "curl", "python", "brew "):
            self.assertNotIn(forbidden, text)
        main = text[text.index("macos_client_main() ("):]
        self.assertLess(main.index("macos_client_help"), main.index("sw_vers"))
        self.assertLess(main.index("macos_client_help"), main.index("MC_BASE="))
        # Offline-only component preparation: bundled binaries are hash-verified in
        # place; the downloader and archive extraction helpers no longer exist.
        prepare = text[text.index("mc_prepare_components() {"):text.index("mc_render_gost() {")]
        self.assertIn('mc_offline "$package" "$scheme"', prepare)
        uninstall = text[text.index("mc_uninstall() {"):text.index("macos_client_help() {")]
        self.assertNotIn("curl", uninstall)
        self.assertNotIn('rm -rf "$MC_BASE"', text)


@unittest.skipUnless(IS_MAC, "Requires macOS builtin plutil/stat")
class MacFixtureTests(unittest.TestCase):
    def test_manifest_accepts_offline_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            file = Path(temporary).resolve() / "components.json"
            for scheme in ("gost", "frp"):
                file.write_text(json.dumps(manifest(scheme)))
                self.assertEqual(shell('mc_manifest "$2" "$3"', file, scheme).returncode, 0)
            file.write_text(json.dumps(manifest("gost", "online")))
            self.assertNotEqual(shell('mc_manifest "$2" gost', file).returncode, 0)

    def test_manifest_rejects_unsafe_contract(self):
        data = manifest("frp")
        changes = []
        for field, value in (("platform", "windows"), ("schemaVersion", "1"), ("mode", "latest"),
                             ("tunnelVersion", "v0.72.0"), ("architectures", ["arm64", "amd64"]),
                             ("architectures", ["amd64"]), ("scheme", "gost")):
            item = copy.deepcopy(data); item[field] = value; changes.append(item)
        for field, value in (("sha256", "A" * 64), ("sha256", "bad"), ("url", "https://evil.example/bin"),
                             ("url", data["components"][0]["url"] + "?x=1"), ("version", "v3.3.1"),
                             ("version", "nightly"), ("asset", "../../bad"), ("repo", "evil/gost"),
                             ("architecture", "arm64"), ("id", "frpc"), ("extra", "unexpected")):
            item = copy.deepcopy(data); item["components"][0][field] = value; changes.append(item)
        item = copy.deepcopy(data); item["components"] = list(reversed(item["components"])); changes.append(item)
        item = copy.deepcopy(data); item["components"].append(copy.deepcopy(item["components"][0])); changes.append(item)
        item = copy.deepcopy(data)
        item["components"][1].update(version="v3.3.3", asset="gost_3.3.3_darwin_arm64.tar.gz",
            url="https://github.com/go-gost/gost/releases/download/v3.3.3/gost_3.3.3_darwin_arm64.tar.gz")
        changes.append(item)
        with tempfile.TemporaryDirectory() as temporary:
            file = Path(temporary).resolve() / "components.json"
            for index, value in enumerate(changes):
                with self.subTest(index=index):
                    file.write_text(json.dumps(value))
                    self.assertNotEqual(shell('mc_manifest "$2" frp', file).returncode, 0)

    def test_hash_and_offline_binary_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            package = Path(temporary).resolve()
            lines = []
            for component in ("gost", "frpc"):
                for arch, cpu in (("amd64", "07000001"), ("arm64", "0c000001")):
                    binary = package / "bin" / arch / component
                    binary.parent.mkdir(parents=True, exist_ok=True)
                    # Only a nonexecutable eight-byte Mach-O header fixture, never run.
                    binary.write_bytes(bytes.fromhex("cffaedfe" + cpu))
                    lines.append(f"{hashlib.sha256(binary.read_bytes()).hexdigest()}  bin/{arch}/{component}\n")
            digests = package / "offline-sha256.txt"
            digests.write_text("".join(lines))
            self.assertEqual(shell('mc_offline "$2" frp', package).returncode, 0)
            for bad in ("".join(reversed(lines)), "".join(lines) + "extra\n", "".join(lines).replace("  bin/", " bin/"),
                        "".join(lines).replace(lines[0][:64], "0" * 64)):
                digests.write_text(bad)
                self.assertNotEqual(shell('mc_offline "$2" frp', package).returncode, 0)
            digests.write_text("".join(lines))
            binary = package / "bin/arm64/frpc"
            binary.unlink(); binary.symlink_to(package / "bin/amd64/frpc")
            self.assertNotEqual(shell('mc_offline "$2" frp', package).returncode, 0)

    def test_plist_ownership_rejects_conflicting_fields(self):
        # Stub only root ownership check to test plist parsing in an unprivileged temp directory.
        with tempfile.TemporaryDirectory() as temporary:
            file = Path(temporary).resolve() / "service.plist"
            runtime = "/Library/Application Support/ResidentialTunnel/gost"
            result = shell('mc_render_plist gost gost "$2" localuser', runtime)
            good = plistlib.loads(result.stdout.encode())
            for field, value in ((None, None), ("Label", "other"), ("UserName", "root"),
                                 ("WorkingDirectory", "/tmp"), ("ProgramArguments", ["/bin/sh", "-c", "true"]),
                                 ("Program", "/bin/sh"), ("KeepAlive", False)):
                data = copy.deepcopy(good)
                if field is not None:
                    data[field] = value
                # Keep the generated byte format for the canonical good case.
                file.write_bytes(result.stdout.encode() if field is None else plistlib.dumps(data))
                check = shell('mc_root_protected() { return 0; }; mc_validate_plist "$2" gost gost "$3" localuser', file, runtime)
                self.assertEqual(check.returncode == 0, field is None, check.stderr)


if __name__ == "__main__":
    unittest.main()
