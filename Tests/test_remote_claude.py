import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('remote', Path(__file__).resolve().parents[1] / 'Resources/remote-claude.py')
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)


class RemoteTests(unittest.TestCase):
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
