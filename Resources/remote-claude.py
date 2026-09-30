# notchwave-remote-claude-v1
"""Private, bounded Claude hook mailbox; no transcript or command collection."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path.home() / '.local/share/notchwave'
EVENTS = ('Stop', 'PermissionRequest', 'Notification', 'PostToolUse',
          'PostToolUseFailure', 'UserPromptSubmit', 'SessionEnd', 'StopFailure')
MARKER = ' --notchwave-remote-claude'


def config_directory():
    configured = os.environ.get('CLAUDE_CONFIG_DIR', '')
    if not configured:
        try:
            output = subprocess.check_output(
                ['tmux', 'show-environment', '-g', 'CLAUDE_CONFIG_DIR'],
                text=True, timeout=2, stderr=subprocess.DEVNULL).strip()
            if output.startswith('CLAUDE_CONFIG_DIR='):
                configured = output.split('=', 1)[1]
        except (OSError, subprocess.SubprocessError):
            pass
    return Path(configured).expanduser() if configured else Path.home() / '.claude'


def settings_target(settings):
    # Dotfile managers often link settings.json. Write the owned target atomically,
    # preserving the link, instead of replacing it or silently using another profile.
    target = settings.resolve()
    if target != settings.absolute():
        if Path.home().resolve() not in target.parents or not target.is_file():
            raise ValueError('Claude settings link must point to a file inside your home')
    if target.exists() and (not target.is_file() or target.stat().st_uid != os.getuid()):
        raise ValueError('Claude settings must be a file owned by the current user')
    return target


def directory(path):
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('Notchwave directory is a symbolic link')
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path, 0o700)


def atomic(path, data, mode=0o600):
    if path.is_symlink():
        raise ValueError('Refusing to replace a symbolic link')
    fd, tmp = tempfile.mkstemp(prefix='.notchwave-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(data)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def updated_settings(original, command, enabled):
    if not isinstance(original, dict) or not isinstance(original.get('hooks', {}), dict):
        raise ValueError('Invalid Claude settings')
    result = dict(original)
    hooks = dict(result.get('hooks', {}))
    for event in EVENTS:
        groups = hooks.get(event, [])
        if not isinstance(groups, list):
            raise ValueError('Invalid existing hook configuration')
        kept_groups = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get('hooks'), list):
                raise ValueError('Invalid existing hook group')
            handlers = group['hooks']
            if not all(isinstance(h, dict) for h in handlers):
                raise ValueError('Invalid existing hook handler')
            kept = [h for h in handlers if not (
                h.get('type') == 'command' and
                isinstance(h.get('command'), str) and
                h['command'].endswith(MARKER) and 'remote-claude.py' in h['command'])]
            if len(kept) == len(handlers):
                kept_groups.append(group)
            elif kept:
                kept_groups.append(dict(group, hooks=kept))
        if enabled:
            group = {'hooks': [{'type': 'command', 'command': command, 'timeout': 3}]}
            if event == 'Notification':
                group['matcher'] = 'permission_prompt'
            kept_groups.append(group)
        if kept_groups:
            hooks[event] = kept_groups
        else:
            hooks.pop(event, None)
    if hooks:
        result['hooks'] = hooks
    else:
        result.pop('hooks', None)
    return result


def install(enabled=True):
    settings = config_directory() / 'settings.json'
    target = settings_target(settings)
    before = target.read_bytes() if target.exists() else None
    if before is not None and len(before) > 1_000_000:
        raise ValueError('Claude settings are too large')
    original = json.loads(before) if before else {}
    command = shlex.quote(sys.executable) + ' ' + shlex.quote(str(ROOT / 'remote-claude.py')) + MARKER
    result = updated_settings(original, command, enabled)
    target.parent.mkdir(parents=True, exist_ok=True)
    directory(ROOT)
    backups = ROOT / 'settings-backups'
    directory(backups)
    backup = backups / (hashlib.sha256(str(target).encode()).hexdigest() + '.json')
    if before is not None and not backup.exists():
        atomic(backup, before)
    if settings_target(settings) != target or (target.read_bytes() if target.exists() else None) != before:
        raise ValueError('Claude settings changed during setup; retry')
    mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o600
    atomic(target, (json.dumps(result, ensure_ascii=False, indent=2) + '\n').encode(), mode)
    print(json.dumps({'notchwave': 1, 'type': 'installed' if enabled else 'removed'}))


def label(value, limit):
    return ''.join(c for c in str(value) if c.isprintable())[:limit]


def tmux_target():
    pane = os.environ.get('TMUX_PANE', '')
    pieces = os.environ.get('TMUX', '').rsplit(',', 2)
    binary = shutil.which('tmux')
    if not binary or len(pieces) != 3 or not re.fullmatch(r'%\d+', pane):
        return None
    socket = pieces[0]
    try:
        output = subprocess.check_output(
            [binary, '-S', socket, 'display-message', '-p', '-t', pane,
             '#{pid}|#{pane_id}|#{pane_pid}'], timeout=0.7, stderr=subprocess.DEVNULL,
            text=True).strip().split('|')
        if len(output) == 3 and output[1] == pane and output[0].isdigit() and output[2].isdigit():
            return {'socket': socket, 'server': output[0], 'pane': pane, 'pid': output[2]}
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def normalize(payload, now=None):
    event = payload.get('hook_event_name')
    session = payload.get('session_id')
    if event not in EVENTS or not isinstance(session, str) or not 0 < len(session) <= 200:
        return None
    if event == 'Notification' and payload.get('notification_type') != 'permission_prompt':
        return None
    tool = payload.get('tool_name', '')
    # State replacement needs only turn-level resume or actual pending-tool completion.
    return {'id': str(uuid.uuid4()), 'session': session,
            'key': hashlib.sha256(session.encode()).hexdigest(), 'hook': event,
            'project': label(Path(str(payload.get('cwd', ''))).name, 64),
            'tool': label(tool, 200), 'created': time.time() if now is None else now}


def capture():
    raw = sys.stdin.buffer.read(2_000_001)
    if len(raw) > 2_000_000:
        return
    event = normalize(json.loads(raw))
    if event is None:
        return
    directory(ROOT)
    mailbox = ROOT / 'events'
    directory(mailbox)
    with (ROOT / 'capture.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = mailbox / (event['key'] + '.json')
        previous = read_event(path)
        if event['hook'] == 'Notification' and previous and previous['hook'] == 'PermissionRequest':
            return  # The delayed permission notification describes the same tool request.
        if event['hook'] in ('PostToolUse', 'PostToolUseFailure'):
            if not previous or previous['hook'] not in ('PermissionRequest', 'Notification'):
                return
            if previous.get('tool') and previous['tool'] != event['tool']:
                return
        event['tmux'] = tmux_target()
        atomic(path, json.dumps(event, ensure_ascii=False).encode())
        files = sorted(mailbox.glob('*.json'), key=lambda p: p.stat().st_mtime, reverse=True)
        for old in files[200:]:
            old.unlink(missing_ok=True)


def read_event(path):
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 8192:
            return None
        event = json.loads(path.read_text())
        if not isinstance(event, dict) or not -60 < time.time() - event['created'] < 3600:
            return None
        return event
    except (OSError, ValueError, KeyError, TypeError):
        return None


def emit(value):
    print(json.dumps(dict(value, notchwave=1), ensure_ascii=False), flush=True)


def hooks_ready(settings):
    try:
        with settings.open('rb') as handle:
            raw = handle.read(1_000_001)
        if len(raw) > 1_000_000:
            return False
        value = json.loads(raw)
        if value.get('disableAllHooks') is True:
            return False
        hooks = value.get('hooks', {})
        return all(any(h.get('type') == 'command' and
                       isinstance(h.get('command'), str) and
                       h['command'].endswith(MARKER) and 'remote-claude.py' in h['command']
                       for group in hooks.get(event, []) for h in group.get('hooks', []))
                   for event in EVENTS)
    except (OSError, ValueError, TypeError, AttributeError):
        return False


def watch():
    sent = {}
    settings = config_directory() / 'settings.json'
    emit({'type': 'ready', 'hooks_ready': hooks_ready(settings)})
    heartbeat = time.monotonic()
    while True:
        events = [e for p in (ROOT / 'events').glob('*.json') if (e := read_event(p))]
        for event in sorted(events, key=lambda e: e['created']):
            if sent.get(event['key']) == event['id']:
                continue
            sent[event['key']] = event['id']
            wire = {k: v for k, v in event.items() if k != 'tmux'}
            wire['can_attach'] = bool(event.get('tmux'))
            emit({'type': 'event', 'event': wire})
        sent = {e['key']: e['id'] for e in events}
        if time.monotonic() - heartbeat >= 15:
            emit({'type': 'heartbeat', 'hooks_ready': hooks_ready(settings)})
            heartbeat = time.monotonic()
        time.sleep(1)


def attach(key, validate_only=False):
    if not re.fullmatch(r'[a-f0-9]{64}', key):
        raise ValueError('Invalid session reference')
    event = read_event(ROOT / 'events' / (key + '.json'))
    target = event.get('tmux') if event else None
    binary = shutil.which('tmux')
    if not target or not binary:
        raise ValueError('This tmux task is no longer available')
    # Verify both server and pane process: IDs can be reused after a tmux restart.
    prefix = [binary, '-S', target['socket']]
    actual = subprocess.check_output(prefix + ['display-message', '-p', '-t', target['pane'],
        '#{pid}|#{pane_id}|#{pane_pid}'], text=True, timeout=3).strip()
    if actual != '|'.join([target['server'], target['pane'], target['pid']]):
        raise ValueError('The original tmux task has ended')
    if validate_only:
        emit({'type': 'attachable'})
        return
    subprocess.run(prefix + ['select-pane', '-t', target['pane']], check=True)
    os.execv(binary, prefix + ['attach-session', '-t', target['pane']])


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ''
    if mode == '--notchwave-remote-claude':
        try:
            capture()
        except Exception:
            pass  # Hooks never block Claude or decide tool permissions.
    elif mode == 'install':
        install()
    elif mode == 'remove':
        install(False)
    elif mode == 'watch':
        watch()
    elif mode in ('attach', 'check-attach'):
        attach(sys.argv[2], validate_only=mode == 'check-attach')
    else:
        raise ValueError('Unknown Notchwave action')


if __name__ == '__main__':
    try:
        main()
    except BrokenPipeError:
        pass
    except Exception as error:
        print('Notchwave: ' + str(error), file=sys.stderr)
        sys.exit(1)
