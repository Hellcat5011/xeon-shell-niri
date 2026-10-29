#!/usr/bin/env python3
import subprocess, os, shlex, json

def get_users():
    try:
        with open('/etc/shells', 'r') as f:
            valid = {line.strip() for line in f if not line.startswith('#') and line.strip()}
    except FileNotFoundError:
        valid = set()
    denylist = {'/bin/false', '/sbin/nologin', '/usr/sbin/nologin'}
    try:
        out = subprocess.check_output(['getent', 'passwd'], text=True)
    except Exception:
        return []
    users = []
    for line in out.splitlines():
        parts = line.split(':')
        if len(parts) >= 7:
            uname, _, uid_str, _, _, _, shell = parts
            try:
                if 1000 <= int(uid_str) <= 60000 and shell not in denylist and (not valid or shell in valid):
                    users.append(uname)
            except ValueError: pass
    return users

def get_sessions():
    dirs = ['/usr/share/wayland-sessions', '/usr/share/xsessions']
    sessions = []
    for d in dirs:
        if os.path.isdir(d):
            for fname in os.listdir(d):
                if fname.endswith('.desktop'):
                    path = os.path.join(d, fname)
                    try:
                        name, exec_cmd = "", ""
                        with open(path, 'r', encoding='utf-8') as f:
                            in_desktop_entry = False
                            for line in f:
                                line = line.strip()
                                if line == '[Desktop Entry]': in_desktop_entry = True
                                elif line.startswith('[') and line.endswith(']'): in_desktop_entry = False
                                if in_desktop_entry:
                                    if line.startswith('Name=') and not name: name = line.split('=', 1)[1]
                                    elif line.startswith('Exec=') and not exec_cmd: exec_cmd = line.split('=', 1)[1]
                        if exec_cmd:
                            argv = shlex.split(exec_cmd)
                            if not name: name = fname.replace('.desktop', '')
                            sessions.append({'name': name, 'cmd': argv})
                    except Exception: pass
    return sessions

def main():
    greeter_dir = os.environ.get("GREETER_DIR", "/etc/greetd/quickshell-greeter")
    
    # Read config snapshot
    config = {"lockscreenAlignment": "left", "rememberLastUser": False}
    try:
        state_dir = os.environ.get("GREETER_STATE_DIR", "/var/lib/greetd/quickshell-greeter")
        try:
            with open(os.path.join(state_dir, "config-snapshot.json"), "r") as f:
                c = json.load(f)
        except Exception:
            with open(os.path.join(greeter_dir, "config-snapshot.json"), "r") as f:
                c = json.load(f)
        if "lockscreenAlignment" in c: config["lockscreenAlignment"] = c["lockscreenAlignment"]
        if "rememberLastUser" in c: config["rememberLastUser"] = c["rememberLastUser"]
    except Exception:
        pass

    # Read last user if enabled
    last_user, last_session = "", []
    if config["rememberLastUser"]:
        try:
            path = os.environ.get("GREETER_LAST_USER_FILE", "/var/lib/greetd/quickshell-greeter/last-user")
            with open(path, "r") as f:
                state = json.load(f)
                last_user = state.get("user", "")
                last_session = state.get("session", [])
        except Exception:
            pass

    print(json.dumps({
        "users": get_users(),
        "sessions": get_sessions(),
        "config": config,
        "last_user": last_user,
        "last_session": last_session
    }))

if __name__ == '__main__':
    main()
