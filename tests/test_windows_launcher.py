"""Static launcher regressions; no cmd.exe, PowerShell or installers are run."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLIENTS = (
    (ROOT / '01_Pure_GOST_v3/windows_client_gost_v3', 'gost_v3'),
    (ROOT / '02_FRP_GOST/windows_client_frp_gost', 'frp_gost'),
)


class WindowsLauncherTests(unittest.TestCase):
    def test_ps1_is_the_only_entry_and_no_batch_launchers_remain(self):
        for directory, suffix in CLIENTS:
            with self.subTest(directory=directory.name):
                self.assertEqual(list(directory.glob('*.bat')), [])
                for verb in ('setup', 'uninstall'):
                    self.assertTrue((directory / f'{verb}_{suffix}.ps1').is_file())
        self.assertEqual(list(ROOT.glob('*/windows_client*/**/*.bat')), [])

    def test_failure_pause_is_optional_and_forwarded_through_uac(self):
        for directory, suffix in CLIENTS:
            for verb in ('setup', 'uninstall'):
                path = directory / f'{verb}_{suffix}.ps1'
                with self.subTest(script=path.name):
                    text = path.read_text(encoding='utf-8-sig')
                    first_statement = next(line for line in text.splitlines() if line.strip() and not line.startswith('#'))
                    self.assertEqual(first_statement, 'param([switch]$PauseOnFailure)')
                    forwarding = "if ($PauseOnFailure) { $Arguments += ' -PauseOnFailure' }"
                    self.assertIn(forwarding, text)
                    self.assertLess(text.index(forwarding), text.index('-ArgumentList $Arguments -Verb RunAs'))
                    match = re.search(r'\} catch \{\n    Write-Host "(?:安装失败|卸载未完成)：', text)
                    self.assertIsNotNone(match, path.name)
                    failure = text[match.start():]
                    self.assertIn('if ($PauseOnFailure)', failure)
                    self.assertLess(failure.index("Read-Host 'Press Enter"), failure.index('exit 1'))

    def test_diagnostic_is_ascii_read_only_and_omits_source_excerpts(self):
        text = (ROOT / 'lib/windows_diagnostics.ps1').read_bytes().decode('ascii')
        self.assertIn('Language.Parser]::ParseFile', text)
        self.assertIn('Assert-ClientComponentManifest', text)
        self.assertIn('$Problem.ErrorId', text)
        for forbidden in ('Initialize-ClientComponents', 'Start-Process', 'Start-Service',
                          'Stop-Service', 'Set-Acl', 'Save-ClientAsset', 'WriteAllText',
                          '$Problem.Extent.Text'):
            self.assertNotIn(forbidden, text)


if __name__ == '__main__':
    unittest.main()
