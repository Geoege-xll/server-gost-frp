"""Offline source contracts and ACE-mask policy fixtures; never runs PowerShell.

These tests do not emulate NTFS, token group expansion or Windows AccessCheck.
Actual DACL persistence/UAC/service execution still needs authorized Windows testing.
"""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = (ROOT / "lib/windows_components.ps1").read_text(encoding="utf-8-sig")
SETUPS = (
    ROOT / "01_Pure_GOST_v3/windows_client_gost_v3/setup_gost_v3.ps1",
    ROOT / "02_FRP_GOST/windows_client_frp_gost/setup_frp_gost.ps1",
)


def body(name):
    match = re.search(r"(?ms)^function " + re.escape(name) + r"(?:\(|\s).*?(?=^function |\Z)", HELPER)
    if match is None:
        raise AssertionError("Missing helper: " + name)
    return match.group()


# FileSystemRights constants used by the production mask. The fixture extracts
# the selected names from source, so removing a protected right fails the cases.
RIGHTS = {
    "WriteData": 0x2,
    "AppendData": 0x4,
    "WriteExtendedAttributes": 0x10,
    "DeleteSubdirectoriesAndFiles": 0x40,
    "WriteAttributes": 0x100,
    "Delete": 0x10000,
    "ChangePermissions": 0x40000,
    "TakeOwnership": 0x80000,
}


def selected_risk(ancestor):
    source = body("Assert-ClientRuntimeAcl")
    selection = source.split("$Risk = [long](", 1)[1].split(")", 1)[0]
    names = re.findall(r"FileSystemRights\]::(\w+)", selection)
    risk = 0
    for name in names:
        risk |= RIGHTS[name]
    extra = re.search(r"\$Risk = \$Risk -bor (0x[0-9a-fA-F]+) -bor (0x[0-9a-fA-F]+)", source)
    if extra is None:
        raise AssertionError("Generic access mask guards missing")
    risk |= int(extra[1], 16) | int(extra[2], 16)
    if not ancestor:
        if "if (!$Ancestor) { $Risk = $Risk -bor [long][Security.AccessControl.FileSystemRights]::AppendData }" in source:
            risk |= RIGHTS["AppendData"]
    return risk


class WindowsPermissionPolicyTests(unittest.TestCase):
    def test_read_execute_and_synchronize_are_not_mutation(self):
        for ancestor in (False, True):
            self.assertEqual(selected_risk(ancestor) & 0x1200A9, 0)
            self.assertEqual(selected_risk(ancestor) & 0x80000000, 0)  # GENERIC_READ

    def test_untrusted_write_delete_and_acl_changes_are_rejected(self):
        for name, right in RIGHTS.items():
            for ancestor in (False, True):
                if ancestor and name == "AppendData":
                    continue
                with self.subTest(name=name, ancestor=ancestor):
                    self.assertNotEqual(selected_risk(ancestor) & right, 0)

    def test_default_drive_root_create_directory_is_not_delete_child(self):
        self.assertEqual(selected_risk(True) & RIGHTS["AppendData"], 0)
        self.assertNotEqual(selected_risk(False) & RIGHTS["AppendData"], 0)
        self.assertNotEqual(selected_risk(True) & RIGHTS["DeleteSubdirectoriesAndFiles"], 0)

    def test_generic_write_and_full_access_are_rejected(self):
        for ancestor in (False, True):
            for mask in (0x10000000, 0x40000000, 0x1F01FF):
                with self.subTest(ancestor=ancestor, mask=mask):
                    self.assertNotEqual(selected_risk(ancestor) & mask, 0)

    def test_fail_closed_owner_null_acl_and_unsupported_aces(self):
        source = body("Assert-ClientRuntimeAcl")
        for required in (
            "$Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value",
            "$Trusted -cnotcontains",
            "$null -eq $Descriptor.DiscretionaryAcl",
            "!$Acl.AreAccessRulesCanonical",
            "$Ace -isnot [Security.AccessControl.CommonAce]",
            "[Security.AccessControl.AceType]::AccessAllowed",
            "[Security.AccessControl.AceType]::AccessDenied",
            "[Security.AccessControl.AceFlags]::InheritOnly",
            "$Trusted -cnotcontains $Ace.SecurityIdentifier.Value",
        ):
            self.assertIn(required, source)
        # No group-name/locale lookups or deny-ACE cancellation that could turn an
        # uncertain broad allow into a supposedly safe writable path.
        self.assertNotIn("NTAccount", source)
        self.assertNotIn("Get-LocalGroupMember", source)
        self.assertNotIn("$Risk = $Risk -band", source)

    def test_unexpected_lookup_errors_are_not_treated_as_missing_paths(self):
        source = body("Get-ClientRuntimeItem")
        self.assertIn("-Force -ErrorAction Stop", source)
        self.assertIn("catch [System.Management.Automation.ItemNotFoundException]", source)
        self.assertEqual(source.count("catch"), 1)
        self.assertNotIn("SilentlyContinue", source)


class WindowsPrivateRuntimeContractTests(unittest.TestCase):
    def test_private_acl_is_protected_and_only_grants_three_trusted_principals(self):
        source = body("New-ClientPrivateAcl")
        for required in (
            "Security.AccessControl.DirectorySecurity",
            "Security.AccessControl.FileSecurity",
            "$Acl.SetAccessRuleProtection($true, $false)",
            "$Acl.SetOwner($User)",
            "[Security.Principal.WindowsIdentity]::GetCurrent().User",
            "[Security.AccessControl.InheritanceFlags]::ContainerInherit",
            "[Security.AccessControl.InheritanceFlags]::ObjectInherit",
            "[Security.AccessControl.FileSystemRights]::FullControl",
            "[Security.AccessControl.AccessControlType]::Allow",
        ):
            self.assertIn(required, source)
        self.assertEqual(re.findall(r"'S-[0-9-]+'", source), ["'S-1-5-32-544'", "'S-1-5-18'"])
        self.assertNotIn("InheritOnly", source)

    def test_read_only_preflight_checks_ancestors_and_entire_existing_tree(self):
        source = body("Assert-ClientRuntimePath")
        for required in (
            "[IO.Directory]::GetParent($Full).FullName -ine 'C:\\Tools'",
            "$Parent = $Parent.Parent",
            "Assert-ClientRuntimeAcl $Path -Ancestor",
            "Assert-ClientRuntimeAcl $Full",
            "Get-ClientPlainTree $Full | ForEach-Object { Assert-ClientRuntimeAcl $_.FullName }",
        ):
            self.assertIn(required, source)
        self.assertIn("Assert-ClientPlainPath $Path", body("Assert-ClientRuntimeAcl"))
        for name in ("Assert-ClientRuntimePath", "Assert-ClientRuntimeAcl", "Get-ClientRuntimeItem"):
            for forbidden in ("SetAccessControl", "Set-Acl", "SetOwner", "CreateDirectory", "Remove-Item", "takeown", "icacls"):
                self.assertNotIn(forbidden, body(name))

    def test_existing_shared_tools_acl_is_never_changed(self):
        source = body("Initialize-ClientRuntimeDirectory")
        self.assertIn("if ($null -eq (Get-ClientRuntimeItem $Shared))", source)
        self.assertIn("{ New-ClientPrivateDirectory $Shared }", source)
        self.assertNotIn("SetAccessControl", source)
        self.assertNotIn("Set-ClientRuntimePrivateAcl $Shared", source)
        self.assertIn("$Items = @((Get-ClientRuntimeItem $Root)) + @(Get-ClientPlainTree $Root)", source)
        self.assertIn("foreach ($Item in $Items) { Set-ClientRuntimePrivateAcl $Item }", source)
        # No recursive OS ACL takeover/repair of ancestors anywhere in the helper.
        for forbidden in ("takeown", "icacls", "Set-Acl"):
            self.assertNotIn(forbidden, HELPER)

    def test_creation_has_private_dacl_and_post_creation_rechecks(self):
        source = body("Initialize-ClientRuntimeDirectory")
        initial_check = source.index("Assert-ClientRuntimePath $Root")
        shared_create = source.index("New-ClientPrivateDirectory $Shared")
        runtime_create = source.index("New-ClientPrivateDirectory $Root")
        protect = source.index("Set-ClientRuntimePrivateAcl $Item")
        self.assertLess(initial_check, shared_create)
        self.assertIn("Assert-ClientRuntimePath $Root", source[shared_create:runtime_create])
        self.assertIn("Assert-ClientRuntimePath $Root", source[runtime_create:protect])
        subdirectory = body("New-ClientRuntimeSubdirectory")
        self.assertIn("[ValidateSet('certs', 'logs', 'servy')]", subdirectory)
        self.assertIn("New-ClientPrivateDirectory $Path", subdirectory)
        self.assertIn("Set-ClientRuntimePrivateAcl $Item", subdirectory)

    def test_hardening_revalidates_before_write_and_checks_persisted_acl(self):
        source = body("Set-ClientRuntimePrivateAcl")
        self.assertLess(source.index("Assert-ClientRuntimeAcl $Item.FullName"), source.index("FileSystemAclExtensions]::SetAccessControl($Item, $Acl)"))
        self.assertLess(source.index("FileSystemAclExtensions]::SetAccessControl($Item, $Acl)"), source.index("$Written = Get-Acl"))
        for required in (
            "$Written.AreAccessRulesProtected",
            "$Written.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $User",
            "$Written.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])",
            "$Trusted -cnotcontains $Rule.IdentityReference.Value",
            "$Rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl",
            "$Rule.InheritanceFlags",
            "$Rule.PropagationFlags",
            "$Seen.Contains($Sid)",
        ):
            self.assertIn(required, source)

    def test_both_setups_fail_before_download_and_protect_before_stop_or_copy(self):
        for script in SETUPS:
            with self.subTest(script=script.name):
                source = script.read_text(encoding="utf-8-sig")
                elevation = source.index("-Verb RunAs -Wait -PassThru")
                preflight = source.index("Assert-ClientRuntimePath -Root $ToolsDir")
                download = source.index("Initialize-ClientComponents -PackageDir")
                ownership = source.rindex("Assert-OwnedService")
                protect = source.index("Initialize-ClientRuntimeDirectory -Root $ToolsDir")
                stop = source.index("Stop-Service")
                copy = source.index("Copy-Item")
                private_servy = source.index("New-ClientRuntimeSubdirectory -Root $ToolsDir -Name 'servy'")
                self.assertLess(elevation, preflight)
                self.assertLess(preflight, download)
                self.assertLess(download, ownership)
                self.assertLess(ownership, protect)
                self.assertLess(protect, stop)
                self.assertLess(stop, private_servy)
                self.assertLess(private_servy, copy)
                self.assertLess(protect, source.index('[IO.File]::WriteAllText("$ToolsDir\\gost.yaml"'))
                self.assertNotIn("New-Item -Path $ToolsDir", source)

    def test_pause_uac_and_official_runtime_paths_remain_unchanged(self):
        for script, directory in zip(SETUPS, ("TikTokGostV3", "TikTokFrpGost")):
            with self.subTest(script=script.name):
                source = script.read_text(encoding="utf-8-sig")
                self.assertIn("param([switch]$PauseOnFailure)", source)
                self.assertIn("if ($PauseOnFailure) { $Arguments += ' -PauseOnFailure' }", source)
                self.assertIn("-ArgumentList $Arguments -Verb RunAs -Wait -PassThru", source)
                self.assertIn("Read-Host 'Press Enter after reading the error above'", source)
                self.assertIn("$ToolsDir = 'C:\\Tools\\" + directory + "'", source)
                # TLS paths derive from the runtime directory so isolated builds cannot
                # leave stale literal paths behind.
                self.assertIn("$CertsPath = $CertsDir.Replace('\\', '/')", source)
                self.assertIn('keyFile: "$CertsPath/client.key"' if directory == "TikTokGostV3"
                              else 'transport.tls.keyFile = "$CertsPath/client.key"', source)

    def test_private_directory_creation_reuses_acl_and_no_external_acl_tools_are_added(self):
        # New-ClientRuntimeSubdirectory is the surviving creation path (certs/logs/servy);
        # the component staging machinery was removed with online mode.
        subdirectory = body("New-ClientRuntimeSubdirectory")
        self.assertIn("New-ClientPrivateDirectory $Path", subdirectory)
        self.assertNotIn("CreateDirectory", subdirectory)
        permissions = HELPER[HELPER.index("function New-ClientPrivateAcl("):HELPER.index("function Get-ClientRuntimeItem(")]
        for forbidden in ("Start-Process", "Invoke-Expression", "Add-Type", "Invoke-WebRequest", "Stop-Service", "Copy-Item"):
            self.assertNotIn(forbidden, permissions)
        self.assertNotIn("??", permissions)
        self.assertNotIn("ForEach-Object -Parallel", permissions)

    def test_ps7_static_acl_calls_use_the_documented_system_io_type(self):
        # Official docs: the static class is System.IO.FileSystemAclExtensions
        # (System.IO namespace) in the System.IO.FileSystem.AccessControl assembly,
        # netcore-1.0..net-11.0 only. A System.Security.AccessControl literal never
        # resolves in any .NET version, and that Add-Type loads the wrong assembly.
        self.assertIn("Add-Type -AssemblyName System.IO.FileSystem.AccessControl", HELPER)
        self.assertIn("[IO.FileSystemAclExtensions]::SetAccessControl($Item, $Acl)", HELPER)
        self.assertIn("[IO.FileSystemAclExtensions]::SetAccessControl($Item, (New-ClientPrivateAcl $true))", HELPER)
        self.assertNotIn("[Security.AccessControl.FileSystemAclExtensions]", HELPER)
        self.assertNotIn("Add-Type -AssemblyName System.Security.AccessControl", HELPER)


if __name__ == "__main__":
    unittest.main()
