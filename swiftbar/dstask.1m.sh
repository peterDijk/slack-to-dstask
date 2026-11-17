#!/usr/bin/env bash
# <xbar.title>dstask</xbar.title>
# <xbar.desc>dstask todos in the menu bar, with Slack fetch and optional auto-fetch</xbar.desc>
# <xbar.dependencies>dstask,jq</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>false</swiftbar.hideLastUpdated>

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

resolve() {
  local f="$1"
  while [ -L "$f" ]; do
    local d t
    d="$(cd "$(dirname "$f")" && pwd)"
    t="$(readlink "$f")"
    case "$t" in /*) f="$t" ;; *) f="$d/$t" ;; esac
  done
  printf '%s/%s' "$(cd "$(dirname "$f")" && pwd)" "$(basename "$f")"
}

SELF="$(resolve "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
STATE_DIR="${STATE_DIR:-$ROOT/state}"
AUTO_FLAG="$STATE_DIR/autofetch.enabled"
LAST_FETCH="$STATE_DIR/swiftbar-last-fetch"
FETCH_LOG="$STATE_DIR/swiftbar-fetch.log"
AUTOFETCH_MINUTES="${AUTOFETCH_MINUTES:-15}"
MAX_LISTED="${MAX_LISTED:-15}"
mkdir -p "$STATE_DIR"

run_fetch() {
  date +%s >"$LAST_FETCH"
  { echo "--- $(date '+%F %T')"; "$ROOT/bin/slack-to-dstask"; echo "exit=$?"; } >>"$FETCH_LOG" 2>&1
  tail -n 300 "$FETCH_LOG" >"$FETCH_LOG.tmp" && mv "$FETCH_LOG.tmp" "$FETCH_LOG"
}

fetch_running() { [ -d "$STATE_DIR/lock.d" ] && kill -0 "$(cat "$STATE_DIR/lock.d/pid" 2>/dev/null)" 2>/dev/null; }

case "${1:-}" in
  fetch) run_fetch; exit 0 ;;
  toggle-auto)
    if [ -f "$AUTO_FLAG" ]; then rm -f "$AUTO_FLAG"; else : >"$AUTO_FLAG"; fi
    exit 0 ;;
  done) dstask "$2" done >/dev/null 2>&1; dstask sync >/dev/null 2>&1; exit 0 ;;
  start) dstask "$2" start >/dev/null 2>&1; exit 0 ;;
  stop) dstask "$2" stop >/dev/null 2>&1; exit 0 ;;
esac

if [ -f "$AUTO_FLAG" ] && ! fetch_running; then
  last="$(cat "$LAST_FETCH" 2>/dev/null || echo 0)"
  if [ $(( $(date +%s) - last )) -ge $(( AUTOFETCH_MINUTES * 60 - 30 )) ]; then
    nohup "$SELF" fetch >/dev/null 2>&1 &
  fi
fi

if ! command -v dstask >/dev/null || ! command -v jq >/dev/null; then
  echo "dstask ⚠️"; echo "---"; echo "dstask or jq not found in PATH"; exit 0
fi

TASKS="$(dstask show-open 2>/dev/null)"
if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$TASKS"; then
  echo "dstask ⚠️"; echo "---"; echo "could not read dstask output"; exit 0
fi

PENDING="$(jq '[.[] | select(.status != "resolved")] | length' <<<"$TASKS")"
ACTIVE="$(jq '[.[] | select(.status == "active")] | length' <<<"$TASKS")"
URGENT="$(jq '[.[] | select(.status != "resolved" and (.priority == "P0" or .priority == "P1"))] | length' <<<"$TASKS")"

ICON="☑︎"
[ "$ACTIVE" -gt 0 ] && ICON="▶︎"
fetch_running && ICON="⟳"
if [ "$URGENT" -gt 0 ]; then
  echo "$ICON $PENDING | color=#ff453a"
else
  echo "$ICON $PENDING"
fi

echo "---"
echo "dstask: $PENDING open, $ACTIVE active | size=12"
echo "---"

jq -r --argjson max "$MAX_LISTED" '
  def rank: {"P0":0,"P1":1,"P2":2,"P3":3}[.priority] // 2;
  [.[] | select(.status != "resolved")]
  | sort_by([(if .status == "active" then 0 else 1 end), rank, .created])
  | .[0:$max][]
  | [.id, .status, .priority, (.summary | gsub("[|\n]"; " ")),
     ((.notes // "") | capture("(?<u>https?://[^\\s)]+)").u? // "")]
  | @tsv' <<<"$TASKS" | while IFS=$'\t' read -r id status prio summary url; do
  prefix=""
  [ "$status" = "active" ] && prefix="▶︎ "
  [ "$prio" = "P0" ] || [ "$prio" = "P1" ] && prefix="${prefix}❗"
  if [ -n "$url" ]; then
    echo "$prefix$summary | href=$url"
  else
    echo "$prefix$summary"
  fi
  echo "--Done | bash=$SELF param1=done param2=$id terminal=false refresh=true"
  if [ "$status" = "active" ]; then
    echo "--Stop | bash=$SELF param1=stop param2=$id terminal=false refresh=true"
  else
    echo "--Start | bash=$SELF param1=start param2=$id terminal=false refresh=true"
  fi
done

[ "$PENDING" -gt "$MAX_LISTED" ] && echo "… and $((PENDING - MAX_LISTED)) more"

echo "---"
if fetch_running; then
  echo "Fetching from Slack… | color=gray"
else
  echo "Fetch from Slack now | bash=$SELF param1=fetch terminal=false refresh=true"
fi

if [ -f "$AUTO_FLAG" ]; then
  echo "Auto-fetch every ${AUTOFETCH_MINUTES}m | checked=true bash=$SELF param1=toggle-auto terminal=false refresh=true"
else
  echo "Auto-fetch off | bash=$SELF param1=toggle-auto terminal=false refresh=true"
fi
echo "Open fetch log | bash=/usr/bin/open param1=-a param2=Console param3=$FETCH_LOG terminal=false"
