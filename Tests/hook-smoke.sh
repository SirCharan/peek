#!/bin/bash
# Smoke test for peek-hook + install/uninstall. Uses a temp HOME only. Run after `swift build -c release`.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${PEEK_HOOK:-$ROOT/.build/release/peek-hook}"
[ -x "$HOOK" ] || { echo "FAIL: $HOOK not built (swift build -c release)"; exit 1; }
FAKE="$(mktemp -d /tmp/peek-smoke.XXXXXX)"   # short path: unix socket paths max out at 103 bytes
trap 'kill $STUB 2>/dev/null; rm -rf "$FAKE"' EXIT
export HOME="$FAKE"
FAIL=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAIL=1; }

PERM='{"session_id":"sid-perm","transcript_path":"/t","cwd":"/w","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test"}}'
PRE='{"session_id":"sid-pre","transcript_path":"/t","cwd":"/w","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/w/a.swift"}}'

echo "{}" | "$HOOK"   # warm the freshly built binary (first exec is slow)
# (a) no socket: exit 0, empty stdout, under 100 ms
python3 - "$HOOK" "$PERM" <<'PY' && ok "(a) no socket: empty stdout, exit 0, fast" || bad "(a) no socket"
import subprocess, sys, time
t = time.time()
r = subprocess.run([sys.argv[1]], input=sys.argv[2].encode(), capture_output=True, timeout=10)
ms = (time.time() - t) * 1000
print("   %.0f ms" % ms)
sys.exit(0 if r.returncode == 0 and r.stdout == b"" and ms < 100 else 1)
PY

# (b) non-blocking event lands in the events file
echo "$PRE" | "$HOOK"
L="$HOME/.peek/events/sid-pre.jsonl"
if [ -f "$L" ] && [ "$(wc -l < "$L")" -eq 1 ] && python3 -c 'import json,sys; o=json.loads(open(sys.argv[1]).readline()); sys.exit(0 if o["ev"]=="PreToolUse" and o["sid"]=="sid-pre" and o["tool_name"]=="Read" else 1)' "$L"; then
  ok "(b) event line written"
else bad "(b) event line"; fi

# (c) stub socket replies allow -> documented decision JSON; second request replies "always" -> recorded
SOCK="$HOME/.peek/peek.sock"
python3 - "$SOCK" <<'PY' &
import os, socket, sys
p = sys.argv[1]
try: os.unlink(p)
except OSError: pass
s = socket.socket(socket.AF_UNIX); s.bind(p); s.listen(4)
for verb in ("allow", "always"):
    c, _ = s.accept()
    buf = b""
    while not buf.endswith(b"\n"): buf += c.recv(65536)
    c.sendall((verb + "\n").encode()); c.close()
PY
STUB=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK" ] && break; sleep 0.2; done
OUT="$(echo "$PERM" | "$HOOK")"
WANT='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
[ "$OUT" = "$WANT" ] && ok "(c) stub allow -> decision JSON" || bad "(c) got: $OUT"
echo "$PERM" | "$HOOK" >/dev/null
grep -q '"Bash:npm"' "$HOME/.peek/always.json" 2>/dev/null && ok "(c) always recorded" || bad "(c) always.json missing"
wait $STUB 2>/dev/null
OUT="$(echo "$PERM" | "$HOOK")"   # socket gone but always rule now answers without the app
[ "$OUT" = "$WANT" ] && ok "(c) always rule answers offline" || bad "(c) always rule: $OUT"

# (d) install twice -> one Peek group per event; uninstall restores byte-identical
mkdir -p "$HOME/.claude"
python3 - <<'PY'
import json, os
d = {"model": "opus", "statusLine": {"type": "command", "command": "echo orig-statusline", "padding": 1},
     "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo user-hook"}]}],
               "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "echo old", "statusMessage": "notch", "async": True}]}]}}
open(os.path.expanduser("~/.claude/settings.json"), "w").write(json.dumps(d, indent=4) + "  \n")  # deliberately not canonical
PY
cp "$HOME/.claude/settings.json" "$FAKE/orig.json"
export PEEK_NO_LAUNCHD=1 PEEK_SKIP_BUILD=1
"$ROOT/install.sh" --yes >/dev/null && "$ROOT/install.sh" --yes >/dev/null || bad "(d) install failed"
python3 - <<'PY' && ok "(d) one Peek group per event, user hooks and statusline wrapped" || bad "(d) group count"
import json, os
d = json.load(open(os.path.expanduser("~/.claude/settings.json")))
evs = ["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","Notification","PreCompact","PostCompact",
       "SubagentStart","SubagentStop","Stop","StopFailure","SessionEnd","PermissionRequest"]
for e in evs:
    n = sum(1 for g in d["hooks"][e] for x in g["hooks"] if x.get("statusMessage") == "peek")
    assert n == 1, (e, n)
assert any(x.get("command") == "echo user-hook" for g in d["hooks"]["PreToolUse"] for x in g["hooks"])
assert any(x.get("statusMessage") == "notch" for g in d["hooks"]["Stop"] for x in g["hooks"])
assert d["hooks"]["PermissionRequest"][0]["hooks"][0]["timeout"] == 120
assert d["statusLine"]["command"].endswith("peek-hook --statusline") and d["statusLine"]["padding"] == 1
assert d["model"] == "opus"
assert open(os.path.expanduser("~/.peek/prev-statusline")).read() == "echo orig-statusline"
PY
echo '{"session_id":"sid-sl","context_window":{"used_percentage":37.2},"session_name":"nm"}' | "$HOME/.peek/bin/peek-hook" --statusline > "$FAKE/sl.out"
[ "$(cat "$FAKE/sl.out")" = "orig-statusline" ] && grep -q '"ctx":37' "$HOME/.peek/status/sid-sl.json" && ok "(d) statusline tee + passthrough" || bad "(d) statusline"
"$ROOT/uninstall.sh" >/dev/null || bad "(d) uninstall failed"
cmp -s "$FAKE/orig.json" "$HOME/.claude/settings.json" && ok "(d) uninstall restored byte-identical" || bad "(d) restore differs"

# (e) uninstall after settings.json was edited by someone else: Peek entries go, the edit stays
"$ROOT/install.sh" --yes >/dev/null
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json"); d = json.load(open(p)); d["extra"] = 1
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
"$ROOT/uninstall.sh" >/dev/null
python3 - "$FAKE/orig.json" <<'PY' && ok "(e) in-place removal keeps later edits" || bad "(e) in-place removal"
import json, os, sys
a = json.load(open(sys.argv[1])); b = json.load(open(os.path.expanduser("~/.claude/settings.json")))
assert b.pop("extra") == 1 and a == b, (a, b)
PY

[ $FAIL -eq 0 ] && echo "SMOKE PASS" || { echo "SMOKE FAIL"; exit 1; }
