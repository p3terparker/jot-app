#!/usr/bin/env python3
"""Exercise build, signing and release tooling without touching user apps, notes or keychains."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import jot_build

ROOT = jot_build.ROOT
DEVELOPER_ID = 'Developer ID Application: Example (ABCDE12345)'
CERTIFICATE_HASH = 'ABCDEF0123456789ABCDEF0123456789ABCDEF01'


class ReplacementSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        # /var can itself be a system symlink on macOS.
        self.root = Path(self.temporary.name).resolve()
        self.destination = self.root / 'Example.app'
        self.destination.mkdir()
        (self.destination / 'old').write_text('old app')
        self.staged = self.root / 'staged.app'
        self.staged.mkdir()
        (self.staged / 'new').write_text('new app')

    def tearDown(self):
        self.temporary.cleanup()

    def test_success_replaces_only_selected_bundle(self):
        unrelated = self.root / 'Other.app'
        unrelated.mkdir()
        jot_build.publish_directory(self.staged, self.destination)
        self.assertEqual((self.destination / 'new').read_text(), 'new app')
        self.assertTrue(unrelated.is_dir())
        self.assertFalse(self.destination.with_name('Example.app.previous').exists())

    def test_failed_publication_restores_previous_bundle(self):
        original_rename = Path.rename
        staged = self.staged

        def fail_staged(path, target):
            if path == staged:
                raise OSError('simulated filesystem failure')
            return original_rename(path, target)

        with patch.object(Path, 'rename', fail_staged):
            with self.assertRaises(OSError):
                jot_build.publish_directory(self.staged, self.destination)
        self.assertEqual((self.destination / 'old').read_text(), 'old app')
        self.assertTrue(self.staged.exists())

    def test_symlink_cannot_replace_an_unrelated_directory(self):
        link = self.root / 'Linked.app'
        link.symlink_to(self.destination)
        with self.assertRaises(ValueError):
            jot_build.publish_directory(self.staged, link)
        self.assertEqual((self.destination / 'old').read_text(), 'old app')
        self.assertTrue(link.is_symlink())

    def test_previous_backup_requires_inspection(self):
        backup = self.destination.with_name('Example.app.previous')
        backup.mkdir()
        with self.assertRaises(ValueError):
            jot_build.publish_directory(self.staged, self.destination)
        self.assertEqual((self.destination / 'old').read_text(), 'old app')
        self.assertTrue(backup.is_dir())

    def test_output_symlink_is_rejected_before_creation(self):
        link = self.root / 'build'
        link.symlink_to(self.destination)
        with self.assertRaises(ValueError):
            jot_build.output_directory(link / 'native')
        self.assertFalse((self.destination / 'native').exists())


class MetadataTests(unittest.TestCase):
    def config(self):
        return json.loads(jot_build.CONFIG.read_text())

    def test_wrong_app_metadata_is_rejected(self):
        config = self.config()
        config['name'] = 'Other'
        with self.assertRaisesRegex(ValueError, 'metadata'):
            jot_build.metadata(config)

    def test_manifest_and_bundle_agree(self):
        config = self.config()
        _, info = jot_build.metadata(config)
        self.assertEqual(info['CFBundleIdentifier'], 'com.jacob.jot')   # existing installs and preferences depend on it
        self.assertEqual(info['LSMinimumSystemVersion'], config['minimum_macos'])
        self.assertTrue(info['LSUIElement'])

    def test_minimum_macos_mismatch_is_rejected(self):
        config = self.config()
        config['minimum_macos'] = '99.0'
        with self.assertRaisesRegex(ValueError, 'Minimum macOS'):
            jot_build.metadata(config)

    def test_duplicate_frameworks_are_rejected(self):
        config = self.config()
        config['frameworks'] = ['Cocoa', 'Cocoa']
        with self.assertRaisesRegex(ValueError, 'framework'):
            jot_build.metadata(config)

    def test_entitlements_must_stay_inside_the_repository(self):
        config = self.config()
        config['entitlements'] = '../outside.entitlements'
        with self.assertRaisesRegex(ValueError, 'Entitlements'):
            jot_build.metadata(config)

    def test_jot_declares_only_the_apple_events_entitlement(self):
        config = self.config()
        self.assertEqual(config['entitlements'], 'Jot.entitlements')
        entitlements = plistlib.loads((ROOT / 'Jot.entitlements').read_bytes())
        self.assertEqual(entitlements, {'com.apple.security.automation.apple-events': True})

    def test_sources_pass_the_repository_check(self):
        jot_build.check_sources(self.config())


class SigningTests(unittest.TestCase):
    config = {'name': 'Jot', 'entitlements': 'Jot.entitlements'}

    def test_identity_precedence(self):
        with patch.dict(os.environ, {jot_build.LOCAL_IDENTITY_VARIABLE: 'From Environment'}):
            self.assertEqual(jot_build.signing_identity('From Flag'), 'From Flag')
            self.assertEqual(jot_build.signing_identity(None), 'From Environment')
        with patch.dict(os.environ):
            os.environ.pop(jot_build.LOCAL_IDENTITY_VARIABLE, None)
            self.assertEqual(jot_build.signing_identity(None), '-')

    def test_local_signing_is_plain(self):
        self.assertEqual(jot_build.codesign_command(self.config, '-', '/x/Jot.app'),
                         ['codesign', '--force', '--sign', '-', '/x/Jot.app'])
        self.assertEqual(jot_build.codesign_command(self.config, CERTIFICATE_HASH, '/x/Jot.app'),
                         ['codesign', '--force', '--sign', CERTIFICATE_HASH, '/x/Jot.app'])

    def test_developer_id_gets_runtime_timestamp_and_entitlements(self):
        command = jot_build.codesign_command(self.config, DEVELOPER_ID, '/x/Jot.app')
        self.assertEqual(command, ['codesign', '--force', '--sign', DEVELOPER_ID, '--options', 'runtime', '--timestamp',
                                   '--entitlements', str(ROOT / 'Jot.entitlements'), '/x/Jot.app'])

    def test_hardened_flag_covers_a_certificate_hash(self):
        command = jot_build.codesign_command(self.config, CERTIFICATE_HASH, '/x/Jot.app', hardened=True)
        self.assertIn('runtime', command)
        self.assertIn('--timestamp', command)
        self.assertIn('--entitlements', command)

    def test_hardened_ad_hoc_smoke_build_needs_no_timestamp_server(self):
        command = jot_build.codesign_command(self.config, '-', '/x/Jot.app', hardened=True)
        self.assertIn('runtime', command)
        self.assertIn('--entitlements', command)
        self.assertNotIn('--timestamp', command)

    def test_an_app_without_entitlements_gets_none(self):
        command = jot_build.codesign_command({'name': 'Jot'}, DEVELOPER_ID, '/x/Jot.app')
        self.assertIn('runtime', command)
        self.assertNotIn('--entitlements', command)


class ReleaseToolingTests(unittest.TestCase):
    def test_release_steps_run_in_the_safe_order(self):
        steps = jot_build.release_commands('Jot', Path('/b/Jot.app'), Path('/d/Jot.zip'), Path('/d/Jot.dmg'), DEVELOPER_ID, 'PROFILE')
        names = [description for description, _ in steps]
        self.assertEqual(names, ['zip the app for upload', 'notarize the app', 'staple the app', 'sign the disk image',
                                 'notarize the disk image', 'staple the disk image', 'validate the stapled disk image',
                                 'assess the disk image with Gatekeeper'])
        # The app is stapled before the image exists; the image is signed before it is notarized.
        self.assertLess(names.index('staple the app'), names.index('sign the disk image'))
        self.assertLess(names.index('sign the disk image'), names.index('notarize the disk image'))
        self.assertTrue(all('PROFILE' in command for description, command in steps if 'notarize' in description))

    def test_release_needs_a_developer_id_and_a_profile(self):
        with self.assertRaises(ValueError): jot_build.require_release_inputs(None, 'P')
        with self.assertRaises(ValueError): jot_build.require_release_inputs('-', 'P')
        with self.assertRaises(ValueError): jot_build.require_release_inputs('My Local Certificate', 'P')
        with self.assertRaises(ValueError): jot_build.require_release_inputs(DEVELOPER_ID, None)
        jot_build.require_release_inputs(DEVELOPER_ID, 'P')


class CommandLineTests(unittest.TestCase):
    """Run the real command line with arguments that must be refused or must run nothing."""

    def run_tool(self, *arguments):
        environment = {key: value for key, value in os.environ.items() if key != jot_build.LOCAL_IDENTITY_VARIABLE}
        return subprocess.run([sys.executable, str(ROOT / 'scripts/jot_build.py'), *arguments],
                              text=True, capture_output=True, env=environment)

    def listing(self):
        found = set()
        for name in ('build', 'dist'):
            base = ROOT / name
            if base.exists():
                found.update(str(path) for path in base.rglob('*'))
        return found

    def test_incompatible_options_are_refused(self):
        for arguments in (('check', '--install'), ('package', '--install'), ('build', '--built'), ('build', '--release'),
                          ('check', '--identity', '-'), ('check', '--hardened'), ('build', '--dry-run'), ('package', '--notary-profile', 'P')):
            result = self.run_tool(*arguments)
            self.assertEqual(result.returncode, 2, arguments)

    def test_release_without_credentials_stops_before_building(self):
        before = self.listing()
        result = self.run_tool('release')
        self.assertEqual(result.returncode, 1)
        self.assertIn('Developer ID', result.stderr)
        self.assertEqual(self.listing(), before)
        result = self.run_tool('release', '--identity', DEVELOPER_ID)
        self.assertEqual(result.returncode, 1)
        self.assertIn('notary-profile', result.stderr)

    def test_dry_run_prints_every_step_and_runs_none(self):
        before = self.listing()
        result = self.run_tool('release', '--identity', DEVELOPER_ID, '--notary-profile', 'PROFILE', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        for step in ('notarize the app', 'staple the app', 'sign the disk image', 'notarize the disk image', 'staple the disk image'):
            self.assertIn('[dry run] ' + step, result.stdout)
        self.assertIn('--keychain-profile PROFILE', result.stdout)
        self.assertEqual(self.listing(), before)


class RepositoryHygieneTests(unittest.TestCase):
    """The repository must stand alone: no developer paths, no sibling checkouts, no secrets-shaped files."""

    skipped_directories = {'.git', 'build', 'dist', '__pycache__'}
    text_suffixes = {'.swift', '.py', '.sh', '.md', '.json', '.plist', '.entitlements', '.txt'}

    def files(self):
        for directory, names, files in os.walk(ROOT):
            names[:] = [name for name in names if name not in self.skipped_directories]
            for name in files:
                path = Path(directory) / name
                if path.suffix in self.text_suffixes or name in ('LICENSE', '.gitignore'):
                    yield path

    def test_no_absolute_developer_paths_or_sibling_checkouts(self):
        forbidden = ('/Users/', '~/GlassKit', 'glasskit archive', 'MenuBarAppsShare')
        hits = []
        for path in self.files():
            if path.name == 'test_tooling.py':
                continue
            text = path.read_text(errors='replace')
            hits += ['{}: {}'.format(path.relative_to(ROOT), item) for item in forbidden if item in text]
        self.assertEqual(hits, [])

    def test_no_credential_files_are_present(self):
        names = [path.name for path in self.files()]
        self.assertFalse([name for name in names if name.startswith('.env') or name.endswith(('.p12', '.p8', '.mobileprovision'))])

    def test_license_is_mit_and_names_the_owner(self):
        text = (ROOT / 'LICENSE').read_text()
        self.assertTrue(text.startswith('MIT License'))
        self.assertIn('Copyright (c) 2026 Jacob Couture', text)


if __name__ == '__main__':
    unittest.main()
