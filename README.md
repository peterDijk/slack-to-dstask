# slack-to-dstask

React to a Slack message with a trigger emoji (default `:tornado:`) and it becomes a [dstask](https://github.com/naggie/dstask) todo.

No Slack app to install: it polls Slack through the Claude Code Slack connector you already have, so it needs no workspace admin approval.

## How it works

1. `claude -p` (Haiku by default) runs `prompt.md`, which searches `hasmy::<emoji>: after:<date>` and returns a JSON array. This is the only non-deterministic step, and it can only call the Slack search tool.
2. `lib/normalize.jq` validates the items, strips Slack markup, takes the first line as the title, truncates it, and neutralizes anything dstask would parse as a command (`+tag`, `project:x`, `P0`, `/`, `--`).
3. `bin/slack-to-dstask` skips messages already in `state/seen.json`, runs `dstask add <title> <tags> / <permalink> (<author> in #<channel>)`, records the message as seen only after dstask succeeded, then runs `dstask sync` once.
4. Every run appends a record to `state/runs.jsonl`: cost, tokens, turns, counts. Dry runs are logged too (`dry_run: true`).

Only the title, permalink, author and channel go into dstask. The message body is never stored.

## Usage

```bash
bin/slack-to-dstask --dry-run          # show what would be added, nothing written to dstask
bin/slack-to-dstask                    # for real
bin/cost-report                        # totals per day
bin/cost-report --no-dry-run --since 2026-11-01
bin/cost-report --csv > runs.csv       # for a spreadsheet
tests/run.sh                           # offline tests, fake claude and dstask
```

## Configuration

Copy `config.example.env` to `config.env`. Precedence: CLI flags > environment > `config.env` > defaults.

| Variable | Default | Flag |
|---|---|---|
| `SLACK_EMOJI` | `tornado` | `--emoji` |
| `LOOKBACK_DAYS` | `7` | `--lookback-days` |
| `MAX_PAGES` | `3` | |
| `MODEL` | `haiku` | `--model` |
| `MAX_BUDGET_USD` | `0.25` | `--max-budget-usd` |
| `TITLE_MAX` | `80` | |
| `DSTASK_TAGS` | `+slack` | `--tags` |
| `DSTASK_PROJECT` | empty | `--project` |
| `DSTASK_IGNORE_CONTEXT` | `0` | |
| `DSTASK_SYNC` | `1` | `--no-sync` |
| `STATE_DIR` | `./state` | |

## Safety

- The search step is restricted with `--allowedTools` plus a `--disallowedTools` list that blocks the built-in tools and every Slack write tool. If your `settings.json` allows `mcp__claude_ai_Slack__*`, keep that denylist current when the connector gains tools.
- Slack message text is untrusted input. It is treated as data in the prompt, validated in `normalize.jq`, and never passed to a shell.
- A failed `dstask add` is not marked as seen, so it is retried on the next run.
- Runs are serialized with a lock directory in `state/`.

## Exit codes

`0` ok, `2` search step failed or returned unparseable output (nothing imported), `3` another run in progress, `4` a `dstask add` or `sync` failed, `64` bad arguments.
