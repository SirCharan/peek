#!/bin/bash
# notch-tasks statusline tap: records context % per session, then runs the original statusline command.
D="$HOME/.claude/notch-events/ctx"
mkdir -p "$D"
ORIG=$(cat <<'NOTCH_ORIG_EOF'
input=$(cat); dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd'); model=$(echo "$input" | jq -r '.model.display_name'); used=$(echo "$input" | jq -r '.context_window.used_percentage // empty'); ctx=""; [ -n "$used" ] && ctx=" | ctx:$(printf '%.0f' "$used")%"; printf "\033[36m%s@%s\033[0m \033[33m%s\033[0m | \033[32m%s\033[0m%s" "$(whoami)" "$(hostname -s)" "$dir" "$model" "$ctx"
NOTCH_ORIG_EOF
)
tee >(jq -r '"\(.session_id // "") \(.context_window.used_percentage // "")"' 2>/dev/null | { read -r sid pct; [ -n "$sid" ] && [ -n "$pct" ] && printf '%.0f\n' "$pct" > "$D/$sid"; }) | bash -c "$ORIG"
