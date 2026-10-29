#!/usr/bin/env python3
"""
greet-helper.py - bridges a Quickshell greeter to greetd over its IPC socket.
"""
import json, os, socket, struct, sys, subprocess

TIMEOUT_S = 10
MAX_PROMPTS = 5

def send_msg(sock, obj):
    body = json.dumps(obj).encode("utf-8")
    sock.sendall(struct.pack("=I", len(body)) + body)

def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("greetd closed the socket")
        buf += chunk
    return buf

def recv_msg(sock):
    (length,) = struct.unpack("=I", recv_exact(sock, 4))
    if length > 1 << 20:
        raise ValueError("oversized message from greetd")
    return json.loads(recv_exact(sock, length).decode("utf-8"))

def fail(reason):
    print(f"FAIL:{reason}", file=sys.stderr)
    sys.exit(1)

def write_last_user(username, session_cmd):
    path = os.environ.get("GREETER_LAST_USER_FILE", "/var/lib/greetd/quickshell-greeter/last-user")
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump({"user": username, "session": session_cmd}, f)
        os.chmod(path, 0o664)
    except Exception as e:
        print(f"WARN: could not write last-user state: {e!r}", file=sys.stderr)

def run_exit_cmd():
    raw = os.environ.get("GREETER_EXIT_CMD", "")
    if not raw:
        print("WARN: GREETER_EXIT_CMD not set - greeter will NOT self-terminate; "
              "greetd is waiting for this process's compositor to exit.",
              file=sys.stderr)
        return
    try:
        cmd = json.loads(raw)
        subprocess.run(cmd, timeout=5, check=True)
    except Exception as e:
        print(f"WARN: GREETER_EXIT_CMD failed ({e!r}); greeter may hang on "
              f"'starting session'", file=sys.stderr)

def main():
    if len(sys.argv) < 4:
        fail("usage: greet-helper.py <remember_1_0> <username> <session_cmd...>")
    remember = (sys.argv[1] == "1")
    username = sys.argv[2]
    session_cmd = sys.argv[3:]
    password = sys.stdin.readline().rstrip("\n")

    sock_path = os.environ.get("GREETD_SOCK")
    if not sock_path:
        fail("GREETD_SOCK not set - this must be run inside a greetd session")

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(TIMEOUT_S)

    # Any exit path that leaves a session open on the greetd side must send
    # cancel_session explicitly before disconnecting. Disconnect-triggered
    # cleanup is not reliable enough on real greetd — without this, a retry
    # after a wrong password hits "session is already being configured".
    session_open = False

    def cancel_and_fail(reason):
        nonlocal session_open
        if session_open:
            try:
                send_msg(sock, {"type": "cancel_session"})
                # Clean shutdown so greetd sees FIN instead of RST. Reduces
                # "client loop failed" noise in the journal.
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except Exception:
                    pass
            except Exception:
                pass
            session_open = False
        fail(reason)

    try:
        sock.connect(sock_path)
        send_msg(sock, {"type": "create_session", "username": username})
        session_open = True
        resp = recv_msg(sock)

        prompts = 0
        while resp.get("type") == "auth_message":
            prompts += 1
            if prompts > MAX_PROMPTS:
                cancel_and_fail(f"too many auth prompts ({prompts}), aborting")
            kind = resp.get("auth_message_type")
            if kind == "secret":
                send_msg(sock, {"type": "post_auth_message_response", "response": password})
            elif kind in ("info", "error"):
                send_msg(sock, {"type": "post_auth_message_response"})
            else:
                cancel_and_fail(f"unsupported auth prompt type '{kind}' - cannot answer "
                                f"automatically (this greeter only handles a single "
                                f"secret/password prompt)")
            resp = recv_msg(sock)

        if resp.get("type") == "error":
            cancel_and_fail(resp.get("description", "auth error"))
        if resp.get("type") != "success":
            cancel_and_fail(f"unexpected response after auth: {resp}")

        # Auth succeeded. Once start_session is sent, the greetd-side session
        # is consumed, so no cancel is needed after this point.
        send_msg(sock, {"type": "start_session", "cmd": session_cmd})
        session_open = False
        resp = recv_msg(sock)
        if resp.get("type") == "error":
            fail(resp.get("description", "start_session error"))
        if resp.get("type") != "success":
            fail(f"unexpected response to start_session: {resp}")

        if remember:
            write_last_user(username, session_cmd)

        run_exit_cmd()
        print("OK")
    except Exception as e:
        cancel_and_fail(str(e))
    finally:
        try:
            sock.close()
        except Exception:
            pass

if __name__ == "__main__":
    main()
