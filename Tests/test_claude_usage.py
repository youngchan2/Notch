import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

spec = importlib.util.spec_from_file_location('usage', Path(__file__).resolve().parents[1] / 'Resources/claude-usage.py')
usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(usage)


class UsageTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.home = Path(self.folder.name).resolve()
        self.config = self.home / '.claude'
        self.config.mkdir()
        self.meta = self.home / '.claude.json'
        self.meta.write_text(json.dumps({'oauthAccount': {'accountUuid': 'account-a', 'emailAddress': 'a@example.com', 'organizationUuid': 'org-a'}}))
        self.creds = self.config / '.credentials.json'
        self.creds.write_text(json.dumps({'claudeAiOauth': {'accessToken': 'SECRET_TOKEN', 'refreshToken': 'NEVER_REFRESH', 'expiresAt': 2_000_000}}))
        self.auth = {'loggedIn': True, 'authMethod': 'claude.ai', 'email': 'a@example.com', 'subscriptionType': 'max', 'orgId': 'org-a'}
        self.env = patch.dict(usage.os.environ, {}, clear=True)
        self.env.start()
        self.status = patch.object(usage, 'auth_status', return_value=self.auth)
        self.status.start()

    def tearDown(self):
        self.status.stop()
        self.env.stop()
        self.folder.cleanup()

    def read(self, **kwargs):
        return usage.read_usage(home=self.home, now=1000, **kwargs)

    def test_all_returned_limits_and_zero(self):
        result = usage.limits({'five_hour': {'utilization': 28, 'resets_at': '2026-10-01T00:00:00Z'},
                               'seven_day': {'utilization': 8}, 'seven_day_fable': {'utilization': 0},
                               'seven_day_sonnet': None, 'context_window': {'utilization': 99},
                               'seven_day_bad': {'utilization': float('nan')}, 'five_hour_bool': {'utilization': True}})
        self.assertEqual([w['id'] for w in result], ['five_hour', 'seven_day', 'seven_day_fable'])
        self.assertEqual(result[-1]['used'], 0)
        self.assertIsNotNone(result[0]['resets_at'])

    def test_named_limits_preferred_without_legacy_duplicates(self):
        response = {'limits': [
            {'kind': 'session', 'percent': 28, 'resets_at': '2026-09-29T13:40:00+00:00'},
            {'kind': 'weekly_all', 'percent': 8},
            {'kind': 'weekly_scoped', 'percent': 0, 'scope': {'model': {'display_name': 'Fable'}}}],
            'five_hour': {'utilization': 28}, 'seven_day': {'utilization': 8},
            'nimbus_quill': {'utilization': 0}, 'seven_day_fable': {'utilization': 0}}
        result = usage.limits(response)
        self.assertEqual(len(result), 3)
        self.assertEqual(result[2]['name'], 'Fable')
        self.assertEqual(result[2]['used'], 0)

    def test_login_configuration_takes_priority_over_legacy_account(self):
        alternate = self.home / '.config/claude'
        alternate.mkdir(parents=True)
        (alternate / '.claude.json').write_text(json.dumps({'oauthAccount': {'accountUuid': 'account-b', 'emailAddress': 'b@example.com'}}))
        (alternate / '.credentials.json').write_text(self.creds.read_text())
        with patch.dict(usage.os.environ, {'CLAUDE_CONFIG_DIR': str(alternate)}), patch.object(usage, 'auth_status', return_value=dict(self.auth, email='b@example.com')):
            with patch.object(usage, 'fetch', return_value=[{'id': 'five_hour', 'used': 3, 'resets_at': 2000}]):
                result = self.read()
        self.assertEqual(result['account']['email'], 'b@example.com')
        self.assertEqual(result['windows'][0]['used'], 3)

    def test_fresh_response_contains_no_credentials_or_unrelated_metadata(self):
        with patch.object(usage, 'fetch', return_value=[{'id': 'five_hour', 'used': 28, 'resets_at': 2000}]) as fetch:
            result = self.read()
        self.assertEqual(result['account']['email'], 'a@example.com')
        self.assertEqual(result['state'], 'ok')
        self.assertEqual(result['windows'][0]['used'], 28)
        self.assertNotIn('SECRET', json.dumps(result))
        self.assertNotIn('NEVER_REFRESH', (self.home / '.local/share/notchwave/usage-response.json').read_text())
        fetch.assert_called_once_with('SECRET_TOKEN')
        self.assertIn('NEVER_REFRESH', self.creds.read_text())

    def test_expired_auth_never_refreshes_or_requests_usage(self):
        before = json.loads(self.creds.read_text())
        before['claudeAiOauth']['expiresAt'] = 500_000
        self.creds.write_text(json.dumps(before))
        with patch.object(usage, 'fetch') as fetch:
            self.assertEqual(self.read()['state'], 'expired')
            fetch.assert_not_called()
        self.assertEqual(json.loads(self.creds.read_text()), before)

    def test_signed_out_does_not_reuse_old_metadata(self):
        with patch.object(usage, 'auth_status', return_value={'loggedIn': False}), patch.object(usage, 'fetch') as fetch:
            result = self.read()
            fetch.assert_not_called()
        self.assertEqual(result['state'], 'not_signed_in')
        self.assertEqual(result['account']['email'], '')
        self.assertEqual(result['windows'], [])

    def test_native_snapshot_must_match_account_and_age(self):
        cache = {'cachedUsageUtilization': {'accountUuid': 'account-a', 'fetchedAtMs': 900_000,
                    'utilization': {'seven_day_fable': {'utilization': 0}}}}
        self.assertIsNotNone(usage.native_snapshot(cache, 'account-a', 1000))
        self.assertIsNone(usage.native_snapshot(cache, 'account-b', 1000))
        self.assertIsNone(usage.native_snapshot(cache, 'account-a', 5000))
        self.assertIsNone(usage.native_snapshot(cache, '', 1000))

    def test_new_account_never_gets_cached_quota(self):
        with patch.object(usage, 'fetch', return_value=[{'id': 'seven_day', 'used': 91, 'resets_at': 2000}]):
            self.read()
        self.auth.update(email='b@example.com', orgId='org-b')
        self.meta.write_text(json.dumps({'oauthAccount': {'accountUuid': 'account-b', 'emailAddress': 'b@example.com'}}))
        with patch.object(usage, 'fetch', side_effect=OSError('failed')):
            result = self.read(force=True)
        self.assertEqual(result['account']['email'], 'b@example.com')
        self.assertEqual(result['windows'], [])

    def test_account_change_during_fetch_discards_response(self):
        def change_account(_):
            self.creds.write_text(json.dumps({'claudeAiOauth': {'accessToken': 'OTHER_ACCOUNT_TOKEN'}}))
            return [{'id': 'five_hour', 'used': 91, 'resets_at': 2000}]
        with patch.object(usage, 'fetch', side_effect=change_account):
            result = self.read()
        self.assertEqual(result['state'], 'account_changed')
        self.assertEqual(result['windows'], [])

    def test_retry_after_and_manual_refresh_are_throttled(self):
        error = urllib.error.HTTPError('https://api.anthropic.com/api/oauth/usage', 429, 'limited', {'Retry-After': '600'}, None)
        with patch.object(usage, 'fetch', side_effect=error) as fetch:
            result = self.read()
            self.assertEqual(result['state'], 'rate_limited')
            self.read(force=True)
            fetch.assert_called_once()
        self.assertEqual(result['retry_at'], 1600)

    def test_local_statusline_requires_matching_account(self):
        cache = self.home / 'Library/Application Support/Notchwave/claude-usage.json'
        cache.parent.mkdir(parents=True)
        cache.write_text(json.dumps({'accountUUID': 'account-b', 'sampledAt': 999,
                         'rate_limits': {'five_hour': {'used_percentage': 45}}}))
        with patch.object(usage, 'fetch') as fetch:
            self.assertEqual(self.read(local=True)['windows'], [])
            cache.write_text(cache.read_text().replace('account-b', 'account-a'))
            result = self.read(local=True)
            self.assertEqual(result['windows'][0]['used'], 45)
            fetch.assert_not_called()

    def test_readers_are_bounded_and_redirects_rejected(self):
        large = self.home / 'large.json'
        large.write_text('{"private": "' + 'x' * 100 + '"}')
        self.assertEqual(usage.read_object(large, 20), {})
        self.assertIsNone(usage.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://other.example'))


if __name__ == '__main__':
    unittest.main()
