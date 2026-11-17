# slack-to-dstask

React to a Slack message with a trigger emoji (default `:tornado:`) and it becomes a [dstask](https://github.com/naggie/dstask) todo.

No Slack app to install: it polls Slack through the Claude Code Slack connector you already have, so it needs no workspace admin approval.

## Prerequisites

| Tool | Needed for | Install |
|---|---|---|
| [dstask](https://github.com/naggie/dstask) | required, the todo store | `brew install naggie/tap/dstask` |
| [Claude Code](https://claude.com/claude-code) with the Slack connector authorized | required, the search step | see Claude Code docs |
| `jq` | required | `brew install jq` |
| [SwiftBar](https://github.com/swiftbar/SwiftBar) | optional, the menu bar indicator | `brew install --cask swiftbar` |

Without SwiftBar everything still works from the command line. The menu bar plugin is an add-on, see [Menu bar (SwiftBar)](#menu-bar-swiftbar).

## How it works

1. `claude -p` (Haiku by default) runs `prompt.md`, which searches `hasmy::<emoji>: after:<date>`, reads the reactions on each hit (`slack_get_reactions`), works out what the message means for you, and returns a JSON array including an actionable `todo` line and the reactions. This is the only non-deterministic step, and it can only call the Slack search tool.
2. `lib/normalize.jq` validates the items, strips Slack markup, uses the `todo` line as the title (falls back to the message's first line), truncates it, and neutralizes anything dstask would parse as a command (`+tag`, `project:x`, `P0`, `/`, `--`).
3. `bin/slack-to-dstask` skips messages already in `state/seen.json`, runs `dstask add <title> <tags> / <permalink> (<author> in #<channel>)`, records the message as seen only after dstask succeeded, then runs `dstask sync` once.
4. Every run appends a record to `state/runs.jsonl`: cost, tokens, turns, counts. Dry runs are logged too (`dry_run: true`).

Only the title, permalink, author, channel and the other reactions (e.g. `reactions: eyes:3`) go into dstask. The message body is never stored.

## Usage

```bash
bin/slack-to-dstask --dry-run          # show what would be added, nothing written to dstask
bin/slack-to-dstask                    # for real
bin/cost-report                        # totals per day
bin/cost-report --no-dry-run --since 2026-11-01
bin/cost-report --csv > runs.csv       # for a spreadsheet
tests/run.sh                           # offline tests, fake claude and dstask
```

## Menu bar (SwiftBar)

A [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin shows your open dstask count in the menu bar (red when you have P0/P1 tasks, ▶︎ when one is started, ⟳ while a fetch runs).

```bash
brew install --cask swiftbar            # once, then pick a plugin folder on first launch
bin/install-swiftbar                    # symlinks swiftbar/dstask.1m.sh into that folder
bin/install-swiftbar ~/swiftbar-plugins # or pass the folder yourself
```

Dropdown: top tasks (started first, then by priority; click opens the Slack link), a Done/Start/Stop submenu per task, **Fetch from Slack now**, and an **Auto-fetch** toggle. The fetch runs `bin/slack-to-dstask` in the background and logs to `state/swiftbar-fetch.log`.

Auto-fetch is a flag file (`state/autofetch.enabled`), not a SwiftBar disable, so the indicator stays visible. The plugin refreshes every minute (from the filename; a local dstask read only, no Slack call) and starts a fetch when the last one is older than `AUTOFETCH_MINUTES` (default 15). Every fetch costs tokens, so check `ds-cost` after enabling it. Set `AUTOFETCH_MINUTES` and `MAX_LISTED` (default 15) in SwiftBar's plugin environment variables.

## Shell shortcuts

Add this to `~/.zshrc` to run everything from any directory. If you already have a `ds-fetch` function there, replace it with this block.

```zsh
export SLACK_TO_DSTASK_HOME="$HOME/sideprojects/slack-to-dstask"

ds-fetch()   { "$SLACK_TO_DSTASK_HOME/bin/slack-to-dstask" "$@"; }
ds-preview() { ds-fetch --dry-run "$@"; }
ds-cost()    { "$SLACK_TO_DSTASK_HOME/bin/cost-report" "$@"; }
ds-runs()    { tail -n "${1:-10}" "$SLACK_TO_DSTASK_HOME/state/runs.jsonl" \
                 | jq -r '[.ts, .status, (if .dry_run then "dry" else "real" end), "$\((.cost_usd // 0) * 10000 | round / 10000)", "added=\(.added)"] | join("  ")'; }
ds-seen()    { jq -r 'to_entries | sort_by(.value.imported_at)[] | "\(.value.imported_at)  \(.value.title)\n    \(.value.permalink // "(no link)")"' \
                 "$SLACK_TO_DSTASK_HOME/state/seen.json" | tail -n "$(( ${1:-20} * 2 ))"; }
ds-test()    { "$SLACK_TO_DSTASK_HOME/tests/run.sh"; }
```

| Command | What it does |
|---|---|
| `ds-fetch [flags]` | import reacted messages into dstask, takes every flag from above |
| `ds-preview [flags]` | same as `ds-fetch --dry-run` |
| `ds-cost [flags]` | token cost report, e.g. `ds-cost --since 2026-11-01`, `ds-cost --csv` |
| `ds-runs [N]` | last N runs (default 10): time, status, dry or real, cost, tasks added |
| `ds-seen [N]` | last N imported messages (default 20) with the Slack link, to see what was already picked up and clear the emoji by hand |
| `ds-test` | run the offline test suite |

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

- The search step is restricted with `--allowedTools` plus a `--disallowedTools` list that blocks the built-in tools and every Slack write tool. The search step may only call the search and `slack_get_reactions` tools. If your `settings.json` allows `mcp__claude_ai_Slack__*`, keep that denylist current when the connector gains tools.
- Slack message text is untrusted input. It is treated as data in the prompt, validated in `normalize.jq`, and never passed to a shell.
- A failed `dstask add` is not marked as seen, so it is retried on the next run.
- Runs are serialized with a lock directory in `state/`.

## Exit codes

`0` ok, `2` search step failed or returned unparseable output (nothing imported), `3` another run in progress, `4` a `dstask add` or `sync` failed, `64` bad arguments.
