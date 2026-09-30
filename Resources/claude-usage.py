# notchwave-claude-usage-v1
"""Quota-only reader. Credentials stay on their machine; never refresh or export them."""
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

MAX_BYTES = 1_000_000


def read_object(path, limit=MAX_BYTES):
    try:
        with path.open('rb') as f:
            data = f.read(limit + 1)
        if len(data) > limit:
            return {}
        value = json.loads(data)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def clean(value, limit=160):
    return ''.join(c for c in value if c.isprintable())[:limit] if isinstance(value, str) else ''


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def timestamp(value):
    if number(value):
        return value if 0 < value < 32_503_680_000 else None
    if isinstance(value, str):
        try:
            parsed = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
            return timestamp(parsed.timestamp()) if parsed.tzinfo else None
        except (ValueError, OverflowError):
            pass
    return None


def limits(payload):
    if not isinstance(payload, dict):
        return []
    windows = []
    # Current Claude /usage responses provide named limits, including scoped models.
    structured = payload.get('limits', [])
    if isinstance(structured, list):
        for value in structured[:24]:
            if not isinstance(value, dict):
                continue
            kind, used = value.get('kind'), value.get('percent')
            if not number(used) or not 0 <= used <= 100_000:
                continue
            name = ''
            if kind == 'session':
                key = 'five_hour'
            elif kind == 'weekly_all':
                key = 'seven_day'
            elif kind == 'weekly_scoped':
                scope = value.get('scope', {})
                if not isinstance(scope, dict):
                    continue
                model = scope.get('model') or {}
                surface = scope.get('surface') or {}
                model_name = clean(model.get('display_name'), 48) if isinstance(model, dict) else ''
                surface_name = clean(surface.get('display_name'), 48) if isinstance(surface, dict) else clean(surface, 48)
                name = ' · '.join(part for part in [model_name, surface_name] if part)
                if not name:
                    continue
                key = 'seven_day_' + hashlib.sha256(name.encode()).hexdigest()[:12]
            else:
                continue
            window = {'id': key, 'used': used, 'resets_at': timestamp(value.get('resets_at'))}
            if name:
                window['name'] = name
            windows.append(window)
    found = {w['id'] for w in windows}
    has_structured = bool(windows)
    for key, value in payload.items():
        if not isinstance(key, str) or not re.fullmatch(r'(five_hour|seven_day)(_[a-z0-9_]{1,48})?|spend_limit|extra_usage', key):
            continue
        if key in found or (has_structured and key not in ('spend_limit', 'extra_usage')):
            continue
        if not isinstance(value, dict):
            continue
        used = value.get('utilization', value.get('used_percentage'))
        if not number(used) or used < 0 or used > 100_000:
            continue
        windows.append({'id': key, 'used': used, 'resets_at': timestamp(value.get('resets_at'))})
    return sorted(windows, key=lambda w: (0 if w['id'] == 'five_hour' else 1 if w['id'] == 'seven_day' else 2, w['id']))[:12]


def configuration(home, local):
    explicit = os.environ.get('CLAUDE_CONFIG_DIR')
    if explicit:
        return Path(explicit).expanduser(), True
    # A tmux server retains the environment used by the user's ordinary `claude` command.
    # Noninteractive SSH sessions do not inherit it. Read this one named variable only.
    if not local and shutil.which('tmux'):
        try:
            result = subprocess.run(['tmux', 'show-environment', '-g', 'CLAUDE_CONFIG_DIR'],
                                    capture_output=True, text=True, timeout=2)
            name, separator, value = result.stdout.strip().partition('=')
            if result.returncode == 0 and name == 'CLAUDE_CONFIG_DIR' and separator and len(value) <= 4096:
                path = Path(value).expanduser()
                if path.is_absolute() and path.is_dir():
                    return path, True
        except (OSError, subprocess.SubprocessError):
            pass
    return home / '.claude', False


def metadata_path(home, config_dir, custom=False):
    # Matches Claude Code's per-configuration global metadata location.
    return config_dir / '.claude.json' if custom else home / '.claude.json'


def identity(metadata, auth):
    oauth = metadata.get('oauthAccount', {})
    if not isinstance(oauth, dict):
        oauth = {}
    email = clean(auth.get('email') or oauth.get('emailAddress')) if auth.get('loggedIn') else ''
    # An auth-status email mismatch means the metadata belongs to an older account.
    matched = bool(email and email == oauth.get('emailAddress') and
                   (not auth.get('orgId') or not oauth.get('organizationUuid') or auth['orgId'] == oauth['organizationUuid']))
    account_id = clean(oauth.get('accountUuid')) if matched else ''
    org = clean(auth.get('orgId') or (oauth.get('organizationUuid') if matched else ''))
    key = hashlib.sha256((account_id + '\n' + email + '\n' + org).encode()).hexdigest() if email else ''
    return {'email': email, 'plan': clean(auth.get('subscriptionType'), 40),
            'logged_in': auth.get('loggedIn') is True, 'identity': key}, account_id


def native_snapshot(metadata, account_id, now):
    cached = metadata.get('cachedUsageUtilization', {})
    if not isinstance(cached, dict) or not account_id or cached.get('accountUuid') != account_id:
        return None
    fetched = cached.get('fetchedAtMs')
    if not number(fetched) or not 0 <= now - fetched / 1000 <= 3600:
        return None
    windows = limits(cached.get('utilization'))
    return {'windows': windows, 'sampled_at': fetched / 1000, 'source': 'claude_cache'} if windows else None


def auth_status(home, config=None):
    candidates = [shutil.which('claude'), str(home / '.local/bin/claude'), '/opt/homebrew/bin/claude', '/usr/local/bin/claude']
    binary = next((p for p in candidates if p and os.access(p, os.X_OK)), str(home / '.local/bin/claude'))
    try:
        # This command neither starts a conversation nor changes authentication.
        environment = dict(os.environ)
        if config is not None:
            environment['CLAUDE_CONFIG_DIR'] = str(config)
        result = subprocess.run([binary, 'auth', 'status', '--json'], capture_output=True,
                                timeout=7, text=True, cwd=str(home), env=environment)
        if len(result.stdout) > 65536:
            return {}
        value = json.loads(result.stdout)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError, subprocess.SubprocessError):
        return {}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward the authorization header to another location.


def fetch(token):
    request = urllib.request.Request('https://api.anthropic.com/api/oauth/usage', headers={
        'Authorization': 'Bearer ' + token, 'anthropic-beta': 'oauth-2025-04-20',
        'User-Agent': 'Notchwave/0.8.0', 'Accept': 'application/json'})
    with urllib.request.build_opener(NoRedirect).open(request, timeout=8) as response:
        raw = response.read(65537)
    if len(raw) > 65536:
        raise ValueError('Response too large')
    return limits(json.loads(raw))


def save_cache(path, record):
    try:
        if any(p.is_symlink() for p in (path, *path.parents)):
            return
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, name = tempfile.mkstemp(prefix='.usage-', dir=path.parent)
        try:
            with os.fdopen(fd, 'w') as f:
                os.fchmod(f.fileno(), 0o600)
                json.dump(record, f, allow_nan=False)
            os.replace(name, path)
        finally:
            if os.path.exists(name):
                os.unlink(name)
    except OSError:
        pass


def read_usage(home=None, local=False, force=False, now=None):
    home = home or Path.home()
    now = time.time() if now is None else now
    config, custom = configuration(home, local)
    meta_path = metadata_path(home, config, custom)
    metadata = read_object(meta_path, 8_000_000)
    auth = auth_status(home, config if custom else None)
    account, account_id = identity(metadata, auth)
    result = {'schema': 1, 'account': account, 'windows': [], 'sampled_at': None,
              'state': 'unavailable', 'source': '', 'checked_at': now}
    if not auth:
        result['state'] = 'cli_unavailable'
        return result
    if not account['logged_in']:
        result['state'] = 'not_signed_in'
        return result
    native = native_snapshot(metadata, account_id, now)
    if native:
        result.update(native)
    if local:
        status = read_object(home / 'Library/Application Support/Notchwave/claude-usage.json', 65536)
        if account_id and status.get('accountUUID') == account_id:
            sampled = status.get('sampledAt')
            if number(sampled) and 0 <= now - sampled <= 3600:
                windows = limits(status.get('rate_limits'))
                if windows and (not native or sampled > native['sampled_at']):
                    # Preserve model-specific windows from the same account's recent /usage cache.
                    current_ids = {w['id'] for w in windows}
                    windows += [w for w in result['windows'] if w['id'] not in current_ids]
                    result.update(windows=windows, sampled_at=min(sampled, native['sampled_at']) if native else sampled, source='statusline')
        result['state'] = 'cached' if result['windows'] else 'waiting'
        return result
    if auth.get('authMethod') != 'claude.ai':
        result.update(state='unsupported', windows=[], sampled_at=None)
        return result
    credentials_path = config / '.credentials.json'
    creds = read_object(credentials_path, 65536).get('claudeAiOauth', {})
    if not isinstance(creds, dict):
        creds = {}
    token = creds.get('accessToken')
    expires = creds.get('expiresAt')
    if not isinstance(token, str) or not token:
        result['state'] = 'not_signed_in'
        return result
    cache_path = home / '.local/share/notchwave/usage-response.json'
    cache = read_object(cache_path, 65536)
    # Never attach one account's previous percentages to a new account label.
    if not account['identity'] or cache.get('account', {}).get('identity') != account['identity']:
        cache = {}
    if cache:
        cached_time = cache.get('sampled_at')
        cached_windows = cache.get('windows', [])
        if number(cached_time) and 0 <= now - cached_time <= 3600 and isinstance(cached_windows, list):
            if not native or cached_time > native['sampled_at']:
                result.update(windows=cached_windows, sampled_at=cached_time, source=cache.get('source', 'api'))
    if number(expires) and expires / 1000 <= now:
        result['state'] = 'expired'
        return result
    checked = cache.get('checked_at', 0)
    delay = 60 if force else 180
    retry_at = cache.get('retry_at', 0)
    if (number(checked) and 0 <= now - checked < delay) or (number(retry_at) and retry_at > now):
        result['state'] = cache.get('state', 'cached')
        result['retry_at'] = retry_at
        return result
    try:
        windows = fetch(token)
        # Discard a response if credentials or account changed while the request was running.
        current = read_object(credentials_path, 65536).get('claudeAiOauth', {})
        current_meta = read_object(meta_path, 8_000_000).get('oauthAccount', {})
        if not isinstance(current, dict) or current.get('accessToken') != token or (account_id and current_meta.get('accountUuid') != account_id):
            result.update(state='account_changed', windows=[], sampled_at=None)
            return result
        if windows:
            result.update(state='ok', windows=windows, sampled_at=now, source='api')
        else:
            result['state'] = 'unavailable'
    except urllib.error.HTTPError as error:
        result['state'] = 'expired' if error.code == 401 else 'forbidden' if error.code == 403 else 'rate_limited' if error.code == 429 else 'unavailable'
        if error.code == 429:
            try: wait = float(error.headers.get('Retry-After', '300'))
            except (TypeError, ValueError): wait = 300
            result['retry_at'] = now + min(3600, max(60, wait if math.isfinite(wait) else 300))
    except (OSError, ValueError, urllib.error.URLError):
        result['state'] = 'unavailable'
    save_cache(cache_path, result)
    return result


if __name__ == '__main__':
    try:
        print(json.dumps(read_usage(local='--local' in sys.argv, force='--force' in sys.argv), allow_nan=False))
    except Exception:
        # Errors may contain credentials or paths; never include raw exception text on SSH stdout.
        print(json.dumps({'schema': 1, 'state': 'unavailable', 'windows': [], 'account': {}}))
