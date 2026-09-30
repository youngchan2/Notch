import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('remote', Path(__file__).resolve().parents[1] / 'Resources/remote-claude.py')
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)


class RemoteTests(unittest.TestCase):
    def test_configuration_matches_login_environment_then_tmux(self):
        with patch.dict(os.environ, {'CLAUDE_CONFIG_DIR': '/home/test/active'}, clear=True), \
             patch.object(remote.subprocess, 'check_output') as tmux:
            self.assertEqual(remote.config_directory(), Path('/home/test/active'))
            tmux.assert_not_called()
        with patch.dict(os.environ, {}, clear=True), \
             patch.object(remote.subprocess, 'check_output', return_value='CLAUDE_CONFIG_DIR=/home/test/tmux\n'):
            self.assertEqual(remote.config_directory(), Path('/home/test/tmux'))
        with patch.dict(os.environ, {}, clear=True), \
             patch.object(remote.subprocess, 'check_output', side_effect=FileNotFoundError), \
             patch.object(remote.Path, 'home', return_value=Path('/home/test')):
            self.assertEqual(remote.config_directory(), Path('/home/test/.claude'))

    def test_install_preserves_dotfile_link_and_other_settings(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder).resolve()
            config = home / '.config/claude'
            config.mkdir(parents=True)
            target = home / 'dotfiles/claude/settings.json'
            target.parent.mkdir(parents=True)
            original = {'permissions': {'allow': ['Read']}, 'statusLine': {'command': 'keep'},
                        'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'existing'}]}]}}
            before = json.dumps(original).encode()
            target.write_bytes(before)
            target.chmod(0o640)
            link = config / 'settings.json'
            link.symlink_to(target)
            legacy = home / '.claude/settings.json'
            legacy.parent.mkdir()
            legacy.write_text('{"model":"legacy"}')
            with patch.object(remote.Path, 'home', return_value=home), \
                 patch.dict(os.environ, {'CLAUDE_CONFIG_DIR': str(config)}), \
                 patch.object(remote, 'ROOT', home / 'notchwave'), \
                 patch('sys.stdout', new=io.StringIO()):
                remote.install()
                installed = json.loads(target.read_text())
                self.assertTrue(remote.hooks_ready(link))
                self.assertEqual(installed['permissions'], original['permissions'])
                self.assertEqual(installed['statusLine'], original['statusLine'])
                self.assertTrue(link.is_symlink())
                self.assertEqual(link.resolve(), target)
                self.assertEqual(target.stat().st_mode & 0o777, 0o640)
                for event in remote.EVENTS:
                    self.assertTrue(any(remote.MARKER in h.get('command', '')
                        for g in installed['hooks'][event] for h in g['hooks']))
                remote.install()
                self.assertEqual(json.loads(target.read_text()), installed)
                remote.install(False)
                self.assertFalse(remote.hooks_ready(link))
                self.assertEqual(json.loads(target.read_text()), original)
                self.assertTrue(link.is_symlink())
                self.assertEqual(legacy.read_text(), '{"model":"legacy"}')
                backups = list((remote.ROOT / 'settings-backups').glob('*.json'))
                self.assertEqual(len(backups), 1)
                self.assertEqual(backups[0].read_bytes(), before)
                self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)

    def test_settings_link_outside_home_is_not_written(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            home = root / 'home'
            home.mkdir()
            outside = root / 'outside.json'
            outside.write_text('{}')
            settings = home / 'settings.json'
            settings.symlink_to(outside)
            with patch.object(remote.Path, 'home', return_value=home):
                with self.assertRaises(ValueError):
                    remote.settings_target(settings)
            self.assertEqual(outside.read_text(), '{}')

    def test_retargeted_link_aborts_install(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder).resolve()
            config = home / 'config'
            config.mkdir()
            target = home / 'first.json'
            target.write_text('{}')
            other = home / 'second.json'
            other.write_text('{"model":"keep"}')
            settings = config / 'settings.json'
            settings.symlink_to(target)
            actual_update = remote.updated_settings
            def relink(*args):
                settings.unlink()
                settings.symlink_to(other)
                return actual_update(*args)
            with patch.object(remote.Path, 'home', return_value=home), \
                 patch.dict(os.environ, {'CLAUDE_CONFIG_DIR': str(config)}), \
                 patch.object(remote, 'ROOT', home / 'notchwave'), \
                 patch.object(remote, 'updated_settings', side_effect=relink):
                with self.assertRaisesRegex(ValueError, 'changed during setup'):
                    remote.install()
            self.assertEqual(target.read_text(), '{}')
            self.assertEqual(other.read_text(), '{"model":"keep"}')

    def test_health_check_rejects_disabled_missing_and_malformed_hooks(self):
        with tempfile.TemporaryDirectory() as folder:
            settings = Path(folder) / 'settings.json'
            self.assertFalse(remote.hooks_ready(settings))
            for invalid in ('{', '[]', '{"hooks":null}', '{"hooks":{"Stop":[null]}}'):
                settings.write_text(invalid)
                self.assertFalse(remote.hooks_ready(settings))
            value = remote.updated_settings({}, '/python /home/test/remote-claude.py' + remote.MARKER, True)
            value['disableAllHooks'] = True
            settings.write_text(json.dumps(value))
            self.assertFalse(remote.hooks_ready(settings))

    def test_settings_preserved_and_idempotent(self):
        original = {'permissions': {'allow': ['Read']}, 'statusLine': {'command': 'my-status'},
                    'hooks': {'Stop': [{'matcher': '*', 'hooks': [{'type': 'command', 'command': 'existing'}]}]}}
        command = '/python /home/test/remote-claude.py' + remote.MARKER
        installed = remote.updated_settings(original, command, True)
        self.assertEqual(remote.updated_settings(installed, command, True), installed)
        self.assertEqual(remote.updated_settings(installed, command, False), original)
        self.assertEqual(installed['statusLine'], original['statusLine'])
        self.assertEqual(installed['permissions'], original['permissions'])

    def test_invalid_settings_rejected(self):
        for value in ([], {'hooks': None}, {'hooks': {'Stop': 'bad'}}, {'hooks': {'Stop': [{}]}}):
            with self.assertRaises((ValueError, TypeError)):
                remote.updated_settings(value, 'anything', True)

    def test_payload_minimized(self):
        event = remote.normalize({'hook_event_name': 'Stop', 'session_id': 'session',
            'cwd': '/private/path/한글', 'last_assistant_message': 'SECRET',
            'transcript_path': '/private/record', 'tool_input': {'command': 'PRIVATE'}}, now=100)
        serialized = json.dumps(event)
        for value in ('SECRET', 'PRIVATE', 'private', 'transcript', 'tool_input'):
            self.assertNotIn(value, serialized)
        self.assertEqual(event['project'], '한글')
        self.assertEqual(len(event['key']), 64)
        self.assertIsNone(remote.normalize({'hook_event_name': 'Stop', 'session_id': ''}))
        self.assertIsNone(remote.normalize({'hook_event_name': 'Notification', 'session_id': 's', 'notification_type': 'idle_prompt'}))

    def test_permissions_and_resume_capture(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(remote, 'tmux_target', return_value=None):
            with patch.object(remote, 'ROOT', Path(folder).resolve() / 'notchwave'):
                def capture(kind, tool='', extra=None):
                    payload = dict(hook_event_name=kind, session_id='s', cwd='/project', tool_name=tool)
                    payload.update(extra or {})
                    stream = io.TextIOWrapper(io.BytesIO(json.dumps(payload).encode()))
                    with patch.object(remote.sys, 'stdin', stream):
                        remote.capture()
                    files = list((remote.ROOT / 'events').glob('*.json'))
                    return remote.read_event(files[0]) if files else None
                permission = capture('PermissionRequest', 'Bash')
                self.assertEqual(capture('Notification', extra={'notification_type': 'permission_prompt'}), permission)
                self.assertEqual(capture('PostToolUse', 'Read'), permission)
                self.assertEqual(capture('PostToolUse', 'Bash')['hook'], 'PostToolUse')
                completed = capture('Stop')
                self.assertEqual(capture('PostToolUse', 'Bash'), completed)
                self.assertEqual(capture('UserPromptSubmit')['hook'], 'UserPromptSubmit')
                self.assertEqual(len(list((remote.ROOT / 'events').glob('*.json'))), 1)

    def test_symlink_write_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            original = root / 'original'
            original.write_text('keep')
            link = root / 'link'
            link.symlink_to(original)
            with self.assertRaises(ValueError):
                remote.atomic(link, b'replace')
            self.assertEqual(original.read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
