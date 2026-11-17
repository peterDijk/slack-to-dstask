#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/slack-to-dstask.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
  local name="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); echo "ok   - $name"; else FAIL=$((FAIL + 1)); echo "FAIL - $name"; fi
}

cat >"$WORK/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
[ -n "${FAKE_CLAUDE_FAIL:-}" ] && exit 1
cat "$FAKE_CLAUDE_OUTPUT"
EOF
cat >"$WORK/dstask" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DSTASK_LOG"
if [ "$1" = "add" ] && [[ "$*" == *FAILME* ]]; then exit 1; fi
exit 0
EOF
chmod +x "$WORK/claude" "$WORK/dstask"

envelope() {
  jq -n --arg result "$1" '{
    type: "result", is_error: false, result: $result, duration_api_ms: 1200, num_turns: 3,
    total_cost_usd: 0.0123, session_id: "abc",
    usage: {input_tokens: 1000, output_tokens: 200, cache_read_input_tokens: 5000, cache_creation_input_tokens: 300},
    modelUsage: {"claude-haiku-5-5": {costUSD: 0.0123}}
  }'
}

item() {
  jq -n --arg ch "$1" --arg ts "$2" --arg text "$3" --arg link "${4:-https://x.slack.com/archives/$1/p$2}" \
    '{channel_id: $ch, channel_name: "general", author: "Ann", message_ts: $ts, permalink: $link, text: $text}'
}

new_env() {
  export STATE_DIR="$WORK/state-$1"
  export FAKE_DSTASK_LOG="$WORK/dstask-$1.log"
  export FAKE_CLAUDE_OUTPUT="$WORK/out-$1.json"
  export CLAUDE_BIN="$WORK/claude"
  export DSTASK_BIN="$WORK/dstask"
  export SLACK_TO_DSTASK_CONFIG="$WORK/none.env"
  rm -rf "$STATE_DIR" "$FAKE_DSTASK_LOG"
  : >"$FAKE_DSTASK_LOG"
}
run() { "$ROOT/bin/slack-to-dstask" "$@" >"$WORK/stdout" 2>"$WORK/stderr"; }
adds() { grep -c '^add ' "$FAKE_DSTASK_LOG" || true; }

new_env dry
envelope "[$(item C1 1.1 'Review the PR please'),$(item C1 2.2 'Another one')]" >"$FAKE_CLAUDE_OUTPUT"
run --dry-run
check "dry-run exits 0" test $? -eq 0
check "dry-run adds nothing" test "$(adds)" -eq 0
check "dry-run writes no seen entries" test "$(jq 'length' "$STATE_DIR/seen.json")" -eq 0
check "dry-run still logs cost" test "$(jq -r '.cost_usd' "$STATE_DIR/runs.jsonl")" = "0.0123"
check "dry-run marked in log" test "$(jq -r '.dry_run' "$STATE_DIR/runs.jsonl")" = "true"
check "dry-run records tokens" test "$(jq -r '.input_tokens + .output_tokens' "$STATE_DIR/runs.jsonl")" -eq 1200
check "dry-run prints commands" test "$(grep -c 'would run' "$WORK/stdout")" -eq 2

new_env real
envelope "[$(item C1 1.1 'Review the PR please'),$(item C1 2.2 'Another one')]" >"$FAKE_CLAUDE_OUTPUT"
run
check "real run adds both" test "$(adds)" -eq 2
check "real run syncs once" test "$(grep -c '^sync' "$FAKE_DSTASK_LOG")" -eq 1
check "real run records seen" test "$(jq 'length' "$STATE_DIR/seen.json")" -eq 2
check "seen entry stores permalink" test "$(jq -r '.["C1:1.1"].permalink' "$STATE_DIR/seen.json")" = "https://x.slack.com/archives/C1/p1.1"
check "seen entry stores channel and author" test "$(jq -r '.["C1:1.1"] | .channel + "/" + .author' "$STATE_DIR/seen.json")" = "general/Ann"
check "tag and notes separator passed" grep -q '+slack / https://x.slack.com/archives/C1/p1.1' "$FAKE_DSTASK_LOG"
run
check "second run dedupes" test "$(adds)" -eq 2
check "second run does not sync" test "$(grep -c '^sync' "$FAKE_DSTASK_LOG")" -eq 1
check "both runs logged" test "$(wc -l <"$STATE_DIR/runs.jsonl" | tr -d ' ')" -eq 2

new_env fail
envelope "[$(item C1 1.1 'FAILME now'),$(item C1 2.2 'fine')]" >"$FAKE_CLAUDE_OUTPUT"
run
check "failed add exits 4" test $? -eq 4
check "failed add not marked seen" test "$(jq 'has("C1:1.1")' "$STATE_DIR/seen.json")" = "false"
check "good add still imported" test "$(jq 'has("C1:2.2")' "$STATE_DIR/seen.json")" = "true"

new_env bad
envelope "Sorry, I could not search." >"$FAKE_CLAUDE_OUTPUT"
run
check "non-JSON result exits 2" test $? -eq 2
check "non-JSON result imports nothing" test "$(adds)" -eq 0
check "parse error is logged with cost" test "$(jq -r '.status + " " + (.cost_usd|tostring)' "$STATE_DIR/runs.jsonl")" = "parse_error 0.0123"

new_env fence
envelope "$(printf '```json\n[%s]\n```' "$(item C1 1.1 'Fenced reply')")" >"$FAKE_CLAUDE_OUTPUT"
run
check "markdown fences tolerated" test "$(adds)" -eq 1

new_env invalid
envelope "[$(item C1 1.1 'no link' 'not-a-url'),$(item C1 2.2 'ok')]" >"$FAKE_CLAUDE_OUTPUT"
run
check "item without https permalink dropped" test "$(adds)" -eq 1
check "invalid count logged" test "$(jq -r '.invalid' "$STATE_DIR/runs.jsonl")" -eq 1

new_env inject
envelope "[$(item C1 1.1 'fix +urgent project:evil P0 / -- due:today <@U1|Bob> see <https://a.b/c|the doc>')]" >"$FAKE_CLAUDE_OUTPUT"
run
LINE="$(grep '^add ' "$FAKE_DSTASK_LOG")"
check "no injected tag" bash -c '! grep -qE "(^| )\+urgent( |$)" <<<"$1"' _ "$LINE"
check "no injected project" bash -c '! grep -qE "(^| )project:evil" <<<"$1"' _ "$LINE"
check "no injected priority" bash -c '! grep -qE "(^| )P0( |$)" <<<"$1"' _ "$LINE"
check "no injected context flag" bash -c '! grep -qE "(^| )-- " <<<"$1"' _ "$LINE"
check "only one notes separator" test "$(grep -o ' / ' <<<"$LINE" | wc -l | tr -d ' ')" -eq 1
check "slack markup resolved" grep -q '@Bob' <<<"$LINE"

new_env lock
envelope "[]" >"$FAKE_CLAUDE_OUTPUT"
mkdir -p "$STATE_DIR/lock.d"; echo $$ >"$STATE_DIR/lock.d/pid"
run
check "live lock blocks run" test $? -eq 3
check "locked run is not logged" test ! -s "$STATE_DIR/runs.jsonl"

new_env report
envelope "[$(item C1 1.1 'x')]" >"$FAKE_CLAUDE_OUTPUT"
run --dry-run; run
check "report table has total" bash -c '"$1/bin/cost-report" | grep -q TOTAL' _ "$ROOT"
check "report excludes dry runs on request" bash -c '"$1/bin/cost-report" --no-dry-run --json | jq -e "length == 1" >/dev/null' _ "$ROOT"
check "report csv has header and rows" test "$("$ROOT/bin/cost-report" --csv | wc -l | tr -d ' ')" -eq 3

new_env todo
envelope "[$(item C1 1.1 'hey can someone look at the export bug?' | jq -c '. + {todo: "Investigate export bug +urgent", reactions: ["eyes:3","tornado:1","bad emoji!:1"]}'),$(item C1 2.2 'plain text fallback')]" >"$FAKE_CLAUDE_OUTPUT"
run
check "todo line used as title" grep -q '^add Investigate export bug' "$FAKE_DSTASK_LOG"
check "todo cannot inject tag" bash -c '! grep -qE "(^| )\+urgent( |$)" "$1"' _ "$FAKE_DSTASK_LOG"
check "reactions in notes" grep -q 'reactions: eyes:3$' "$FAKE_DSTASK_LOG"
check "trigger emoji and junk reactions dropped" bash -c '! grep -qE "tornado:|bad" "$1"' _ "$FAKE_DSTASK_LOG"
check "missing todo falls back to text" grep -q '^add plain text fallback' "$FAKE_DSTASK_LOG"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
