#!/bin/bash
# notch-tasks hook: events -> ~/.claude/notch-events/<sid>.jsonl; PermissionRequest -> perm file + reply poll
D="$HOME/.claude/notch-events"
mkdir -p "$D/perm" "$D/ctx"
IN=$(cat)
OUT=$(printf '%s' "$IN" | jq -r '
  def tgt: (.tool_input // {}) as $i
    | (if ($i.file_path // "") != "" then ($i.file_path | split("/") | last)
       elif ($i.command // "") != "" then ($i.command | gsub("\n"; " ") | .[0:60])
       else ($i.pattern // $i.url // $i.description // "" | tostring | .[0:60]) end);
  .session_id // "", ((now*1000|floor|tostring) + " " + .hook_event_name),
  ({t:(now*1000|floor), ev:.hook_event_name, tool:(.tool_name // ""), target:tgt,
    ntype:(.notification_type // ""), msg:((.message // "")[0:200]),
    last:((.last_assistant_message // "")[0:300])} | tojson)' 2>/dev/null) || exit 0
{ read -r SID; read -r META; read -r LINE; } <<<"$OUT"
[ -z "$SID" ] && exit 0
MS=${META%% *}; EV=${META#* }
if [ "$EV" = "PermissionRequest" ]; then
  P="$D/perm/$SID-$MS"
  printf '%s' "$IN" | jq -c '{session_id, tool_name, target:((.tool_input // {}) as $i | if ($i.file_path // "") != "" then ($i.file_path|split("/")|last) else (($i.command // "")|gsub("\n";" ")|.[0:60]) end),
    command:(.tool_input.command // null), file_path:(.tool_input.file_path // null), suggestions:(.permission_suggestions // [])}' > "$P.json.tmp" && mv "$P.json.tmp" "$P.json"
  i=0
  while [ $i -lt 550 ]; do
    if [ -f "$P.reply" ]; then
      R=$(cat "$P.reply"); rm -f "$P.json" "$P.reply"
      case "$R" in
        allow) echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' ;;
        deny*) jq -nc --arg m "${R#deny:}" '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:(if $m == "" or $m == "deny" then "Denied from the notch" else $m end)}}}' ;;
        always) printf '%s' "$IN" | jq -c '
          (.permission_suggestions // [])[0] as $s
          | (.tool_input.command // "" | split(" ")[0]) as $w
          | (if $s then ($s + {destination:"session"})
             else {type:"addRules", behavior:"allow", destination:"session",
                   rules:[{toolName:.tool_name} + (if .tool_name == "Bash" and $w != "" then {ruleContent:($w + ":*")} else {} end)]} end) as $u
          | {hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow",updatedPermissions:[$u]}}}' ;;
      esac
      exit 0
    fi
    sleep 0.2; i=$((i+1))
  done
  rm -f "$P.json"
  exit 0
fi
F="$D/$SID.jsonl"
echo "$LINE" >> "$F"
if [ "$(wc -l < "$F")" -gt 400 ]; then tail -n 200 "$F" > "$F.tmp" && mv "$F.tmp" "$F"; fi
exit 0
