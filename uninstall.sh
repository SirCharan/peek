#!/bin/bash
# usage: uninstall.sh   (PEEK_NO_LAUNCHD=1 skips launchctl; honours $HOME)
set -euo pipefail
LABEL=com.sircharan.peek
PEEK="$HOME/.peek"
SETTINGS="$HOME/.claude/settings.json"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "${PEEK_NO_LAUNCHD:-0}" != 1 ]; then launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true; fi
rm -f "$PLIST"

if [ -f "$SETTINGS" ]; then
  BK="$(cat "$PEEK/settings-backup" 2>/dev/null || true)"
  if [ -n "$BK" ] && [ -f "$PEEK/settings-sha" ] && [ "$(shasum -a 256 "$SETTINGS" | cut -d' ' -f1)" = "$(cat "$PEEK/settings-sha")" ] && { [ "$BK" = none ] || [ -f "$BK" ]; }; then
    # nothing touched settings.json since Peek wrote it: put the original back byte for byte
    if [ "$BK" = none ]; then rm -f "$SETTINGS"; else cp -p "$BK" "$SETTINGS"; fi
    echo "settings.json: restored from backup"
  else
    python3 - "$SETTINGS" "$PEEK/prev-statusline" <<'PY'
import json, os, sys
sp, prev = sys.argv[1:3]
MARK, STATUS = "peek", "~/.peek/bin/peek-hook --statusline"
d = json.load(open(sp))
h = d.get("hooks", {})
for ev in list(h):
    for g in h[ev]: g["hooks"] = [x for x in g.get("hooks", []) if x.get("statusMessage") != MARK]
    h[ev] = [g for g in h[ev] if g.get("hooks") or "hooks" not in g]
    if not h[ev]: del h[ev]
if not h: d.pop("hooks", None)
sl = d.get("statusLine")
if isinstance(sl, dict) and sl.get("command") == STATUS:
    p = open(prev).read() if os.path.exists(prev) else ""
    if p: sl["command"] = p
    else: del d["statusLine"]
open(sp, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
    echo "settings.json: Peek entries removed (file changed since install, so edited in place)"
  fi
fi
rm -rf "$PEEK/bin" "$PEEK/prev-statusline" "$PEEK/settings-sha" "$PEEK/settings-backup" "$PEEK/peek.sock"
echo "uninstalled $LABEL (kept $PEEK/events, status, always.json and the settings backup)"
