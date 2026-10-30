"""Offline regressions. No VPS access, package installation or service mutation."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_helper", ROOT / "lib/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def bash(script, *args, env=None):
    return subprocess.run(["bash", "-c", "set -euo pipefail\n" + script, "test", *map(str, args)],
                          env=env, capture_output=True, text=True)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.metadata = self.root / "release.json"
        self.data = {"tag_name": "v3.3.2", "assets": [{
            "name": "binary.zip",
            "browser_download_url": "https://github.com/go-gost/gost/releases/download/v3.3.2/binary.zip",
            "digest": "sha256:" + "a" * 64,
        }]}

    def save(self):
        self.metadata.write_text(json.dumps(self.data))

    def test_official_asset(self):
        self.save()
        url, digest = release.release_asset(self.metadata, "go-gost/gost", "binary.zip")
        self.assertTrue(url.startswith("https://github.com/go-gost/gost/"))
        self.assertEqual(digest, "a" * 64)

    def test_bad_metadata_rejected(self):
        for change in ({"draft": True}, {"prerelease": True}, {"tag_name": "nightly"}, {"assets": []}):
            with self.subTest(change=change):
                data = self.data.copy()
                self.data.update(change)
                self.save()
                with self.assertRaises(ValueError):
                    release.release_asset(self.metadata, "go-gost/gost", "binary.zip")
                self.data = data

    def test_digest_required(self):
        for digest in (None, "", "sha256:bad", "md5:" + "a" * 32):
            with self.subTest(digest=digest):
                self.data["assets"][0]["digest"] = digest
                self.save()
                with self.assertRaises(ValueError):
                    release.release_asset(self.metadata, "go-gost/gost", "binary.zip")

    def test_foreign_download_url_rejected(self):
        self.data["assets"][0]["browser_download_url"] = "https://example.org/binary.zip"
        self.save()
        with self.assertRaises(ValueError):
            release.release_asset(self.metadata, "go-gost/gost", "binary.zip")

    def test_duplicate_asset_rejected(self):
        self.data["assets"] *= 2
        self.save()
        with self.assertRaises(ValueError):
            release.release_asset(self.metadata, "go-gost/gost", "binary.zip")

    def test_hash_verification(self):
        path = self.root / "binary"
        path.write_bytes(b"test binary")
        release.verify(path, hashlib.sha256(path.read_bytes()).hexdigest())
        with self.assertRaises(ValueError):
            release.verify(path, "0" * 64)

    def test_version_compare(self):
        for current, target, expected in (("3.3.1", "v3.3.2", "1"), ("v3.3.2", "3.3.1", "-1"),
                                          ("v1.2", "1.2.0", "0"), ("v10.7", "v10.7", "0")):
            result = subprocess.run(["python3", "-I", str(ROOT / "lib/release.py"), "compare", current, target],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)

    def test_archive_paths(self):
        for name in ("../escape", "/tmp/escape", "a/../../escape", "a\\b", "C:/escape"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                release.archive_path(self.root, name)

    def test_archive_extract(self):
        for kind in ("zip", "tar"):
            destination = self.root / kind
            destination.mkdir()
            archive = self.root / (kind + ".archive")
            if kind == "zip":
                with zipfile.ZipFile(archive, "w") as stream:
                    stream.writestr("folder/binary", b"good")
            else:
                with tarfile.open(archive, "w:gz") as stream:
                    member = tarfile.TarInfo("folder/binary")
                    member.size = 4
                    stream.addfile(member, io.BytesIO(b"good"))
            release.extract(archive, destination)
            self.assertEqual((destination / "folder/binary").read_bytes(), b"good")
            with self.assertRaises(ValueError):
                release.extract(archive, destination)

    def test_tar_links_rejected(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
            destination = self.root / kind.decode()
            destination.mkdir()
            archive = self.root / (kind.decode() + ".tar.gz")
            with tarfile.open(archive, "w:gz") as stream:
                member = tarfile.TarInfo("link")
                member.type = kind
                member.linkname = "/etc/passwd"
                stream.addfile(member)
            with self.assertRaises(ValueError):
                release.extract(archive, destination)

    def test_zip_symlink_rejected(self):
        destination = self.root / "extract"
        destination.mkdir()
        archive = self.root / "bad.zip"
        with zipfile.ZipFile(archive, "w") as stream:
            member = zipfile.ZipInfo("link")
            member.create_system = 3
            member.external_attr = 0o120777 << 16
            stream.writestr(member, "/etc/passwd")
        with self.assertRaises(ValueError):
            release.extract(archive, destination)

    def test_archive_traversal_rejected(self):
        destination = self.root / "extract"
        destination.mkdir()
        archive = self.root / "bad.zip"
        with zipfile.ZipFile(archive, "w") as stream:
            stream.writestr("../escape", "bad")
        with self.assertRaises(ValueError):
            release.extract(archive, destination)
        self.assertFalse((self.root / "escape").exists())

    def test_template_encoding_and_injection(self):
        script = self.root / "setup.ps1"
        script.write_text('$IP = "VPS_PUBLIC_IP_PLACEHOLDER"\n$User = "GOST_USER_PLACEHOLDER"\n# 中文\n', encoding="utf-8")
        release.inject(self.root, ["VPS_PUBLIC_IP=203.0.113.1", "GOST_USER=user_a"])
        self.assertTrue(script.read_bytes().startswith(b"\xef\xbb\xbf"))
        self.assertNotIn(b"_PLACEHOLDER", script.read_bytes())
        self.assertNotIn(b"\n", script.read_bytes().replace(b"\r\n", b""))
        with self.assertRaises(ValueError):
            release.inject(self.root, ["GOST_USER=bad\"user"])
        with self.assertRaises(ValueError):
            release.inject(self.root, ["VPS_PUBLIC_IP=not-an-ip"])

    def test_unresolved_template_rejected(self):
        (self.root / "setup.ps1").write_text("TOKEN_PLACEHOLDER")
        with self.assertRaises(ValueError):
            release.inject(self.root, [])


class ShellTests(unittest.TestCase):
    def test_bash_syntax(self):
        for script in (ROOT / "install.sh", ROOT / "lib/deploy.sh",
                       ROOT / "01_Pure_GOST_v3/install_vps_gost_v3.sh",
                       ROOT / "02_FRP_GOST/install_vps_frp_gost.sh"):
            result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_safe_help_from_unrelated_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(["bash", str(ROOT / "install.sh"), "--help"], cwd=directory,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for scheme in ("01_Pure_GOST_v3/install_vps_gost_v3.sh", "02_FRP_GOST/install_vps_frp_gost.sh"):
                result = subprocess.run(["bash", str(ROOT / scheme), "--help"], cwd=directory,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_supported_architecture(self):
        for source, expected in (("x86_64", "amd64"), ("aarch64", "arm64"), ("riscv64", None)):
            result = bash('source "$1"; linux_arch "$2"', ROOT / "lib/deploy.sh", source)
            if expected:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)
            else:
                self.assertNotEqual(result.returncode, 0)

    def test_shell_variable_boundaries(self):
        for script in ROOT.rglob("*.sh"):
            self.assertIsNone(re.search(r"\$[A-Za-z_][A-Za-z_0-9]*[^\x00-\x7f]", script.read_text()), str(script))

    def test_explicit_ipv4_validation(self):
        for address, valid in (("203.0.113.1", True), ("not-an-ip", False), ("::1", False)):
            env = dict(os.environ, VPS_PUBLIC_IP=address)
            result = bash('source "$1"; REPO_ROOT=$2; public_ipv4', ROOT / "lib/deploy.sh", ROOT, env=env)
            self.assertEqual(result.returncode == 0, valid, result.stderr)

    def test_upgrade_avoids_unneeded_apt_changes(self):
        result = bash('source "$1"; apt-get() { printf SHOULD_NOT_RUN; return 99; }; install_dependencies upgrade',
                      ROOT / "lib/deploy.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)

    @unittest.skipUnless(shutil.which("openssl"), "OpenSSL not installed")
    def test_certificate_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            certs = Path(directory) / "certs"
            result = bash('source "$1"; umask 077; generate_certs "$2" 127.0.0.1',
                          ROOT / "lib/deploy.sh", certs)
            self.assertEqual(result.returncode, 0, result.stderr)
            for key in certs.glob("*.key"):
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            # Leaf purposes and the IP SAN are checked by the deployment function.
            wrong_ip = subprocess.run(["openssl", "verify", "-CAfile", str(certs / "ca.crt"),
                                       "-verify_ip", "203.0.113.1", str(certs / "server.crt")], capture_output=True)
            self.assertNotEqual(wrong_ip.returncode, 0)
            wrong_purpose = subprocess.run(["openssl", "verify", "-CAfile", str(certs / "ca.crt"),
                                            "-purpose", "sslserver", str(certs / "client.crt")], capture_output=True)
            self.assertNotEqual(wrong_purpose.returncode, 0)

    def test_server_rendering(self):
        result = bash('source "$1"; render_frps_server /etc/frp token', ROOT / "lib/deploy.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("wireProtocol", result.stdout)
        self.assertIn('proxyBindAddr = "127.0.0.1"', result.stdout)
        self.assertIn('allowPorts = [{ single = 10001 }, { single = 33389 }]', result.stdout)
        self.assertIn("transport.tls.force = true", result.stdout)
        result = bash('source "$1"; render_gost_server /etc/gost relay password', ROOT / "lib/deploy.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("type: mtls", result.stdout)
        self.assertIn("bind: true", result.stdout)
        self.assertIn('caFile: "/etc/gost/certs/ca.crt"', result.stdout)

    def test_release_download_failure_propagates(self):
        # Even command substitution must not hide a failed HTTP transfer.
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / "already-valid.json"
            metadata.write_text('{"tag_name":"v3.3.2"}')
            result = bash('source "$1"; REPO_ROOT=$2; https_get() { return 22; }; '
                          'tag=$(release_info go-gost/gost latest "$3"); printf SHOULD_NOT_RUN',
                          ROOT / "lib/deploy.sh", ROOT, metadata)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("SHOULD_NOT_RUN", result.stdout)

    def test_remote_bootstrap_http_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "install.sh").write_bytes((ROOT / "install.sh").read_bytes())
            mock = root / "bin"
            mock.mkdir()
            for name, body in {"uname": "printf Linux", "id": "printf 0", "curl": "exit 22",
                               "apt-get": "exit 99"}.items():
                target = mock / name
                target.write_text("#!/bin/sh\n" + body + "\n")
                target.chmod(0o755)
            env = dict(os.environ, PATH=str(mock) + os.pathsep + os.environ["PATH"])
            env.pop("REPO_COMMIT", None)
            result = subprocess.run(["bash", str(root / "install.sh"), "gost"], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 22, result.stderr)
            self.assertNotIn("部署已", result.stdout)

    def test_no_global_network_or_http_mutation(self):
        deployment = (ROOT / "lib/deploy.sh").read_text()
        for forbidden in ("http.server", "disable_ipv6", "sysctl", "ghproxy", "bash <(curl"):
            self.assertNotIn(forbidden, deployment)
        self.assertNotIn("bash <(curl", (ROOT / "install.sh").read_text())

    @unittest.skipUnless(shutil.which("zip") and shutil.which("unzip"), "zip/unzip not installed")
    def test_offline_package_uses_templates_without_server_keys(self):
        for scheme, template in (("gost", ROOT / "01_Pure_GOST_v3/windows_client_gost_v3"),
                                 ("frp", ROOT / "02_FRP_GOST/windows_client_frp_gost")):
            with self.subTest(scheme=scheme), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                work = root / "work"
                work.mkdir()
                certs = root / "certs"
                certs.mkdir()
                for name in ("ca.crt", "client.crt", "client.key", "ca.key", "server.key"):
                    (certs / name).write_text("test fixture, not a real key")
                tag = "v3.3.2" if scheme == "gost" else "v0.71.1"
                (work / "core-release.json").write_text(json.dumps({"tag_name": tag}))
                mock = root / "bin"
                mock.mkdir()
                sevenzip = mock / "7z"
                sevenzip.write_text('''#!/bin/bash
set -euo pipefail
directory=${3#-o}
mkdir -p "$directory/runtime"
for file in servy-cli.exe Servy.exe Servy.Service.CLI.exe; do
    printf 'fixture' > "$directory/runtime/$file"
done
''')
                sevenzip.chmod(0o755)
                env = dict(os.environ, PATH=str(mock) + os.pathsep + os.environ["PATH"])
                result = bash('''
source "$1"
REPO_ROOT=$2
WORK_DIR=$3/work
SCHEME=$4
CORE_TAG=$5
PUBLIC_IP=203.0.113.1
AUTH_TOKEN=token_test
RELAY_USER=relay_test
RELAY_PASS=relay_secret
GOST_USER=user_test
GOST_PASS=socks_secret
release_info() {
    local tag=v10.7
    [ "$1" != go-gost/gost ] || tag=v3.3.2
    printf '{"tag_name":"%s"}' "$tag" > "$3"
    printf '%s\\n' "$tag"
}
download_asset() { printf fixture > "$4"; }
extract_asset() {
    mkdir "$2"
    if [[ "$1" = *frpc.zip ]]; then printf fixture > "$2/frpc.exe";
    else printf fixture > "$2/gost.exe"; fi
}
build_windows_package "$6" client.zip "$3/certs"
''', ROOT / "lib/deploy.sh", ROOT, root, scheme, tag, template, env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                with zipfile.ZipFile(work / "client.zip") as archive:
                    names = archive.namelist()
                    self.assertIn("client.key", names)
                    self.assertIn("gost.exe", names)
                    self.assertIn("servy/runtime/Servy.Service.CLI.exe", names)
                    self.assertNotIn("ca.key", names)
                    self.assertNotIn("server.key", names)
                    if scheme == "frp":
                        self.assertIn("frpc.exe", names)
                    setup_name = "setup_gost_v3.ps1" if scheme == "gost" else "setup_frp_gost.ps1"
                    setup = archive.read(setup_name).decode("utf-8-sig")
                    self.assertIn('$GostUser = "user_test"', setup)
                    self.assertIn('$GostPass = "socks_secret"', setup)
                    self.assertIn("账号：$GostUser", setup)
                    self.assertIn("密码：$GostPass", setup)
                    self.assertIn("[IO.File]::WriteAllText($SocksInfoPath,", setup)
                    # The readable credentials file is created on Windows, not by this package test.
                    self.assertNotIn("SOCKS5账号密码.txt", names)
                    for name in names:
                        if name.endswith(".ps1"):
                            self.assertTrue(archive.read(name).startswith(b"\xef\xbb\xbf"), name)
                            self.assertIsNone(re.search(rb"\b[A-Z_]+_PLACEHOLDER\b", archive.read(name)), name)

    def test_gost_upgrade_reads_version_not_go_toolchain(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "gost"
            binary.write_text('#!/bin/bash\nprintf "gost version 3.3.1 (go1.26.3 linux/amd64)\\n"\n')
            binary.chmod(0o755)
            candidate = root / "candidate"
            candidate.write_text('#!/bin/bash\nexit 0\n# new binary\n')
            candidate.chmod(0o755)
            (root / "config.yaml").write_text("services: []")
            (root / "work").mkdir()
            result = bash('''
source "$1"
REPO_ROOT=$2
BINARY=$3/gost
CORE_BINARY=$3/candidate
CONFIG=$3/config.yaml
WORK_DIR=$3/work
SCHEME=gost
SERVICE=gost
CORE_TAG=v3.3.2
UPGRADE_PENDING=0
trap cleanup_deploy EXIT
systemctl() { return 1; }
upgrade_binary
''', ROOT / "lib/deploy.sh", ROOT, root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertIn("new binary", binary.read_text())

    def test_atomic_upgrade_and_rollback(self):
        for mode in ("success", "restart-failure", "health-failure", "inactive", "invalid-config", "same", "downgrade"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                binary = root / "frps"
                candidate = root / "candidate"
                old = '#!/bin/bash\nprintf "0.71.0\\n"\n# old binary\n'
                binary.write_text(old)
                binary.chmod(0o755)
                candidate.write_text('#!/bin/bash\nif [ "$1" = verify ] && [ "$TEST_MODE" = invalid-config ]; then exit 2; fi\nprintf "0.71.1\\n"\n# new binary\n')
                candidate.chmod(0o755)
                (root / "frps.toml").write_text("# existing config\n")
                (root / "work").mkdir()
                env = dict(os.environ, TEST_MODE=mode)
                result = bash('''
source "$1"
REPO_ROOT=$2
BINARY=$3/frps
CORE_BINARY=$3/candidate
CONFIG=$3/frps.toml
WORK_DIR=$3/work
SERVICE=frps
SCHEME=frp
CORE_TAG=v0.71.1
[ "$TEST_MODE" != same ] || CORE_TAG=v0.71.0
[ "$TEST_MODE" != downgrade ] || CORE_TAG=v0.70.0
UPGRADE_PENDING=0
trap cleanup_deploy EXIT
systemctl() {
    case "$1" in
        is-active) [ "$TEST_MODE" != inactive ] ;;
        restart)
            printf restart >> "$TEST_LOG"
            if [ "$TEST_MODE" = restart-failure ] && grep -q 'new binary' "$BINARY"; then return 1; fi ;;
        *) return 1 ;;
    esac
}
# Test-only health check; do not sleep or touch the host service manager.
wait_service() { [ "$TEST_MODE" != health-failure ]; }
export TEST_LOG="$3/restarts"
upgrade_binary
''',
                              ROOT / "lib/deploy.sh", ROOT, root, env=env)
                expected_failure = mode in ("restart-failure", "health-failure", "invalid-config", "downgrade")
                self.assertEqual(result.returncode != 0, expected_failure, result.stdout + result.stderr)
                if not expected_failure:
                    self.assertEqual(result.stderr, "")
                should_replace = mode in ("success", "inactive")
                self.assertEqual("new binary" in binary.read_text(), should_replace)
                self.assertEqual((root / "frps.toml").read_text(), "# existing config\n")
                self.assertFalse(list(root.glob(".frps.*")))
                if mode in ("inactive", "same", "downgrade", "invalid-config"):
                    self.assertFalse((root / "restarts").exists())
                if mode in ("restart-failure", "health-failure"):
                    self.assertEqual((root / "restarts").read_text(), "restartrestart")


class WindowsTemplateTests(unittest.TestCase):
    def test_source_encoding_and_bat_exit_codes(self):
        ps1_files = list(ROOT.glob("*/windows_client*/*.ps1"))
        bat_files = list(ROOT.glob("*/windows_client*/*.bat"))
        self.assertEqual(len(ps1_files), 4)
        self.assertEqual(len(bat_files), 4)
        for script in ps1_files:
            self.assertTrue(script.read_bytes().startswith(b"\xef\xbb\xbf"), str(script))
        for script in bat_files:
            data = script.read_bytes()
            self.assertNotIn(b"\n", data.replace(b"\r\n", b""))
            self.assertIn(b'set "ExitCode=%ERRORLEVEL%"', data)
            self.assertIn(b"exit /b %ExitCode%", data)

    def test_pure_gost_listener_chain_and_tls(self):
        text = (ROOT / "01_Pure_GOST_v3/windows_client_gost_v3/setup_gost_v3.ps1").read_text(encoding="utf-8-sig")
        self.assertEqual(len(re.findall(r"listener:\s*\n\s+type: rtcp\s*\n\s+chain: relay-chain", text)), 2)
        self.assertIn('addr: "${VpsServerIp}:9000"', text)
        self.assertNotIn("$VpsServerIp:9000", text)
        for field in ('addr: "127.0.0.1:10001"', 'addr: "127.0.0.1:33389"', "secure: true", 'serverName: "$VpsServerIp"'):
            self.assertIn(field, text)

    def test_frpc_settings(self):
        text = (ROOT / "02_FRP_GOST/windows_client_frp_gost/setup_frp_gost.ps1").read_text(encoding="utf-8-sig")
        self.assertIn('transport.wireProtocol = "v2"', text)
        self.assertIn('transport.tls.serverName = "$VpsServerIp"', text)
        self.assertIn("transport.tcpMux = true", text)
        self.assertEqual(text.count("transport.useEncryption = false"), 2)
        self.assertEqual(text.count("transport.useCompression = false"), 2)

    def test_socks_credentials_record_uses_configured_values(self):
        scripts = list(ROOT.glob("*/windows_client*/setup_*.ps1"))
        self.assertEqual(len(scripts), 2)
        for script in scripts:
            with self.subTest(script=script.name):
                text = script.read_text(encoding="utf-8-sig")
                self.assertIn("$SocksInfoPath = Join-Path $ToolsDir 'SOCKS5账号密码.txt'", text)
                match = re.search(r'\$SocksInfo = @"\n(.*?)\n"@', text, re.DOTALL)
                self.assertIsNotNone(match)
                record = match.group(1)
                self.assertIn("账号：$GostUser", record)
                self.assertIn("密码：$GostPass", record)
                self.assertEqual(re.findall(r"\$[A-Za-z_]\w*", record),
                                 ["$VpsServerIp", "$GostUser", "$GostPass"])
                for value in ("127.0.0.1:10000", "127.0.0.1:10001", "不对公网开放", "明文密码"):
                    self.assertIn(value, record)
                self.assertIn("$GostUserYaml = ConvertTo-Json -InputObject $GostUser -Compress", text)
                self.assertIn("$GostPassYaml = ConvertTo-Json -InputObject $GostPass -Compress", text)
                write_call = ('[IO.File]::WriteAllText($SocksInfoPath, '
                              '($SocksInfo -replace \'\\r?\\n\', "`r`n"), (New-Object Text.UTF8Encoding($true)))')
                self.assertEqual(text.count(write_call), 1)
                self.assertLess(text.index('[IO.File]::WriteAllText("$ToolsDir\\gost.yaml"'),
                                text.index(write_call))
                self.assertLess(text.index(write_call), text.index("Write-Host '[4/5]"))
                self.assertIn('Write-Host "SOCKS5 账号密码已保存：$SocksInfoPath', text)
                self.assertIn("$ErrorActionPreference = 'Stop'", text)

    def test_socks_credentials_location_and_uninstall_warning(self):
        for directory, tools_dir in (("01_Pure_GOST_v3/windows_client_gost_v3", r"C:\Tools\TikTokGostV3"),
                                     ("02_FRP_GOST/windows_client_frp_gost", r"C:\Tools\TikTokFrpGost")):
            with self.subTest(directory=directory):
                client = ROOT / directory
                instructions = (client / "README_住宅机安装说明.txt").read_text()
                self.assertIn(tools_dir + r"\SOCKS5账号密码.txt", instructions)
                self.assertIn("卸载默认保留整个运行目录", instructions)
                uninstall = next(client.glob("uninstall_*.ps1")).read_text(encoding="utf-8-sig")
                prompt = next(line for line in uninstall.splitlines() if "$Confirm = Read-Host" in line)
                self.assertIn("SOCKS5账号密码.txt", prompt)
                self.assertIn("请先备份所需凭据", prompt)
                self.assertIn("(y/N)", prompt)
                self.assertIn("if ($Confirm -ieq 'y')", uninstall)

    def test_windows_safety_guards(self):
        for script in ROOT.glob("*/windows_client*/*.ps1"):
            text = script.read_text(encoding="utf-8-sig")
            for forbidden in ("Add-MpPreference", "Stop-Process", "Invoke-WebRequest", "$P_HS://"):
                self.assertNotIn(forbidden, text, str(script))
            self.assertIn("-Verb RunAs -Wait -PassThru", text)
            self.assertIn("exit $Child.ExitCode", text)
            self.assertIn("Assert-OwnedService", text)
            if script.name.startswith("setup_"):
                self.assertIn("--enableHealth", text)
                self.assertLess(text.index("Stop-Service"), text.index("Copy-Item"))
                self.assertLess(text.index("PLACEHOLDER'"), text.index("-Verb RunAs"))


if __name__ == "__main__":
    unittest.main()
