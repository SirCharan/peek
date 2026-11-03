#!/bin/bash
# usage: install.sh [uninstall]
LABEL=com.ck.notchtasks
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
HOOKS="$HOME/.claude/hooks"
EVENTS="PreToolUse PostToolUse Notification PreCompact PostCompact Stop UserPromptSubmit"

if [ "$1" = "uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  rm -f "$PLIST"
  python3 - "$SETTINGS" "$HOOKS/statusline-notch.sh" <<'PY'
import json, sys, re, os
sp, wrapper = sys.argv[1:3]
d = json.load(open(sp))
h = d.get("hooks", {})
for ev in list(h):
    h[ev] = [g for g in h[ev] if not any(x.get("statusMessage") == "notch" for x in g.get("hooks", []))]
    if not h[ev]: del h[ev]
if not h: d.pop("hooks", None)
sl = d.get("statusLine", {})
if "statusline-notch.sh" in sl.get("command", "") and os.path.exists(wrapper):
    m = re.search(r"<<'NOTCH_ORIG_EOF'\n(.*?)\nNOTCH_ORIG_EOF\n", open(wrapper).read(), re.S)
    if m: sl["command"] = m.group(1)
open(sp, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
  rm -f "$HOOKS/notch-hook.sh" "$HOOKS/statusline-notch.sh"
  echo "uninstalled $LABEL and notch hooks"
  exit 0
fi

(cd "$DIR" && swift build -c release 2>&1 | tail -3) || exit 1

# hooks step
mkdir -p "$HOOKS" "$HOME/.claude/notch-events/perm" "$HOME/.claude/notch-events/ctx" "$HOME/.claude/backups"
cp "$DIR/hooks/notch-hook.sh" "$DIR/hooks/statusline-notch.sh" "$HOOKS/" && chmod +x "$HOOKS"/notch-hook.sh "$HOOKS"/statusline-notch.sh
BK="$HOME/.claude/backups/settings-pre-notch-$(date +%Y%m%d-%H%M%S).json"
python3 - "$SETTINGS" "$BK" "$EVENTS" <<'PY'
import json, sys, shutil
sp, bk, evs = sys.argv[1], sys.argv[2], sys.argv[3].split()
raw = open(sp).read()
d = json.loads(raw)
h = d.setdefault("hooks", {})
def has(ev): return any(x.get("statusMessage") == "notch" for g in h.get(ev, []) for x in g.get("hooks", []))
todo = [e for e in evs + ["PermissionRequest"] if not has(e)]
sl = d.setdefault("statusLine", {"type": "command"})
swap = "statusline-notch.sh" not in sl.get("command", "")
if not todo and not swap:
    print("hooks: already installed"); sys.exit(0)
shutil.copy(sp, bk)
for ev in todo:
    cmd = {"type": "command", "command": "bash ~/.claude/hooks/notch-hook.sh", "statusMessage": "notch"}
    if ev == "PermissionRequest": cmd["timeout"] = 120
    else: cmd.update(async_=True, timeout=5)
    if "async_" in cmd: cmd["async"] = cmd.pop("async_")
    h.setdefault(ev, []).append({"matcher": "", "hooks": [cmd]})
if swap: sl["command"] = "bash ~/.claude/hooks/statusline-notch.sh"
open(sp, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
print("hooks: installed (backup " + bk + ")")
PY

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$DIR/.build/release/NotchTasks</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>/tmp/notchtasks.log</string>
<key>StandardErrorPath</key><string>/tmp/notchtasks.log</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST" && echo "installed $LABEL"
