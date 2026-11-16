#!/bin/bash
# usage: install.sh [--yes]
# Builds Peek, installs ~/.peek/bin/peek-hook, merges Peek's hooks into ~/.claude/settings.json (diff + y/N), installs the LaunchAgent.
# Env: PEEK_NO_LAUNCHD=1 skips launchctl; PEEK_SKIP_BUILD=1 reuses an existing .build/release (both for tests).
set -euo pipefail
YES=0; [ "${1:-}" = "--yes" ] && YES=1
LABEL=com.sircharan.peek
DIR="$(cd "$(dirname "$0")" && pwd)"
PEEK="$HOME/.peek"
SETTINGS="$HOME/.claude/settings.json"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
command -v python3 >/dev/null || { echo "python3 is required (it edits settings.json)"; exit 1; }

if [ "${PEEK_SKIP_BUILD:-0}" != 1 ]; then
  command -v swift >/dev/null || { echo "swift not found: install Xcode or the Command Line Tools"; exit 1; }
  (cd "$DIR" && swift build -c release 2>&1 | tail -3)
fi
[ -x "$DIR/.build/release/peek-hook" ] && [ -x "$DIR/.build/release/Peek" ] || { echo "build products missing in $DIR/.build/release"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$HOME/.claude"
python3 - "$SETTINGS" "$TMP" <<'PY' || exit 1
import json, os, sys
sp, tmp = sys.argv[1:3]
MARK = "peek"
HOOK = "~/.peek/bin/peek-hook"
STATUS = HOOK + " --statusline"
ASYNC = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification",
         "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Stop", "StopFailure", "SessionEnd"]
def die(m): print("refusing to edit %s: %s" % (sp, m)); sys.exit(2)
d = {}
if os.path.exists(sp):
    try: d = json.load(open(sp))
    except Exception as e: die("not valid JSON (%s)" % e)
if not isinstance(d, dict): die("top level is not an object")
h = d.get("hooks", {})
if not isinstance(h, dict): die('"hooks" is not an object')
for ev, groups in h.items():
    if not isinstance(groups, list): die('hooks.%s is not a list' % ev)
    for g in groups:
        if not isinstance(g, dict) or not isinstance(g.get("hooks", []), list): die('hooks.%s has an unknown shape' % ev)
        if any(not isinstance(x, dict) for x in g.get("hooks", [])): die('hooks.%s has an unknown shape' % ev)
sl = d.get("statusLine")
if sl is not None and (not isinstance(sl, dict) or not isinstance(sl.get("command", ""), str)): die('"statusLine" has an unknown shape')
# drop previous Peek entries, then add one fresh group per event
for ev in list(h):
    for g in h[ev]: g["hooks"] = [x for x in g.get("hooks", []) if x.get("statusMessage") != MARK]
    h[ev] = [g for g in h[ev] if g.get("hooks") or "hooks" not in g]
    if not h[ev]: del h[ev]
for ev in ASYNC + ["PermissionRequest"]:
    c = {"type": "command", "command": HOOK, "statusMessage": MARK}
    if ev == "PermissionRequest": c["timeout"] = 120
    else: c.update({"timeout": 5, "async": True})
    h.setdefault(ev, []).append({"matcher": "", "hooks": [c]})
# AskUserQuestion answered from the notch: blocking PreToolUse (the async PreToolUse group above only logs it)
h.setdefault("PreToolUse", []).append({"matcher": "AskUserQuestion", "hooks": [{"type": "command", "command": HOOK + " --ask", "timeout": 130, "statusMessage": MARK}]})
d["hooks"] = h
if sl is not None and sl.get("command") == STATUS: pass
elif sl is not None and "command" in sl:
    open(os.path.join(tmp, "prev"), "w").write(sl["command"])
    d["statusLine"] = dict(sl, command=STATUS)
elif sl is not None: die('"statusLine" has no command')
else: d["statusLine"] = {"type": "command", "command": STATUS}
open(os.path.join(tmp, "new"), "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY

OLD="$SETTINGS"; [ -f "$SETTINGS" ] || OLD=/dev/null
if cmp -s "$OLD" "$TMP/new"; then
  echo "settings.json: already up to date"
else
  diff -u "$OLD" "$TMP/new" || true
  if [ "$YES" != 1 ]; then
    read -r -p "Write these changes to $SETTINGS? [y/N] " a
    case "$a" in y|Y|yes) ;; *) echo "aborted, nothing changed"; exit 1 ;; esac
  fi
fi

mkdir -p "$PEEK/bin" "$PEEK/events" "$PEEK/status"
cp "$DIR/.build/release/peek-hook" "$PEEK/bin/peek-hook.new" && mv "$PEEK/bin/peek-hook.new" "$PEEK/bin/peek-hook"
if ! cmp -s "$OLD" "$TMP/new"; then
  # first install only: remember the pre-Peek file so uninstall can restore it byte for byte
  if [ ! -f "$PEEK/settings-backup" ]; then
    if [ -f "$SETTINGS" ]; then
      mkdir -p "$HOME/.claude/backups"
      BK="$HOME/.claude/backups/settings-pre-peek-$(date +%Y%m%d-%H%M%S).json"
      cp -p "$SETTINGS" "$BK"; echo "$BK" > "$PEEK/settings-backup"; echo "backup: $BK"
    else echo none > "$PEEK/settings-backup"; fi
  fi
  [ -f "$TMP/prev" ] && cp "$TMP/prev" "$PEEK/prev-statusline"
  cp "$TMP/new" "$SETTINGS.peek-new" && mv "$SETTINGS.peek-new" "$SETTINGS"
  shasum -a 256 "$SETTINGS" | cut -d' ' -f1 > "$PEEK/settings-sha"
  echo "settings.json: updated"
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$DIR/.build/release/Peek</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>/tmp/peek.log</string>
<key>StandardErrorPath</key><string>/tmp/peek.log</string>
</dict></plist>
PL
if [ "${PEEK_NO_LAUNCHD:-0}" != 1 ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" && echo "installed $LABEL"
fi
