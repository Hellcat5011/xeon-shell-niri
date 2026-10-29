#!/usr/bin/env python3
"""parse-niri-binds.py — turn niri's config.kdl keybinds into JSON for KeybindViewer.

Usage:
    parse-niri-binds.py [path/to/config.kdl]

With no argument the config is located the same way niri does:
    $NIRI_CONFIG, else $XDG_CONFIG_HOME/niri/config.kdl, else ~/.config/niri/config.kdl

Prints a JSON array on stdout:
    [{"section": "Windows", "key": "SUPER + Q", "action": "Close Window"}, ...]

`include "other.kdl"` lines are followed (relative to the including file).

niri has no IPC request that dumps the bind table, so the config file itself is
parsed. The parser understands the KDL subset niri configs use (v1 and v2
syntax): comments, slashdash (/-), quoted / raw strings, properties, children.
It never raises on odd input: unparseable parts are skipped and the exit code
is 0 so the viewer simply shows what it could read. A missing config file
prints an empty array and exits with status 2.
"""
import json
import os
import re
import sys

MAX_INCLUDE_DEPTH = 5


# ───────────────────────────── KDL subset parser ─────────────────────────────

class Node:
    __slots__ = ("name", "args", "props", "children")

    def __init__(self, name):
        self.name = name
        self.args = []
        self.props = {}
        self.children = []


WORD_END = set(' \t\r\n{}();="\\/')  # "/" handled specially (comments / slashdash)


class Parser:
    def __init__(self, text):
        self.s = text
        self.i = 0
        self.n = len(text)

    # -- low level helpers --------------------------------------------------
    def peek(self, k=0):
        j = self.i + k
        return self.s[j] if j < self.n else ""

    def skip_block_comment(self):
        # at "/*"; KDL block comments nest
        depth = 0
        while self.i < self.n:
            if self.s.startswith("/*", self.i):
                depth += 1
                self.i += 2
            elif self.s.startswith("*/", self.i):
                depth -= 1
                self.i += 2
                if depth == 0:
                    return
            else:
                self.i += 1

    def skip_line_comment(self):
        while self.i < self.n and self.s[self.i] != "\n":
            self.i += 1

    def skip_ws(self, newlines):
        """Skip whitespace and comments. If newlines is False stop at a newline."""
        while self.i < self.n:
            c = self.s[self.i]
            if c in " \t\ufeff\u00a0":
                self.i += 1
            elif c in "\r\n":
                if not newlines:
                    return
                self.i += 1
            elif c == "\\":
                # line continuation: backslash, optional ws/comment, newline
                j = self.i + 1
                while j < self.n and self.s[j] in " \t":
                    j += 1
                if j < self.n and self.s.startswith("//", j):
                    while j < self.n and self.s[j] != "\n":
                        j += 1
                if j < self.n and self.s[j] in "\r\n":
                    while j < self.n and self.s[j] in "\r\n":
                        j += 1
                    self.i = j
                else:
                    return
            elif self.s.startswith("//", self.i):
                self.skip_line_comment()
            elif self.s.startswith("/*", self.i):
                self.skip_block_comment()
            else:
                return

    # -- tokens ---------------------------------------------------------------
    def read_string(self):
        # at opening quote(s)
        if self.s.startswith('"""', self.i):
            end = self.s.find('"""', self.i + 3)
            if end == -1:
                end = self.n
            out = self.s[self.i + 3:end]
            self.i = min(end + 3, self.n)
            return out.strip("\n")
        self.i += 1
        out = []
        while self.i < self.n:
            c = self.s[self.i]
            if c == "\\":
                nxt = self.peek(1)
                out.append({"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "/": "/",
                            "b": "\b", "f": "\f", "s": " "}.get(nxt, nxt))
                self.i += 2
            elif c == '"':
                self.i += 1
                return "".join(out)
            else:
                out.append(c)
                self.i += 1
        return "".join(out)

    def read_raw_string(self):
        # r#"..."#  (KDL v1)  or  #"..."#  (KDL v2); at the 'r' or '#'
        j = self.i
        if self.s[j] == "r":
            j += 1
        hashes = 0
        while j < self.n and self.s[j] == "#":
            hashes += 1
            j += 1
        if j >= self.n or self.s[j] != '"':
            return None
        closing = '"' + "#" * hashes
        end = self.s.find(closing, j + 1)
        if end == -1:
            end = self.n
        out = self.s[j + 1:end]
        self.i = min(end + len(closing), self.n)
        return out

    def read_word(self):
        start = self.i
        while self.i < self.n:
            c = self.s[self.i]
            if c in WORD_END:
                if c == "/" and self.s.startswith(("//", "/*"), self.i):
                    break
                if c == "/":
                    self.i += 1  # a lone slash is a legal identifier character
                    continue
                break
            self.i += 1
        return self.s[start:self.i]

    def read_value(self):
        """Read a string or bare word at the cursor. Returns (value, was_quoted)."""
        c = self.peek()
        if c == '"':
            return self.read_string(), True
        if c == "#" or (c == "r" and self.peek(1) in ('#', '"')):
            save = self.i
            raw = self.read_raw_string()
            if raw is not None:
                return raw, True
            self.i = save
        if c == "(":  # type annotation: (u8)5 — skip it
            while self.i < self.n and self.s[self.i] != ")":
                self.i += 1
            self.i += 1
            return self.read_value()
        w = self.read_word()
        if w.startswith("#"):  # KDL v2 keywords: #true #false #null
            w = w[1:]
        return w, False

    # -- grammar --------------------------------------------------------------
    def parse_nodes(self, in_block):
        nodes = []
        while True:
            self.skip_ws(newlines=True)
            while self.peek() == ";":
                self.i += 1
                self.skip_ws(newlines=True)
            if self.i >= self.n:
                return nodes
            if self.peek() == "}":
                if in_block:
                    self.i += 1
                    return nodes
                self.i += 1  # stray brace at top level: ignore
                continue
            slashdash = False
            if self.s.startswith("/-", self.i):
                slashdash = True
                self.i += 2
                self.skip_ws(newlines=True)
            node = self.parse_node()
            if node is not None and not slashdash:
                nodes.append(node)

    def parse_node(self):
        before = self.i
        name, _ = self.read_value()
        if name == "" and self.i == before:
            self.i += 1  # unknown character: skip it so we always make progress
            return None
        node = Node(name)
        while True:
            self.skip_ws(newlines=False)
            c = self.peek()
            if c in ("", "\n", "\r", ";"):
                if c == ";":
                    self.i += 1
                return node
            if c == "}":
                return node  # closing brace of the parent block (not consumed)
            slashdash = False
            if self.s.startswith("/-", self.i):
                slashdash = True
                self.i += 2
                self.skip_ws(newlines=False)
                c = self.peek()
            if c == "{":
                self.i += 1
                kids = self.parse_nodes(in_block=True)
                if not slashdash:
                    node.children.extend(kids)
                continue
            before = self.i
            val, quoted = self.read_value()
            if self.i == before:
                self.i += 1
                continue
            self.skip_ws(newlines=False)
            if self.peek() == "=":
                self.i += 1
                self.skip_ws(newlines=False)
                pval, pquoted = self.read_value()
                if not slashdash:
                    node.props[val] = None if (pval == "null" and not pquoted) else pval
            elif not slashdash:
                node.args.append(val)


def parse_kdl(text):
    return Parser(text).parse_nodes(in_block=False)


# ───────────────────────────── config loading ────────────────────────────────

def read_file(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def load_nodes(path, depth=0, seen=None):
    """Parse `path` and splice in `include`d files (best effort)."""
    seen = seen if seen is not None else set()
    real = os.path.realpath(path)
    if real in seen or depth > MAX_INCLUDE_DEPTH:
        return []
    seen = seen | {real}
    text = read_file(path)
    if text is None:
        return []
    out = []
    for node in parse_kdl(text):
        if node.name == "include" and node.args:
            inc = os.path.expanduser(node.args[0])
            if not os.path.isabs(inc):
                inc = os.path.join(os.path.dirname(path), inc)
            out.extend(load_nodes(inc, depth + 1, seen))
        else:
            out.append(node)
    return out


def find_config():
    env = os.environ.get("NIRI_CONFIG")
    if env:
        return os.path.expanduser(env)
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "niri", "config.kdl")


# ───────────────────────────── presentation ──────────────────────────────────

MOD_NAMES = {
    "mod": "SUPER", "super": "SUPER", "win": "SUPER", "logo": "SUPER",
    "ctrl": "CTRL", "control": "CTRL", "shift": "SHIFT", "alt": "ALT",
    "iso_level3_shift": "ALTGR", "mod5": "ALTGR",
    "iso_level5_shift": "LEVEL5", "mod3": "LEVEL5",
}

KEY_NAMES = {
    "slash": "/", "backslash": "\\", "comma": ",", "period": ".", "minus": "-",
    "equal": "=", "plus": "Plus", "semicolon": ";", "apostrophe": "'", "grave": "`",
    "bracketleft": "[", "bracketright": "]", "return": "Enter", "escape": "Esc",
    "print": "PrtSc", "space": "Space", "prior": "PgUp", "next": "PgDn",
    "page_up": "PgUp", "page_down": "PgDn", "delete": "Del",
    "wheelscrolldown": "Scroll Down", "wheelscrollup": "Scroll Up",
    "wheelscrollleft": "Scroll Left", "wheelscrollright": "Scroll Right",
    "touchpadscrolldown": "Touchpad Scroll Down", "touchpadscrollup": "Touchpad Scroll Up",
    "touchpadscrollleft": "Touchpad Scroll Left", "touchpadscrollright": "Touchpad Scroll Right",
    "mousemiddle": "Middle Click", "mouseleft": "Left Click", "mouseright": "Right Click",
}


def key_label(combo):
    # "Mod+Shift+Slash" → "SUPER + SHIFT + /".  A literal "+" key is written
    # as "Mod+plus" in niri configs, so a plain split on "+" is safe.
    parts = [p for p in combo.split("+") if p != ""]
    out = []
    for idx, p in enumerate(parts):
        low = p.lower()
        if idx < len(parts) - 1 and low in MOD_NAMES:
            out.append(MOD_NAMES[low])
        elif low in MOD_NAMES and len(parts) == 1:
            out.append(MOD_NAMES[low])  # bare modifier bind, e.g. `Mod { ... }`
        elif low in KEY_NAMES:
            out.append(KEY_NAMES[low])
        elif len(p) == 1:
            out.append(p.upper())
        else:
            out.append(p)
    return " + ".join(out)


QS_NAMES = {
    "notif toggle": "Notification Center",
    "wallpaper toggle": "Wallpaper Picker",
    "launcher toggle": "App Launcher",
    "power toggle": "Power Menu",
    "clipboard toggle": "Clipboard History",
    "emoji toggle": "Emoji Picker",
    "keybinds toggle": "Keybind Viewer",
    "settings toggle": "Settings",
    "lock lock": "Lock Screen",
}

ACTION_NAMES = {
    "quit": "Exit Niri",
    "close-window": "Close Window",
    "fullscreen-window": "Toggle Fullscreen",
    "toggle-windowed-fullscreen": "Toggle Windowed Fullscreen",
    "maximize-column": "Maximize Column",
    "maximize-window-to-edges": "Maximize Window",
    "toggle-window-floating": "Toggle Floating",
    "switch-focus-between-floating-and-tiling": "Switch Floating / Tiling Focus",
    "toggle-overview": "Toggle Overview",
    "open-overview": "Open Overview",
    "close-overview": "Close Overview",
    "show-hotkey-overlay": "Show Hotkey Overlay",
    "power-off-monitors": "Power Off Monitors",
    "toggle-keyboard-shortcuts-inhibit": "Toggle Shortcuts Inhibit",
    "screenshot": "Screenshot (Select Region)",
    "screenshot-screen": "Screenshot Screen",
    "screenshot-window": "Screenshot Window",
    "next-window": "Next Window (Alt-Tab)",
    "previous-window": "Previous Window (Alt-Tab)",
    "focus-window-previous": "Focus Previous Window",
    "toggle-column-tabbed-display": "Toggle Tabbed Column",
    "switch-preset-column-width": "Cycle Column Width",
    "switch-preset-window-height": "Cycle Window Height",
    "consume-or-expel-window-left": "Consume / Expel Window Left",
    "consume-or-expel-window-right": "Consume / Expel Window Right",
    "toggle-touchpad": "Toggle Touchpad",
}


def human_cmd(cmd):
    """Friendly name + category hint for a spawned command line."""
    c = cmd.strip()
    m = re.search(r"\b(?:qs|quickshell)\b.*?\bipc\s+call\s+(\w+)\s+(\w+)", c)
    if m:
        key = m.group(1) + " " + m.group(2)
        if key in QS_NAMES:
            return QS_NAMES[key], "Shell"
        return m.group(1).capitalize() + " → " + m.group(2), "Shell"
    low = c.lower()
    if "volume.sh" in low or "set-volume" in low:
        return "Volume " + ("Up" if "+" in c else "Down" if "-" in c else "Mute"), "Media & Hardware"
    if "set-mute" in low:
        return ("Mute Microphone" if "SOURCE" in c else "Mute Volume"), "Media & Hardware"
    if "brightness.sh" in low or "brightnessctl" in low:
        return "Brightness " + ("Up" if "+" in c else "Down"), "Media & Hardware"
    if "playerctl" in low:
        return "Media " + (c.split("playerctl", 1)[1].strip().title() or "Control"), "Media & Hardware"
    if "pavucontrol" in low:
        return "Audio Settings", "Applications"
    if "blueman" in low:
        return "Bluetooth Manager", "Applications"
    if "pick-color" in low or "hyprpicker" in low:
        return "Color Picker", "Applications"
    short = c if len(c) <= 56 else c[:53] + "…"
    return "Run: " + short, "Applications"


def humanise(name, args, props):
    if name in ("spawn", "spawn-sh"):
        cmd = args[0] if name == "spawn-sh" and args else " ".join(args)
        return human_cmd(cmd)
    if name in ACTION_NAMES:
        label = ACTION_NAMES[name]
    else:
        label = " ".join(w.capitalize() for w in name.split("-"))
    if args:
        label += " " + " ".join(args)
    if props.get("filter") == "app-id":
        label = label.replace(" (Alt-Tab)", "") + " (Same App)"
    if props.get("scope"):
        label += " (" + str(props["scope"]) + ")"
    return label, section_for(name)


def section_for(name):
    if name.startswith("screenshot"):
        return "Screenshots"
    if "workspace" in name:
        return "Workspaces"
    if "monitor" in name:
        return "Monitors"
    if "column" in name:
        return "Columns"
    if "window" in name or "overview" in name or "floating" in name:
        return "Windows"
    if name in ("quit", "power-off-monitors", "show-hotkey-overlay",
                "toggle-keyboard-shortcuts-inhibit", "do-screen-transition",
                "toggle-touchpad"):
        return "Session & System"
    return "Other"


SECTION_ORDER = ["Shell", "Applications", "Media & Hardware", "Windows", "Columns",
                 "Workspaces", "Monitors", "Screenshots", "Session & System", "Other"]


def bind_rows(bind_nodes):
    rows = []
    for b in bind_nodes:
        combo = b.name
        title = b.props.get("hotkey-overlay-title")
        trigger = ""
        action = None
        for child in b.children:
            if child.name in ("press", "release") and child.children:
                action = child.children[0]
                trigger = " (on %s)" % child.name
                break
            action = child
            break
        if action is None:
            continue
        label, section = humanise(action.name, action.args, action.props)
        # niri's own hotkey-overlay-title is the best label when the user set one
        # (but never for spawns of our own shell, which we label ourselves).
        if isinstance(title, str) and title.strip() and section != "Shell":
            label = title.strip()
        rows.append({"section": section, "key": key_label(combo), "action": label + trigger})
    return rows


def collect_rows(nodes):
    bind_nodes = []
    for n in nodes:
        if n.name == "binds":
            bind_nodes.extend(n.children)
        elif n.name == "recent-windows":
            for sub in n.children:
                if sub.name == "binds":
                    bind_nodes.extend(sub.children)
    rows = bind_rows(bind_nodes)
    order = {s: i for i, s in enumerate(SECTION_ORDER)}
    rows.sort(key=lambda r: order.get(r["section"], len(order)))  # stable
    return rows


def main(argv):
    path = argv[1] if len(argv) > 1 else find_config()
    if not os.path.isfile(path):
        print("[]")
        print("parse-niri-binds: config not found: %s" % path, file=sys.stderr)
        return 2
    print(json.dumps(collect_rows(load_nodes(path)), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
