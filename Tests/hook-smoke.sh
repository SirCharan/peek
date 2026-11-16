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

# (c) stub socket: allow -> plain decision JSON; always (with a permission_suggestion) -> allow + updatedPermissions; ExitPlanMode allow echoes input
SOCK="$HOME/.peek/peek.sock"
python3 - "$SOCK" <<'PY' &
import os, socket, sys, json
p = sys.argv[1]
try: os.unlink(p)
except OSError: pass
s = socket.socket(socket.AF_UNIX); s.bind(p); s.listen(4)
for verb in ("allow", "always", "always", "allow"):
    c, _ = s.accept()
    buf = b""
    while not buf.endswith(b"\n"): buf += c.recv(65536)
    ev = json.loads(buf)
    if verb == "always" and "always" not in ev: verb = "allow"   # no suggestion -> the hook offers no Always; reply anyway
    c.sendall((verb + "\n").encode()); c.close()
PY
STUB=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK" ] && break; sleep 0.2; done
OUT="$(echo "$PERM" | "$HOOK")"
WANT='{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}'
[ "$OUT" = "$WANT" ] && ok "(c) stub allow -> decision JSON" || bad "(c) got: $OUT"
PERMS='{"session_id":"sid-perm","cwd":"/w","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test"}],"behavior":"allow","destination":"localSettings"}]}'
OUT="$(echo "$PERMS" | "$HOOK")"
python3 - "$OUT" <<'PY' && ok "(c) always -> allow + updatedPermissions from the suggestion" || bad "(c) always got: $OUT"
import json, sys
o = json.loads(sys.argv[1])["hookSpecificOutput"]
assert o["hookEventName"] == "PermissionRequest" and o["decision"] == {"behavior": "allow", "updatedPermissions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "npm test"}], "behavior": "allow", "destination": "localSettings"}]}, o
PY
OUT="$(echo "$PERM" | "$HOOK")"   # no permission_suggestions: always degrades to a plain allow
[ "$OUT" = "$WANT" ] && ok "(c) always without suggestions -> plain allow" || bad "(c) degrade got: $OUT"
[ -f "$HOME/.peek/always.json" ] && bad "(c) always.json must not exist" || ok "(c) no always.json"
PLAN='{"session_id":"sid-perm","cwd":"/w","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{"plan":"## P","planFilePath":"/p.md"}}'
OUT="$(echo "$PLAN" | "$HOOK")"
python3 - "$OUT" <<'PY' && ok "(c) ExitPlanMode allow echoes updatedInput" || bad "(c) plan got: $OUT"
import json, sys
d = json.loads(sys.argv[1])["hookSpecificOutput"]["decision"]
assert d == {"behavior": "allow", "updatedInput": {"plan": "## P", "planFilePath": "/p.md"}}, d
PY
wait $STUB 2>/dev/null

# (c2) --ask: stub answers -> documented PreToolUse JSON; hang-up -> empty stdout
rm -f "$SOCK"   # the previous stub's socket file is stale; wait for the new bind below
ASK='{"session_id":"sid-ask","cwd":"/w","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React","description":"Component library"},{"label":"Vue","description":"Progressive framework"}],"multiSelect":false}]}}'
python3 - "$SOCK" <<'PY' &
import os, socket, sys, json
p = sys.argv[1]
try: os.unlink(p)
except OSError: pass
s = socket.socket(socket.AF_UNIX); s.bind(p); s.listen(4)
c, _ = s.accept()
buf = b""
while not buf.endswith(b"\n"): buf += c.recv(65536)
ev = json.loads(buf)
assert ev["ev"] == "AskUserQuestion" and ev["tool_input"]["questions"][0]["question"] == "Which framework?", ev
c.sendall(b'{"Which framework?":"React"}\n'); c.close()
c, _ = s.accept()
while not c.recv(65536).endswith(b"\n"): pass
c.close()   # hang up without answering
PY
STUB=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK" ] && break; sleep 0.2; done
OUT="$(echo "$ASK" | "$HOOK" --ask)"
python3 - "$OUT" <<'PY' && ok "(c2) --ask answer -> documented PreToolUse JSON" || bad "(c2) got: $OUT"
import json, sys
q = [{"question": "Which framework?", "header": "Framework", "options": [{"label": "React", "description": "Component library"}, {"label": "Vue", "description": "Progressive framework"}], "multiSelect": False}]
want = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": {"questions": q, "answers": {"Which framework?": "React"}}}}
assert json.loads(sys.argv[1]) == want
PY
OUT="$(echo "$ASK" | "$HOOK" --ask)"
[ -z "$OUT" ] && ok "(c2) --ask hang-up -> empty stdout" || bad "(c2) hang-up got: $OUT"
wait $STUB 2>/dev/null
OUT="$(echo "$ASK" | "$HOOK" --ask)"
[ -z "$OUT" ] && ok "(c2) --ask no socket -> empty stdout" || bad "(c2) no-socket got: $OUT"

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
python3 - <<'PY' && ok "(d) one Peek group per event (+ exactly one --ask group), user hooks and statusline wrapped" || bad "(d) group count"
import json, os
d = json.load(open(os.path.expanduser("~/.claude/settings.json")))
evs = ["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","Notification","PreCompact","PostCompact",
       "SubagentStart","SubagentStop","Stop","StopFailure","SessionEnd","PermissionRequest"]
for e in evs:
    n = sum(1 for g in d["hooks"][e] for x in g["hooks"] if x.get("statusMessage") == "peek")
    assert n == (2 if e == "PreToolUse" else 1), (e, n)
asks = [(g, x) for g in d["hooks"]["PreToolUse"] for x in g["hooks"] if x.get("command", "").endswith("peek-hook --ask")]
assert len(asks) == 1 and asks[0][0]["matcher"] == "AskUserQuestion" and asks[0][1]["timeout"] == 130 and asks[0][1]["statusMessage"] == "peek" and "async" not in asks[0][1], asks
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
