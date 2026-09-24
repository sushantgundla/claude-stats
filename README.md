# claudecost

See what your Claude Code usage would cost at API prices: tokens, cache hits and misses,
models, tools, MCP servers, skills and slash commands. Compare days, weeks (including your
Pro/Max quota week), months or years side by side, in the terminal or as an HTML report.

One bash script. Nothing to install. Everything stays on your machine.

## Install

```bash
curl -O https://raw.githubusercontent.com/sushantgundla/claudecost/main/claudecost.sh
chmod +x claudecost.sh
```

## Quick start

```bash
./claudecost.sh --days 7                        # the last 7 days
./claudecost.sh --reset "wed 23:30" --weeks 2   # your last 2 quota weeks, side by side
./claudecost.sh --reset "wed 23:30" --html report.html && open report.html
```

`--reset` is the weekday and local time your weekly limit resets. Find it on claude.ai
under **Settings → Usage**.

## Commands

### One time range

| Command | Shows |
| --- | --- |
| `./claudecost.sh` | All history |
| `./claudecost.sh --days 7` | Last 7 days |
| `./claudecost.sh --since 2026-09-01 --until 2026-09-07` | Those dates (`--until` is inclusive) |
| `./claudecost.sh --since "2026-09-16 11:30" --until "2026-09-23 11:30"` | Exact times |
| `./claudecost.sh --month 2026-08` | One calendar month |

### Compare periods (up to 5)

| Command | Compares |
| --- | --- |
| `./claudecost.sh --reset "wed 23:30" --weeks 4` | Your last 4 quota weeks |
| `./claudecost.sh --compare day --last 5` | The last 5 days |
| `./claudecost.sh --compare week --last 3` | The last 3 calendar weeks (Monday 00:00) |
| `./claudecost.sh --compare month --last 4 --current` | The last 4 months, plus this month so far |
| `./claudecost.sh --compare year --last 2 --current` | The last 2 years, plus this year so far |

- `--last N` counts complete periods; `--current` adds the one in progress. 5 at most.
- The cost chart goes one step finer than what you compare: years by month, months by
  week, weeks by day, days by hour. Change it with `--freq hourly|daily|weekly|monthly`.

### Other options

| Option | Does |
| --- | --- |
| `--html FILE` | Also write a self-contained HTML report (no internet needed to view it) |
| `--top N` | Rows in the tools, MCP, skills and commands lists (default 10) |
| `--project NAME` | Only projects whose folder name contains `NAME` |
| `--dir PATH` | Read logs from another folder (default `~/.claude/projects`) |
| `--offline` | Use built-in prices instead of downloading the latest |
| `--help` | All options |

## What you get

**In the terminal** *(example numbers)*

```
  Claude Code usage  · estimated at API list prices · pricing LiteLLM (21 models)

  ■ Week 1      Wed Sep 09 23:30 → Wed Sep 16 23:30
  ■ Week 2      Wed Sep 16 23:30 → Wed Sep 23 23:30

  Total  $806  ·  6,000 calls  ·  1.30B tokens  ·  hit rate 97.4%  ·  14 active days

  ▍Comparison

                                       Week 1               Week 2    vs prev
  ───────────────────────────────────────────────────────────────────────────
  API calls                             2,500                3,500       +40%
  Input tokens                          0.61B                0.69B       +13%
    Cache read (hit)             0.59B · $255         0.67B · $263        +3%
    Cache writes (miss)          18.0M · $125          15.0M · $89       -29%
    Cache hit rate                      97.0%                97.7%    +0.7 pt
  Output tokens                    1.5M · $33           2.1M · $41       +24%
  Est. API cost                          $413                 $393        -5%
```

…followed by where the money goes (cache read, cache write, output, input), a cost chart,
a models table, and the top tools, MCP servers, skills, slash commands and subagents for
each period.

**In the HTML report** (`--html`)

- A card per period, the comparison table, and where the money goes
- A cost chart: bars for cost, a line for API calls, hover for exact numbers
- Models: one row per model, one column per period
- Top 10 tools, MCP servers, skills, slash commands and subagents, switchable between
  "by item" and "by week" (or day, month, year)
- Light and dark mode, works offline, easy to share as a single file

## What the numbers mean

- **Cache read (hit)**: conversation already in the cache. About 0.1x the input price.
- **Cache write (miss)**: new content stored in the cache, 1.25x input for 5 minutes or 2x
  for 1 hour (Claude Code's default).
- **Not cached**: plain input at 1x. **Output** is never cached.
- Every step of a session re-sends the whole conversation, mostly from cache, so cache
  reads are usually the biggest cost.
- Costs are **API list-price estimates**, not a Pro or Max bill. Subscription limits are
  measured differently.

## How it counts

Claude Code logs a reply once per streamed block, and resumed or forked sessions copy old
messages into new files, often with new timestamps. claudecost counts each thing once:

- API calls by message id, tool and MCP calls by `tool_use` id, slash commands by message id
- For a call logged several times, the largest token count wins (early lines are partial)
- Each item is placed at its earliest timestamp, so a copied message never counts as new

The report ends with a small table showing how many log lines became how many unique
items. Because of this, totals can be lower than tools that count every line.

Prices come from [LiteLLM](https://github.com/BerriAI/litellm) on every run (`--offline`
uses built-in prices). Models without a known price are marked `*` and priced like Sonnet.

## Speed

About 4 seconds for 2 GB of logs on a recent Mac. Files are read in parallel, and `perl`
(on macOS and most Linux) pulls out just the fields needed. Without perl it falls back to
plain awk, about twice as slow.

## Settings

| Variable | Effect |
| --- | --- |
| `NO_COLOR=1` | No colours (also off automatically when output is not a terminal) |
| `FORCE_COLOR=1` | Keep colours when piping, e.g. `FORCE_COLOR=1 ./claudecost.sh \| less -R` |
| `CLAUDE_DIR` | Same as `--dir` |
| `CLAUDECOST_READER=awk` | Force the plain awk reader |

## Requirements

bash, awk, curl and perl, all included with macOS and most Linux systems.

## License

MIT
