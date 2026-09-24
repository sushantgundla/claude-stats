#!/bin/bash
# ============================================================================
# claudecost - Claude Code Usage Stats
# ============================================================================
# A zero-dependency bash alternative to `npx ccusage`.
# Reads JSONL session logs from ~/.claude/projects/ and displays:
#   - Total tokens, estimated API cost, active days, cache hit rate
#   - Daily/weekly/monthly cost chart (ASCII bar chart)
#   - Per-model table and cost split by token type (cache read/write, input, output)
#   - Side-by-side comparison of quota weeks (--reset) or any time range
#   - Top tools, MCP servers, skills, slash commands and subagents
#   - Optional self-contained HTML report (--html)
#
# Requirements: bash, awk, curl (perl, which ships with macOS and most Linux, makes it ~5x faster)
# Works on: macOS (default awk), Linux (gawk)
#
# Usage:
#   ./claudecost.sh                                   # daily view, all history
#   ./claudecost.sh --days 7                          # last 7 days
#   ./claudecost.sh --since 2026-09-17 --until 2026-09-23
#   ./claudecost.sh --since "2026-09-16 11:30" --until "2026-09-23 11:30"
#   ./claudecost.sh --reset "wed 11:30"               # compare the last 2 quota weeks
#   ./claudecost.sh --reset "wed 11:30" --weeks 4 --current
#   ./claudecost.sh --reset "wed 11:30" --html report.html
#   ./claudecost.sh --freq monthly                    # monthly chart
#   ./claudecost.sh --project my-app                  # filter by project name
#   ./claudecost.sh --offline                         # skip LiteLLM, use hardcoded pricing
#
# Pricing: fetches latest from LiteLLM on every run (falls back to hardcoded)
# Dedup strategy: API message id; the largest count per field wins, because
#   Claude Code logs one line per streamed content block and early lines carry
#   partial output_tokens. Tool calls are deduplicated by tool_use id and slash
#   commands by message uuid, since resumed sessions copy earlier lines.
# Dates: timestamps are UTC in the logs and are bucketed by local time.
# Cache writes: 1-hour writes (Claude Code's default) are priced at the 1-hour rate.
# ============================================================================

set -euo pipefail

# --- Defaults ---
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude/projects}"
DAYS=""
MONTH=""
SINCE=""
UNTIL=""
PROJECT_FILTER=""
CHART_FREQ="auto"  # auto | hourly | daily | weekly | monthly
OFFLINE=false
RESET_AT=""
COMPARE=""
LAST=2
LAST_SET=false
WEEKS_SET=false
CURRENT=false
HTML_OUT=""
TOP_N=10
LITELLM_URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

usage() {
  cat <<EOF
Usage: $0 [options]

One time range (default is all history):
  --days N              Last N days
  --since WHEN          Start, local time: YYYY-MM-DD or "YYYY-MM-DD HH:MM"
  --until WHEN          End, local time: YYYY-MM-DD (inclusive) or "YYYY-MM-DD HH:MM" (exclusive)
  --month YYYY-MM       One calendar month

Or compare up to 5 periods side by side:
  --compare UNIT        day, week, month or year (complete periods, newest last)
  --last N              How many complete periods (default 2, at most 5)
  --current             Also show the period in progress (counts toward the 5)
  --reset "DAY HH:MM"   Weekly boundary, e.g. your subscription reset "wed 23:30".
                        Implies --compare week. Weeks otherwise start Monday 00:00.
  --weeks N             Same as --compare week --last N

Output:
  --html FILE           Also write a self-contained HTML report to FILE
  --top N               Rows in the tools/MCP/skills/commands lists (default 10)
  --freq FREQ           Chart step: auto (default), hourly, daily, weekly, monthly.
                        Auto is one level below the comparison: year→month,
                        month→week, week→day, day→hour.

Other:
  --project PATTERN     Filter by project folder name (substring match)
  --dir PATH            Custom log directory (default: ~/.claude/projects)
  --offline             Skip LiteLLM fetch, use hardcoded pricing
EOF
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --days)    DAYS="$2"; shift 2 ;;
    --month)   MONTH="$2"; shift 2 ;;
    --since)   SINCE="$2"; shift 2 ;;
    --until)   UNTIL="$2"; shift 2 ;;
    --reset)   RESET_AT="$2"; shift 2 ;;
    --compare) COMPARE="$2"; shift 2 ;;
    --last)    LAST="$2"; LAST_SET=true; shift 2 ;;
    --weeks)   LAST="$2"; LAST_SET=true; WEEKS_SET=true; shift 2 ;;
    --current) CURRENT=true; shift ;;
    --html)    HTML_OUT="$2"; shift 2 ;;
    --top)     TOP_N="$2"; shift 2 ;;
    --project) PROJECT_FILTER="$2"; shift 2 ;;
    --dir)     CLAUDE_DIR="$2"; shift 2 ;;
    --freq)    CHART_FREQ="$2"; shift 2 ;;
    --offline) OFFLINE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [[ ! -d "$CLAUDE_DIR" ]]; then
  echo "Error: Claude logs directory not found: $CLAUDE_DIR"
  echo "Set CLAUDE_DIR or use --dir to point to your logs."
  exit 1
fi

# --- Colors: off when NO_COLOR is set or output is not a terminal; FORCE_COLOR=1 keeps them ---
NOCOLOR=0
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then NOCOLOR=1; fi
if [[ -n "${FORCE_COLOR:-}" && "${FORCE_COLOR}" != 0 ]]; then NOCOLOR=0; fi   # e.g. for less -R
if [[ "$NOCOLOR" == 1 ]]; then
  DIM=''; YELLOW=''; RESET=''
else
  DIM='\033[2m'; YELLOW='\033[33m'; RESET='\033[0m'
fi

# --- Portable date helpers (GNU date on Linux, BSD date on macOS) ---
is_gnu_date() { date --version >/dev/null 2>&1; }

# "YYYY-MM-DD HH:MM" (local) -> epoch seconds
# (seconds are given explicitly: BSD date fills missing fields from the current clock)
to_epoch() {
  if is_gnu_date; then date -d "$1:00" +%s; else date -j -f "%Y-%m-%d %H:%M:%S" "$1:00" +%s; fi
}

# epoch seconds -> local time in the given format
fmt_epoch() {
  if is_gnu_date; then date -d "@$1" +"$2"; else date -r "$1" +"$2"; fi
}

# YYYY-MM-DD plus N days (N may be negative)
add_days() {
  local n=$2
  if is_gnu_date; then
    date -d "$1 $n days" +%Y-%m-%d
  else
    [[ $n != -* ]] && n="+$n"
    date -j -v"${n}"d -f %Y-%m-%d "$1" +%Y-%m-%d
  fi
}

# YYYY-MM-01 plus N months (N may be negative)
add_months() {
  local n=$2
  if is_gnu_date; then
    date -d "$1 $n months" +%Y-%m-%d
  else
    [[ $n != -* ]] && n="+$n"
    date -j -v"${n}"m -f %Y-%m-%d "$1" +%Y-%m-%d
  fi
}

die() { echo "Error: $*" >&2; exit 1; }

# "YYYY-MM-DD" or "YYYY-MM-DD HH:MM" -> epoch; $2=end makes a bare date mean "end of that day"
parse_when() {
  local out=""
  if [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    if [[ "${2:-}" == end ]]; then
      out=$(add_days "$1" 1 2>/dev/null) && out=$(to_epoch "$out 00:00" 2>/dev/null) || out=""
    else
      out=$(to_epoch "$1 00:00" 2>/dev/null) || out=""
    fi
  elif [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{1,2}:[0-9]{2}$ ]]; then
    out=$(to_epoch "$1" 2>/dev/null) || out=""
  fi
  if [[ -z "$out" ]]; then
    echo "Error: bad date '$1' (use YYYY-MM-DD or \"YYYY-MM-DD HH:MM\")" >&2
    return 1
  fi
  echo "$out"
}

# --- Fetch LiteLLM pricing (default behavior) ---
PRICING_FILE=""
if [[ "$OFFLINE" != true ]]; then
  echo -e "${DIM}Fetching latest pricing from LiteLLM...${RESET}"
  TMPJSON=$(mktemp)
  TMPTSV=$(mktemp)
  if curl -sS --fail -o "$TMPJSON" "$LITELLM_URL" 2>/dev/null; then
    # Parse JSON into TSV: model, input, output, cache_write_5m, cache_read, cache_write_1h (per 1M)
    awk '
    {
      gsub(/^[ \t]+/, "")
      gsub(/[ \t]+$/, "")
    }
    /^"[a-zA-Z]/ && /": *\{/ {
      if (model != "") print model "|" data
      model = $0
      gsub(/^"/, "", model)
      gsub(/".*/, "", model)
      data = ""
      next
    }
    model != "" && (/cost_per_token/ || /token_cost/) {
      gsub(/[ \t]*"/, "")
      gsub(/: */, "=")
      gsub(/,[ \t]*$/, "")
      data = data $0 "|"
    }
    END { if (model != "") print model "|" data }
    ' "$TMPJSON" | \
    grep -E '^(anthropic/)?claude-' | \
    awk -F"|" '
    {
      model = $1
      inp=0; out=0; cw=0; cr=0; cw1h=0
      for (i=2; i<=NF; i++) {
        if ($i == "") continue
        split($i, kv, "=")
        k = kv[1]; v = kv[2] + 0
        if (k == "input_cost_per_token") inp = v
        else if (k == "output_cost_per_token") out = v
        else if (k == "cache_creation_input_token_cost") cw = v
        else if (k == "cache_read_input_token_cost") cr = v
        else if (k == "cache_creation_input_token_cost_above_1hr") cw1h = v
      }
      if (inp > 0 || out > 0) {
        if (cw1h == 0) cw1h = inp * 2
        printf "%s\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\n", model, inp*1000000, out*1000000, cw*1000000, cr*1000000, cw1h*1000000
      }
    }
    ' > "$TMPTSV"
    MODELS_LOADED=$(wc -l < "$TMPTSV" | tr -d ' ')
    echo -e "${DIM}Loaded pricing for $MODELS_LOADED Claude models${RESET}"
    if [[ -s "$TMPTSV" ]]; then
      PRICING_FILE="$TMPTSV"
    fi
  else
    echo -e "${YELLOW}Warning: Could not fetch LiteLLM pricing, using hardcoded defaults${RESET}"
  fi
  rm -f "$TMPJSON"
fi

# --- Periods: one line per column to report, as idx<TAB>start<TAB>end<TAB>short<TAB>long ---
PERIOD_FILE=$(mktemp)
NOW=$(date +%s)
LABEL_FMT="%a %b %d %H:%M"

case "$COMPARE" in
  "") ;;
  day|days|daily)       COMPARE=day ;;
  week|weeks|weekly)    COMPARE=week ;;
  month|months|monthly) COMPARE=month ;;
  year|years|yearly)    COMPARE=year ;;
  *) die "--compare takes day, week, month or year" ;;
esac
if [[ -n "$RESET_AT" || "$WEEKS_SET" == true ]]; then
  [[ -z "$COMPARE" ]] && COMPARE=week
  [[ "$COMPARE" == week ]] || die "--reset and --weeks only work with weekly comparisons"
fi
if [[ -z "$COMPARE" && ( "$LAST_SET" == true || "$CURRENT" == true ) ]]; then
  die "--last, --weeks and --current need --compare or --reset, e.g. --reset \"wed 11:30\""
fi

BUCKET=auto
if [[ -n "$COMPARE" ]]; then
  [[ -n "$DAYS$SINCE$UNTIL$MONTH" ]] && die "--compare/--reset cannot be combined with --days, --since, --until or --month"
  [[ "$LAST" =~ ^[1-5]$ ]] || die "--last/--weeks must be 1 to 5 (at most 5 periods are compared)"
  TOTAL=$LAST
  [[ "$CURRENT" == true ]] && TOTAL=$((LAST + 1))
  (( TOTAL <= 5 )) || die "at most 5 periods can be compared; --last $LAST with --current makes $TOTAL"

  TODAY=$(date +%Y-%m-%d)
  B_TIME="00:00"
  case "$COMPARE" in
    day)   BASE="$TODAY"; BUCKET=hour; CUR_LABEL="Today" ;;
    month) BASE="$(date +%Y-%m)-01"; BUCKET=week; CUR_LABEL="This month" ;;
    year)  BASE="$(date +%Y)-01-01"; BUCKET=month; CUR_LABEL="This year" ;;
    week)
      BUCKET=day; CUR_LABEL="This week"
      R_DAY=mon; R_TIME="00:00"
      if [[ -n "$RESET_AT" ]]; then
        read -r R_DAY R_TIME <<< "$RESET_AT"
        R_DAY=$(echo "${R_DAY:-}" | tr '[:upper:]' '[:lower:]' | cut -c1-3)
        if [[ ! "$R_DAY" =~ ^(mon|tue|wed|thu|fri|sat|sun)$ || ! "${R_TIME:-}" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
          die "--reset needs a weekday and a time, e.g. --reset \"wed 11:30\""
        fi
      fi
      B_TIME="$R_TIME"
      # Most recent boundary at or before now
      BASE=""
      for i in 0 1 2 3 4 5 6 7; do
        d=$(add_days "$TODAY" "-$i")
        e=$(to_epoch "$d $R_TIME")
        wd=$(fmt_epoch "$e" %a | tr '[:upper:]' '[:lower:]')
        if [[ "$wd" == "$R_DAY" && "$e" -le "$NOW" ]]; then BASE="$d"; break; fi
      done
      ;;
  esac

  # Start date of the period k steps before the one in progress (k = 0 is current)
  period_start() {
    case "$COMPARE" in
      day)   add_days "$BASE" "-$1" ;;
      week)  add_days "$BASE" "$(( -7 * $1 ))" ;;
      month) add_months "$BASE" "-$1" ;;
      year)  echo "$(( ${BASE:0:4} - $1 ))-01-01" ;;
    esac
  }
  short_label() {  # $1 start epoch, $2 index
    case "$COMPARE" in
      day)   fmt_epoch "$1" "%a %b %d" ;;
      week)  echo "Week $2" ;;
      month) fmt_epoch "$1" "%b %Y" ;;
      year)  fmt_epoch "$1" "%Y" ;;
    esac
  }
  long_label() {   # $1 start epoch, $2 end epoch
    case "$COMPARE" in
      day)   fmt_epoch "$1" "%a %b %d %Y" ;;
      week)  echo "$(fmt_epoch "$1" "$LABEL_FMT") → $(fmt_epoch "$2" "$LABEL_FMT")" ;;
      *)     echo "$(fmt_epoch "$1" "%b %d %Y") → $(fmt_epoch "$2" "%b %d %Y")" ;;
    esac
  }

  idx=0
  for (( k=LAST; k>=1; k-- )); do
    s=$(to_epoch "$(period_start "$k") $B_TIME")
    e=$(to_epoch "$(period_start $((k - 1))) $B_TIME")
    idx=$((idx + 1))
    printf "%d\t%d\t%d\t%s\t%s\n" "$idx" "$s" "$e" "$(short_label "$s" "$idx")" "$(long_label "$s" "$e")" >> "$PERIOD_FILE"
  done
  if [[ "$CURRENT" == true ]]; then
    s=$(to_epoch "$(period_start 0) $B_TIME")
    idx=$((idx + 1))
    if [[ "$COMPARE" == day ]]; then CUR_LONG="$(fmt_epoch "$s" "%a %b %d") (in progress)"
    else CUR_LONG="$(fmt_epoch "$s" "$LABEL_FMT") → now (in progress)"; fi
    printf "%d\t%d\t%d\t%s\t%s\n" "$idx" "$s" "$((NOW + 1))" "$CUR_LABEL" "$CUR_LONG" >> "$PERIOD_FILE"
  fi
else
  START=0
  END=$((NOW + 86400))
  if [[ -n "$DAYS" ]]; then START=$(to_epoch "$(add_days "$(date +%Y-%m-%d)" "-$DAYS") 00:00"); fi
  if [[ -n "$MONTH" ]]; then
    if [[ ! "$MONTH" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
      echo "Error: --month needs YYYY-MM" >&2; exit 1
    fi
    START=$(parse_when "$MONTH-01") || exit 1
    END=$(parse_when "$(add_days "$(add_days "$MONTH-01" 31 | cut -c1-7)-01" -1)" end) || exit 1
  fi
  if [[ -n "$SINCE" ]]; then START=$(parse_when "$SINCE") || exit 1; fi
  if [[ -n "$UNTIL" ]]; then END=$(parse_when "$UNTIL" end) || exit 1; fi
  if [[ "$START" -gt 0 ]]; then
    if [[ -n "$UNTIL" || -n "$MONTH" ]]; then
      LONG="$(fmt_epoch "$START" "$LABEL_FMT") → $(fmt_epoch "$END" "$LABEL_FMT")"
    else
      LONG="$(fmt_epoch "$START" "$LABEL_FMT") → now"
    fi
  else
    LONG="All history"
  fi
  printf "1\t%d\t%d\tSelected\t%s\n" "$START" "$END" "$LONG" >> "$PERIOD_FILE"
fi


case "$CHART_FREQ" in
  auto) ;;
  hourly|hour)   BUCKET=hour ;;
  daily|day)     BUCKET=day ;;
  weekly|week)   BUCKET=week ;;
  monthly|month) BUCKET=month ;;
  *) die "--freq takes auto, hourly, daily, weekly or monthly" ;;
esac

# Local UTC offset in minutes, e.g. +0530 -> 330
TZ_RAW=$(date +%z)
TZ_SIGN=${TZ_RAW:0:1}
TZ_OFF_MIN=$(( 10#${TZ_RAW:1:2} * 60 + 10#${TZ_RAW:3:2} ))
[[ "$TZ_SIGN" == "-" ]] && TZ_OFF_MIN=$(( -TZ_OFF_MIN ))

# --- Find JSONL files (including subagent sessions) ---
FIND_ARGS=("$CLAUDE_DIR" -name '*.jsonl' -type f)
if [[ -n "$PROJECT_FILTER" ]]; then
  FIND_ARGS+=(-path "*${PROJECT_FILTER}*")
fi
# Every file is read, even ones last written before the range: resumed sessions
# copy old messages into new files, and the earliest copy decides where a
# message is counted.

FILE_LIST=$(mktemp)
find "${FIND_ARGS[@]}" -print0 2>/dev/null > "$FILE_LIST" || true
FILE_COUNT=$(tr -cd '\0' < "$FILE_LIST" | wc -c | tr -d ' ')

if [[ "$FILE_COUNT" -eq 0 ]]; then
  echo "No JSONL files found in $CLAUDE_DIR"
  rm -f "$FILE_LIST" "$PERIOD_FILE"
  exit 1
fi

echo -e "${DIM}Scanning $FILE_COUNT session files...${RESET}"

GEN_TIME=$(date '+%Y-%m-%d %H:%M %Z')

# --- Extract, aggregate and report with awk ---
# Helpers shared by the readers and the reducer
IFS= read -r -d '' COMMON_AWK <<'AWK' || true
function set_price(m, i, o, cw, cr) {
  price[m,"input"] = i; price[m,"output"] = o
  price[m,"cache_write"] = cw; price[m,"cache_read"] = cr
}

# --- Portable sorts (macOS awk lacks asorti) ---
function sort_keys(arr, sorted,    i, j, n, tmp, k) {
  n = 0
  for (k in arr) { n++; sorted[n] = k }
  for (i = 2; i <= n; i++) {
    tmp = sorted[i]
    j = i - 1
    while (j >= 1 && sorted[j] > tmp) {
      sorted[j+1] = sorted[j]
      j--
    }
    sorted[j+1] = tmp
  }
  return n
}

# Keys of arr ordered by value, highest first
function sort_desc(arr, sorted,    i, j, n, tmp, k) {
  n = 0
  for (k in arr) { n++; sorted[n] = k }
  for (i = 2; i <= n; i++) {
    tmp = sorted[i]
    j = i - 1
    while (j >= 1 && arr[sorted[j]] < arr[tmp]) {
      sorted[j+1] = sorted[j]
      j--
    }
    sorted[j+1] = tmp
  }
  return n
}

# ---- Readers: merge copies within a batch, then print one record per id ----
# Same rules as the reducer: largest count per field, earliest timestamp wins.
# Raw line counts inside the range go out on one "R" line for the uniqueness table.
function emit_u(k, p, d, m, a, b, c, e, h, ep, sid, sd, cwd) {
  if (p > 0) r_u++
  if (!(k in eu_ep) || ep < eu_ep[k]) { eu_ep[k] = ep; eu_p[k] = p; eu_d[k] = d; eu_m[k] = m; eu_s[k] = sid; eu_sd[k] = sd; sub(/^.*\//, "", cwd); eu_w[k] = cwd }
  if (a > eu_a[k]) eu_a[k] = a
  if (b > eu_b[k]) eu_b[k] = b
  if (c > eu_c[k]) eu_c[k] = c
  if (e > eu_e[k]) eu_e[k] = e
  if (h > eu_h[k]) eu_h[k] = h
}

# First word of a shell command, as a name: skips VAR=value prefixes and a leading "cd dir" line or "cd dir &&"
function bash_word(c,    n, t, i, w) {
  gsub(/\\n/, " ; ", c); gsub(/\\t/, " ", c); gsub(/&&|;/, " ; ", c)
  n = split(c, t, /[ \t]+/)
  i = 1
  while (i <= n) {
    if (t[i] == "" || t[i] == ";" || t[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
    if (t[i] == "cd") { for (i++; i <= n && t[i] != ";"; i++) ; continue }
    break
  }
  if (i > n) return ""
  w = t[i]; sub(/^.*\//, "", w); gsub(/[^A-Za-z0-9_.+-]/, "", w)
  return w
}

# "dir/file" from a full path
function short_path(f,    n, a) {
  n = split(f, a, "/")
  return (n >= 2) ? a[n - 1] "/" a[n] : f
}

function emit_t(k, p, cat, name, ep) {
  if (p > 0 && (cat == "tool" || cat == "mcp")) r_t++
  if (!(k in et_ep) || ep < et_ep[k]) { et_ep[k] = ep; et_p[k] = p; et_c[k] = cat; et_n[k] = name }
}

function emit_c(uid, p, name, ep,    k) {
  if (p > 0) r_c++
  k = (uid == "") ? "nouuid:" wid ":" NR : uid
  if (!(k in ec_ep) || ep < ec_ep[k]) { ec_ep[k] = ep; ec_p[k] = p; ec_n[k] = name }
}

function flush_emits(    k) {
  for (k in eu_ep)
    print "U\t" k "\t" eu_p[k] "\t" eu_d[k] "\t" eu_m[k] "\t" eu_a[k] + 0 "\t" eu_b[k] + 0 "\t" eu_c[k] + 0 "\t" eu_e[k] + 0 "\t" eu_h[k] + 0 "\t" eu_ep[k] "\t" eu_s[k] "\t" eu_sd[k] + 0 "\t" eu_w[k]
  for (k in et_ep) print "T\t" k "\t" et_p[k] "\t" et_c[k] "\t" et_n[k] "\t" et_ep[k]
  for (k in ec_ep) print "C\t" k "\t" ec_p[k] "\t" ec_n[k] "\t" ec_ep[k]
  print "R\t" r_u + 0 "\t" r_t + 0 "\t" r_c + 0
}

function extract_num(str, key,    pat, val) {
  pat = "\"" key "\":[0-9]+"
  if (match(str, pat)) {
    val = substr(str, RSTART, RLENGTH)
    gsub(/.*:/, "", val)
    return val + 0
  }
  return 0
}

function extract_str(str, key,    pat, val) {
  pat = "\"" key "\":\"[^\"]*\""
  if (match(str, pat)) {
    val = substr(str, RSTART, RLENGTH)
    gsub(/.*:"/, "", val)
    gsub(/"$/, "", val)
    return val
  }
  return ""
}

# Last match of a string field; top-level fields come after the message body
function last_str(str, key,    pat, val, rest) {
  pat = "\"" key "\":\"[^\"]*\""
  val = ""
  # Top-level fields sit after the message body, so scan only the tail when it has them
  rest = (length(str) > 4000) ? substr(str, length(str) - 3999) : str
  if (!match(rest, pat)) rest = str
  while (match(rest, pat)) {
    val = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
  }
  if (val == "") return ""
  sub(/^"[^"]*":"/, "", val)
  sub(/"$/, "", val)
  return val
}

function get_price(model, type,    key, m) {
  # 1-hour cache writes cost 2x input when no explicit price is known
  if (type == "cache_write_1h" && !((model SUBSEP type) in price) && ((model SUBSEP "input") in price))
    return 2 * price[model SUBSEP "input"]
  key = model SUBSEP type
  if (key in price) return price[key]
  key = ("anthropic/" model) SUBSEP type
  if (key in price) return price[key]
  m = model; sub(/-20[0-9]+$/, "", m); sub(/-thinking$/, "", m); gsub(/\./, "-", m)
  key = m SUBSEP type
  if (key in price) return price[key]
  key = ("anthropic/" m) SUBSEP type
  if (key in price) return price[key]
  if (type == "cache_write_1h") return 2 * get_price(model, "input")
  unpriced[model] = 1
  return price["default" SUBSEP type]
}

function model_short(m) {
  if (m ~ /opus/)   return "opus"
  if (m ~ /sonnet/) return "sonnet"
  if (m ~ /haiku/)  return "haiku"
  if (m ~ /fable/)  return "fable"
  return "other"
}

function date_to_jdn(datestr,    y, m, d, a) {
  split(datestr, _dq, "-")
  y = _dq[1] + 0; m = _dq[2] + 0; d = _dq[3] + 0
  a = int((14 - m) / 12)
  y = y + 4800 - a
  m = m + 12 * a - 3
  return d + int((153 * m + 2) / 5) + 365 * y + int(y/4) - int(y/100) + int(y/400) - 32045
}

function jdn_to_date(jdn,    a, b, c, d, e, m, day, mon, yr) {
  a = jdn + 32044
  b = int((4*a + 3) / 146097)
  c = a - int(146097*b / 4)
  d = int((4*c + 3) / 1461)
  e = c - int(1461*d / 4)
  m = int((5*e + 2) / 153)
  day = e - int((153*m + 2)/5) + 1
  mon = m + 3 - 12 * int(m/10)
  yr  = 100*b + d - 4800 + int(m/10)
  return sprintf("%04d-%02d-%02d", yr, mon, day)
}

function week_start(datestr,    jdn) {
  jdn = date_to_jdn(datestr)
  return jdn_to_date(jdn - jdn % 7)
}

# UTC ISO timestamp -> epoch seconds
function ts_epoch(ts) {
  return (date_to_jdn(substr(ts, 1, 10)) - 2440588) * 86400 \
       + substr(ts, 12, 2) * 3600 + substr(ts, 15, 2) * 60 + substr(ts, 18, 2)
}

# epoch seconds -> local YYYY-MM-DD
function local_date(ep) {
  return jdn_to_date(int((ep + tz_off * 60) / 86400) + 2440588)
}

function period_of(ep,    p) {
  for (p = 1; p <= nper; p++)
    if (ep >= ps[p] && ep < pe[p]) return p
  return 0
}

# ---- Chart buckets: sortable key for the local hour, day, week (Monday) or month ----
function bucket_key(ep, unit,    lep, d, ws, p, pd) {
  lep = ep + tz_off * 60
  d = jdn_to_date(int(lep / 86400) + 2440588)
  if (unit == "hour") return d " " sprintf("%02d", int((lep % 86400) / 3600))
  if (unit == "day")  return d
  if (unit == "week") {
    # a week that starts before its period is clipped to the period start
    ws = week_start(d)
    p = period_of(ep)
    if (p > 0 && ps[p] > 0) { pd = local_date(ps[p]); if (ws < pd) ws = pd }
    return ws
  }
  return substr(d, 1, 7)
}

function bucket_label(k, unit,    m) {
  m = substr(k, 6, 2) + 0
  if (unit == "hour")  return months_arr[m] " " (substr(k, 9, 2) + 0) " " substr(k, 12, 2) ":00"
  if (unit == "day")   return months_arr[m] " " (substr(k, 9, 2) + 0)
  if (unit == "week")  return "Week of " months_arr[m] " " (substr(k, 9, 2) + 0)
  return months_arr[m] " " substr(k, 1, 4)
}

# Short x-axis tick
function bucket_tick(k, unit,    m) {
  m = substr(k, 6, 2) + 0
  if (unit == "hour")  return (substr(k, 12, 2) == "00") ? months_arr[m] " " (substr(k, 9, 2) + 0) : substr(k, 12, 2) "h"
  if (unit == "month") return months_arr[m] " " substr(k, 3, 2)
  return months_arr[m] " " (substr(k, 9, 2) + 0)
}

function unit_word(unit) {
  if (unit == "hour") return "hour"
  if (unit == "day")  return "day"
  if (unit == "week") return "week"
  return "month"
}

# 1, 2 or 5 times a power of ten, at or above x
function nice_max(x,    e, f) {
  if (x <= 0) return 1
  e = exp(log(10) * int(log(x) / log(10)))
  f = x / e
  if (f <= 1) return e
  if (f <= 2) return 2 * e
  if (f <= 5) return 5 * e
  return 10 * e
}

function bump(cat, p, key) {
  cnt[cat, p, key]++
  ctot[cat, key]++
  csum[cat, p]++
}

# Copy one category's totals into out[key]; returns number of keys
function cat_totals(cat, out,    k, kp, n) {
  n = 0
  for (k in ctot) {
    split(k, kp, SUBSEP)
    if (kp[1] == cat) { out[kp[2]] = ctot[k]; n++ }
  }
  return n
}

function format_tokens(t) {
  if (t >= 1000000000) return sprintf("%.2fB", t/1000000000)
  if (t >= 1000000)    return sprintf("%.1fM", t/1000000)
  if (t >= 1000)       return sprintf("%.1fK", t/1000)
  return sprintf("%d", t)
}

function commas(n,    s, r, neg) {
  s = sprintf("%.0f", n)
  neg = ""
  if (substr(s, 1, 1) == "-") { neg = "-"; s = substr(s, 2) }
  r = ""
  while (length(s) > 3) {
    r = "," substr(s, length(s) - 2) r
    s = substr(s, 1, length(s) - 3)
  }
  return neg s r
}

function money(x) {
  if (x < 10) return sprintf("$%.2f", x)
  return "$" commas(x)
}

function pct(a, b) {
  return (b > 0) ? sprintf("%.1f%%", a / b * 100) : "–"
}

function hesc(s) {
  gsub(/&/, "\\&amp;", s)
  gsub(/</, "\\&lt;", s)
  gsub(/>/, "\\&gt;", s)
  gsub(/"/, "\\&quot;", s)
  gsub(/'/, "\\&#39;", s)
  return s
}

AWK

# Fast reader (needs perl): perl pulls out only the needed fields, awk groups them
IFS= read -r -d '' FRAG_PROG_MAIN <<'AWK' || true
BEGIN {
  nper = 0
  while ((getline line < period_file) > 0) {
    split(line, f, "\t")
    nper++
    ps[nper] = f[2] + 0; pe[nper] = f[3] + 0
  }
  close(period_file)
}

# Input: "<line number>\t<fragment>" from the perl extractor, in line order.
# All fragments of one log line are grouped and turned into records.
{
  c = index($0, "\t")
  n = substr($0, 1, c - 1)
  fr = substr($0, c + 1)
  if (n != cur) { flush(); cur = n }
  # The message model/id come first on the line; later "model" keys belong to tool inputs.
  # Claude Code writes {"model","id",...}; some other tools write {"id",...,"model"}.
  if (substr(fr, 1, 9) == "\"model\":\"") {
    if (f_model == "") f_model = extract_str(fr, "model")
    if (f_mid == "") f_mid = extract_str(fr, "id")
  } else if (substr(fr, 1, 16) == "\"message\":{\"id\":") {
    if (f_mid == "") f_mid = extract_str(fr, "id")
  } else if (substr(fr, 1, 17) == "\"type\":\"tool_use\"") {
    nt++
    t_id[nt] = extract_str(fr, "id"); t_name[nt] = extract_str(fr, "name"); t_arg[nt] = ""
  } else if (substr(fr, 1, 9) == "\"skill\":\"") {
    if (nt > 0 && t_name[nt] == "Skill" && t_arg[nt] == "") t_arg[nt] = extract_str(fr, "skill")
  } else if (substr(fr, 1, 11) == "\"command\":\"") {
    if (nt > 0 && t_name[nt] == "Bash" && t_arg[nt] == "") t_arg[nt] = substr(fr, 12)
  } else if (substr(fr, 1, 13) == "\"file_path\":\"") {
    if (nt > 0 && t_name[nt] == "Read" && t_arg[nt] == "") t_arg[nt] = substr(fr, 14)
  } else if (substr(fr, 1, 17) == "\"subagent_type\":\"") {
    if (nt > 0 && (t_name[nt] == "Agent" || t_name[nt] == "Task") && t_arg[nt] == "") t_arg[nt] = extract_str(fr, "subagent_type")
  } else if (fr == "\"usage\":{") {
    in_usage = 1
  } else if (substr(fr, 1, 12) == "\"timestamp\":") {
    f_ts = extract_str(fr, "timestamp")
  } else if (substr(fr, 1, 7) == "\"uuid\":") {
    f_uid = extract_str(fr, "uuid")
  } else if (substr(fr, 1, 13) == "\"sessionId\":\"") {
    f_sid = extract_str(fr, "sessionId")   # last one wins: the top-level key comes after the message
  } else if (substr(fr, 1, 7) == "\"cwd\":\"") {
    f_cwd = extract_str(fr, "cwd")          # last one wins, like the session id
  } else if (substr(fr, 1, 14) == "\"isSidechain\":") {
    if (f_side == "") f_side = (fr ~ /true/) ? 1 : 0
  } else if (substr(fr, 1, 20) == "\"content\":\"<command-") {
    f_cmd = fr
  } else if (in_usage) {
    # first value after "usage":{ is the usage field; later ones repeat it in "iterations"
    key = fr; sub(/^"/, "", key); sub(/".*$/, "", key)
    if (!(key in uv)) uv[key] = extract_num(fr, key)
  }
}
END { flush(); flush_emits() }

function flush(    w, ep, p, d, i, mp, name, tin, tout, tcc, tcr, t1h) {
  if (cur != "" && length(f_ts) >= 19) {
    ep = ts_epoch(f_ts)
    p = period_of(ep)   # 0 outside the range; kept for earliest-copy dedup
    {
      d = local_date(ep)
      {
        if (f_cmd != "" && match(f_cmd, /<command-name>[^<]*/)) {
          name = substr(f_cmd, RSTART + 14, RLENGTH - 14)
          sub(/^\//, "", name)
          emit_c(f_uid, p, "/" name, ep)
        }
        for (i = 1; i <= nt; i++) {
          if (t_name[i] ~ /^mcp__/) {
            split(t_name[i], mp, "__")
            emit_t(t_id[i], p, "mcp", mp[2], ep)
            emit_t(t_id[i] ":m", p, "mcptool", mp[2] " › " substr(t_name[i], length("mcp__" mp[2] "__") + 1), ep)
          } else {
            emit_t(t_id[i], p, "tool", t_name[i], ep)
          }
          if (t_name[i] == "Skill" && t_arg[i] != "") emit_t(t_id[i] ":s", p, "skill", t_arg[i], ep)
          if (t_name[i] == "Bash" && (w = bash_word(t_arg[i])) != "") emit_t(t_id[i] ":b", p, "bash", w, ep)
          if (t_name[i] == "Read" && t_arg[i] != "") emit_t(t_id[i] ":f", p, "file", short_path(t_arg[i]), ep)
          if (t_name[i] == "Agent" || t_name[i] == "Task")
            emit_t(t_id[i] ":a", p, "agent", (t_arg[i] == "") ? "general-purpose" : t_arg[i], ep)
        }
        if (in_usage && f_model != "" && f_model != "<synthetic>") {
          tin = uv["input_tokens"] + 0; tout = uv["output_tokens"] + 0
          tcc = uv["cache_creation_input_tokens"] + 0; tcr = uv["cache_read_input_tokens"] + 0
          t1h = uv["ephemeral_1h_input_tokens"] + 0
          if (t1h > tcc) t1h = tcc
          if (tin + tout + tcc + tcr > 0)
            emit_u((f_mid != "") ? f_mid : "unk_" wid ":" cur, p, d, f_model, tin, tout, tcc, tcr, t1h, ep, f_sid, f_side + 0, f_cwd)
        }
      }
    }
  }
  f_model = f_mid = f_ts = f_uid = f_cmd = f_sid = f_side = f_cwd = ""
  nt = 0; in_usage = 0
  delete uv
}
AWK
FRAG_PROG="${COMMON_AWK}${FRAG_PROG_MAIN}"

# perl extractor: one "<line>\t<fragment>" per field, only on lines awk needs.
# Escaped JSON inside message text (\"usage\") never matches these patterns.
# Slash commands come in two shapes: <command-...> tags, or plain text "/name ..." typed by the
# user (skipped in subagent prompts, and when followed by "/", as in file paths). Plain ones are
# rewritten to the tag shape so the awk side sees one thing. Tool results that merely show a tag are skipped.
PERL_PROG='next unless index($_, q{"usage"}) >= 0 || index($_, q{"content":"<command-}) >= 0 || index($_, q{"role":"user","content":"/}) >= 0;
next if index($_, q{"type":"tool_result"}) >= 0;
$side = index($_, q{"isSidechain":true}) >= 0;
while (/("model":"[^"]*"(?:,"id":"[^"]*")?|"message":\{"id":"[^"]*"|"type":"tool_use","id":"[^"]*","name":"[^"]*"|"(?:skill|subagent_type)":"[^"]*"|"command":"(?:[^"\\]|\\.)*|"file_path":"[^"]*|"usage":\{|"(?:input_tokens|output_tokens|cache_creation_input_tokens|cache_read_input_tokens|ephemeral_1h_input_tokens)":[0-9]+|"timestamp":"[^"]*"|"uuid":"[^"]*"|"sessionId":"[^"]*"|"cwd":"[^"]*"|"isSidechain":(?:true|false)|"content":"<command-[^"]*|"role":"user","content":"\/[A-Za-z][\w:-]*(?=[ ,"\\]))/g) { $f = $1; if ($f =~ /^"role"/) { next if $side; $f =~ s{^.*"content":"}{"content":"<command-name>}; } print "$.\t$f\n" }'

# Fallback reader (awk only): runs in parallel over batches of files and prints compact records
IFS= read -r -d '' MAP_PROG_MAIN <<'AWK' || true
BEGIN {
  nper = 0
  while ((getline line < period_file) > 0) {
    split(line, f, "\t")
    nper++
    ps[nper] = f[2] + 0; pe[nper] = f[3] + 0
  }
  close(period_file)
}

{
  # ---- Timestamp: take the last match, the top-level field ----
  ts = last_str($0, "timestamp")
  if (length(ts) < 19) next
  ep = ts_epoch(ts)
  # p = 0 outside the report range; still emitted so the reducer can see an
  # earlier copy of a message and not count a later copy inside the range
  p = period_of(ep)
  cur_date = local_date(ep)

  # ---- Slash commands the user typed ----
  # Logged as "<command-name>…" or, for skill commands, "<command-message>…<command-name>…",
  # or as plain text "/name …" (not in subagent prompts, and not a path like /tmp/x).
  # A tool result that merely shows a tag is not a command.
  if (index($0, "\"type\":\"tool_result\"") > 0) next
  if (index($0, "\"content\":\"<command-") > 0) {
    if (match($0, /<command-name>[^<]*</)) {
      cname = substr($0, RSTART + 14, RLENGTH - 15)
      sub(/^\//, "", cname)
      emit_c(last_str($0, "uuid"), p, "/" cname, ep)
    }
    next
  }
  if (index($0, "\"role\":\"user\",\"content\":\"/") > 0 && index($0, "\"isSidechain\":true") == 0 &&
      match($0, /"role":"user","content":"\/[A-Za-z][A-Za-z0-9_:-]*[ ,"\\]/)) {
    cname = substr($0, RSTART + 26, RLENGTH - 27)
    emit_c(last_str($0, "uuid"), p, "/" cname, ep)
    next
  }

  if (index($0, "\"usage\"") == 0) next

  # ---- Tool calls in this assistant message ----
  rest = $0
  while (match(rest, /"type":"tool_use","id":"[^"]*","name":"[^"]*"/)) {
    blk = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
    tid = blk;   sub(/^.*"id":"/, "", tid);     sub(/".*$/, "", tid)
    tname = blk; sub(/^.*"name":"/, "", tname); sub(/"$/, "", tname)
    # This call's input runs up to the next tool_use block
    nxt = index(rest, "\"type\":\"tool_use\"")
    tinput = (nxt > 0) ? substr(rest, 1, nxt) : rest
    if (tname ~ /^mcp__/) {
      split(tname, mp, "__")
      emit_t(tid, p, "mcp", mp[2], ep)
      emit_t(tid ":m", p, "mcptool", mp[2] " › " substr(tname, length("mcp__" mp[2] "__") + 1), ep)
    } else {
      emit_t(tid, p, "tool", tname, ep)
    }
    if (tname == "Bash" && index(tinput, "\"command\":\"") > 0 && (bw = bash_word(substr(tinput, index(tinput, "\"command\":\"") + 11, 1000))) != "") emit_t(tid ":b", p, "bash", bw, ep)
    if (tname == "Read" && (fpath = extract_str(tinput, "file_path")) != "") emit_t(tid ":f", p, "file", short_path(fpath), ep)
    if (tname == "Skill") {
      sname = extract_str(tinput, "skill")
      if (sname != "") emit_t(tid ":s", p, "skill", sname, ep)
    }
    if (tname == "Agent" || tname == "Task") {
      aname = extract_str(tinput, "subagent_type")
      emit_t(tid ":a", p, "agent", (aname == "") ? "general-purpose" : aname, ep)
    }
  }

  # ---- Token usage ----
  cur_model = extract_str($0, "model")
  if (cur_model == "" || cur_model == "<synthetic>") next

  # Read counts from the usage object only, not from message text
  if (!match($0, /"usage":\{/)) next
  u = substr($0, RSTART)
  cur_input   = extract_num(u, "input_tokens")
  cur_output  = extract_num(u, "output_tokens")
  cur_ccreate = extract_num(u, "cache_creation_input_tokens")
  cur_cread   = extract_num(u, "cache_read_input_tokens")
  cur_c1h     = extract_num(u, "ephemeral_1h_input_tokens")
  if (cur_c1h > cur_ccreate) cur_c1h = cur_ccreate

  if (cur_input + cur_output + cur_ccreate + cur_cread == 0) next

  # Dedup key: the API message id, unique per response. Copies of the same
  # response (streamed blocks, resumed or forked sessions) share it, whatever
  # their timestamp, so they are counted once.
  msg_id = extract_str($0, "id")
  dedup_key = (msg_id != "") ? msg_id : "unk_" wid ":" NR

  emit_u(dedup_key, p, cur_date, cur_model, cur_input, cur_output, cur_ccreate, cur_cread, cur_c1h, ep,
         last_str($0, "sessionId"), (index($0, "\"isSidechain\":true") > 0) ? 1 : 0, last_str($0, "cwd"))
}
END { flush_emits() }
AWK
MAP_PROG="${COMMON_AWK}${MAP_PROG_MAIN}"

# Reducer: merges the records, prices them and prints the report
IFS= read -r -d '' REDUCE_PROG_MAIN <<'AWK' || true
BEGIN {
  # --- Load pricing ---
  loaded_live = 0
  if (pricing_file != "") {
    while ((getline line < pricing_file) > 0) {
      n = split(line, f, "\t")
      if (n >= 6) {
        price[f[1],"input"]          = f[2] + 0
        price[f[1],"output"]         = f[3] + 0
        price[f[1],"cache_write"]    = f[4] + 0
        price[f[1],"cache_read"]     = f[5] + 0
        price[f[1],"cache_write_1h"] = f[6] + 0
        loaded_live++
      }
    }
    close(pricing_file)
  }

  if (loaded_live == 0) {
    # Hardcoded fallback pricing (per 1M tokens): input, output, 5m cache write, cache read.
    # 1-hour cache writes fall back to 2x input in get_price().
    set_price("claude-fable-5-1",           10.00, 50.00, 12.50, 0.25)
    set_price("claude-fable-5",             10.00, 50.00, 12.50, 1.00)
    set_price("claude-opus-5-5",             4.00, 20.00,  5.00, 0.20)
    set_price("claude-opus-5",               5.00, 25.00,  6.25, 0.50)
    set_price("claude-sonnet-5",             2.00, 10.00,  2.50, 0.20)
    set_price("claude-opus-4-6",             5.00, 25.00,  6.25, 0.50)
    set_price("claude-opus-4-5-20251101",    5.00, 25.00,  6.25, 0.50)
    set_price("claude-sonnet-4-6",           3.00, 15.00,  3.75, 0.30)
    set_price("claude-sonnet-4-5-20250929",  3.00, 15.00,  3.75, 0.30)
    set_price("claude-haiku-4-5-20251001",   1.00,  5.00,  1.25, 0.10)
    set_price("sonnet",                      3.00, 15.00,  3.75, 0.30)
  }

  # Default fallback (always set)
  set_price("default", 3.00, 15.00, 3.75, 0.30)

  # --- Load periods ---
  nper = 0
  while ((getline line < period_file) > 0) {
    split(line, f, "\t")
    nper++
    ps[nper] = f[2] + 0; pe[nper] = f[3] + 0
    plab[nper] = f[4]; plong[nper] = f[5]
  }
  close(period_file)

  split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", months_arr, " ")
  ncat = split("tool mcp skill cmd agent", cats, " ")
  cat_title["tool"]  = "Tools";          cat_icon["tool"]  = "🔧"
  cat_title["mcp"]   = "MCP servers";    cat_icon["mcp"]   = "🔌"
  cat_title["skill"] = "Skills";         cat_icon["skill"] = "🧩"
  cat_title["cmd"]   = "Slash commands"; cat_icon["cmd"]   = "⌨️ "
  cat_title["agent"] = "Subagents";      cat_icon["agent"] = "🤖"
  # the HTML report also lists individual MCP tools and projects (the terminal keeps the first five)
  nhcat = split("tool mcp mcptool bash file skill cmd agent project", hcats, " ")
  cat_title["mcptool"]  = "MCP tools";           cat_icon["mcptool"]  = "🔧"
  cat_title["project"]  = "Projects (API calls)"; cat_icon["project"] = "📁"
  cat_title["bash"]     = "Bash commands";       cat_icon["bash"]     = "⌨️ "
  cat_title["file"]     = "Files read";          cat_icon["file"]     = "📄"
}

# ---- Merge the records written by the parallel readers ----
# Resumed sessions copy old lines with new timestamps, so every record is placed
# at its earliest timestamp; that keeps results independent of file order.
# U: one API response line. The same call is logged once per streamed block,
#    so keep the largest count seen per field.
$1 == "R" { raw_u += $2; raw_t += $3; raw_c += $4; next }
$1 == "U" {
  k = $2
  if (!(k in dk_date) || $11 + 0 < dk_ep[k]) {
    dk_date[k] = $4; dk_model[k] = $5; dk_period[k] = $3 + 0; dk_ep[k] = $11 + 0
    dk_sid[k] = $12; dk_side[k] = $13 + 0; dk_cwd[k] = $14
  }
  if ($6 + 0 > dk_input[k])   dk_input[k]   = $6 + 0
  if ($7 + 0 > dk_output[k])  dk_output[k]  = $7 + 0
  if ($8 + 0 > dk_ccreate[k]) dk_ccreate[k] = $8 + 0
  if ($9 + 0 > dk_cread[k])   dk_cread[k]   = $9 + 0
  if ($10 + 0 > dk_c1h[k])    dk_c1h[k]     = $10 + 0
  next
}
# T: one tool call (or the skill / subagent it names), unique by tool_use id
$1 == "T" {
  k = $2
  if (!(k in t_ep) || $6 + 0 < t_ep[k]) {
    t_ep[k] = $6 + 0; t_p[k] = $3 + 0; t_cat[k] = $4; t_name[k] = $5
  }
  next
}
# C: one slash command, unique by message uuid
$1 == "C" {
  k = $2
  if (!(k in c_ep) || $5 + 0 < c_ep[k]) {
    c_ep[k] = $5 + 0; c_p[k] = $3 + 0; c_name[k] = $4
  }
  next
}

END {
  # Records whose earliest copy is outside the range (period 0) are dropped here
  for (k in t_ep) {
    if (t_p[k] == 0) continue
    bump(t_cat[k], t_p[k], t_name[k])
    if (t_cat[k] == "tool" || t_cat[k] == "mcp") uniq_t++
  }
  for (k in c_ep) { if (c_p[k] == 0) continue; bump("cmd", c_p[k], c_name[k]); uniq_c++ }
  for (k in dk_date) { if (dk_period[k] == 0) delete dk_date[k]; else uniq_u++ }
  analyze_context()

  # ---- Chart step: given, or picked from the span of the data ----
  min_ep = 0; max_ep = 0
  for (dk in dk_date) {
    if (dk_period[dk] == 0) continue
    if (min_ep == 0 || dk_ep[dk] < min_ep) min_ep = dk_ep[dk]
    if (dk_ep[dk] > max_ep) max_ep = dk_ep[dk]
  }
  # chart range: the compared periods, or the data itself for one open range
  r_from = (ps[1] > 0) ? ps[1] : min_ep
  r_to = (pe[nper] < now) ? pe[nper] : now
  if (nper == 1 && pe[1] > now) r_to = (max_ep > 0) ? max_ep : now
  if (bucket_unit == "auto") {
    span = r_to - r_from
    if (span <= 2 * 86400)        bucket_unit = "hour"
    else if (span <= 45 * 86400)  bucket_unit = "day"
    else if (span <= 200 * 86400) bucket_unit = "week"
    else                          bucket_unit = "month"
  }
  # every bucket in the range, so empty ones show as zero
  if (min_ep > 0 && r_from > 0) {
    for (t = r_from; t < r_to; t += 3600) B_cost[bucket_key(t, bucket_unit)] += 0
    if (r_to > r_from) B_cost[bucket_key(r_to - 1, bucket_unit)] += 0
  }

  # ---- Aggregate from deduplicated messages ----
  for (dk in dk_date) {
    date    = dk_date[dk]
    model   = dk_model[dk]
    p       = dk_period[dk]
    ym      = substr(date, 1, 7)
    input_tok    = dk_input[dk] + 0
    output_tok   = dk_output[dk] + 0
    cache_create = dk_ccreate[dk] + 0
    cache_read   = dk_cread[dk] + 0
    cache_1h     = dk_c1h[dk] + 0

    cost_input  = input_tok    * get_price(model, "input")       / 1000000
    cost_output = output_tok   * get_price(model, "output")      / 1000000
    cost_cwrite = (cache_create - cache_1h) * get_price(model, "cache_write") / 1000000 \
                + cache_1h * get_price(model, "cache_write_1h") / 1000000
    cost_cread  = cache_read   * get_price(model, "cache_read")  / 1000000
    line_cost   = cost_input + cost_output + cost_cwrite + cost_cread
    line_nocache = (input_tok + cache_create + cache_read) * get_price(model, "input") / 1000000 + cost_output

    total_input   += input_tok
    total_output  += output_tok
    total_ccreate += cache_create
    total_cread   += cache_read
    total_cost    += line_cost
    nocache_cost  += line_nocache
    kind_cost["Input"]        += cost_input
    kind_cost["Output"]       += cost_output
    kind_cost["Cache create"] += cost_cwrite
    kind_cost["Cache read"]   += cost_cread

    # per period
    P_calls[p]++
    P_in[p]   += input_tok
    P_out[p]  += output_tok
    P_cw5[p]  += cache_create - cache_1h
    P_cw1h[p] += cache_1h
    P_cr[p]   += cache_read
    P_cin[p]  += cost_input
    P_cout[p] += cost_output
    P_ccw[p]  += cost_cwrite
    P_ccr[p]  += cost_cread
    P_cost[p] += line_cost
    P_nc[p]   += line_nocache

    # per model (all periods, and per period)
    mod_input[model]   += input_tok
    mod_output[model]  += output_tok
    mod_ccreate[model] += cache_create
    mod_cread[model]   += cache_read
    mod_cost[model]    += line_cost
    mod_calls[model]++
    PM_calls[p, model]++
    PM_in[p, model]  += input_tok
    PM_out[p, model] += output_tok
    PM_cw[p, model]  += cache_create
    PM_cr[p, model]  += cache_read
    PM_cost[p, model] += line_cost

    day_cost[date]   += line_cost
    day_cost_p[date, p] += line_cost
    day_tokens[date] += input_tok + output_tok + cache_create + cache_read
    active_days[date] = 1

    bk = bucket_key(dk_ep[dk], bucket_unit)
    B_cost[bk]    += line_cost
    B_cost_p[bk, p] += line_cost
    B_calls[bk]++
    bump("project", p, (dk_cwd[dk] != "") ? dk_cwd[dk] : "(unknown)")
    lep = dk_ep[dk] + tz_off * 60
    hh = int((lep % 86400) / 3600); wd = (int(lep / 86400) + 3) % 7   # 1970-01-01 was a Thursday; Monday = 0
    proj = (dk_cwd[dk] != "") ? dk_cwd[dk] : "(unknown)"
    PJ_c[p, proj] += line_cost; PJ_n[p, proj]++; PJ_t[proj] += line_cost
    TH_n[p, hh]++; TH_c[p, hh] += line_cost; TW_n[p, wd]++; TW_c[p, wd] += line_cost
    B_cr[bk] += cache_read
    B_in[bk] += input_tok + cache_create + cache_read

    month_cost[ym]   += line_cost
    month_tokens[ym] += input_tok + output_tok + cache_create + cache_read
    month_models[ym SUBSEP model_short(model)] = 1
  }

  if (length(dk_date) == 0) {
    print "\n  No usage found in this range.\n"
    exit 0
  }

  total_tokens = total_input + total_output + total_ccreate + total_cread
  num_active = 0
  for (_k in active_days) num_active++
  cache_hit = (total_cread + total_ccreate + total_input > 0) ? total_cread / (total_cread + total_ccreate + total_input) * 100 : 0

  avg_cost = (num_active > 0) ? total_cost / num_active : 0
  avg_tokens = (num_active > 0) ? total_tokens / num_active : 0

  peak_cost = 0; peak_day = ""
  for (d in day_cost) {
    if (day_cost[d] > peak_cost) { peak_cost = day_cost[d]; peak_day = d }
  }
  split(peak_day, pd, "-")
  peak_label = months_arr[pd[2]+0] " " pd[3]+0

  # ===================== TERMINAL REPORT =====================
  CR = tc("0"); CB = tc("1"); CD = tc("2"); CG = tc("32"); CRD = tc("31"); CC = tc("36")
  split("69 208 36 168 141", pcn, " ")
  for (p = 1; p <= nper; p++) PC[p] = tc("38;5;" pcn[(p - 1) % 5 + 1])
  split("75 214 43 245", kcn, " ")
  for (j = 1; j <= 4; j++) KC[j] = tc("38;5;" kcn[j])

  # ---- Header ----
  printf "\n  %sClaude Code usage%s  %s· estimated at API list prices · pricing %s%s\n\n", CB, CR, CD, \
    (loaded_live > 0 ? "LiteLLM (" loaded_live " models)" : "hardcoded"), CR
  for (p = 1; p <= nper; p++)
    printf "  %s■%s %s%-11s%s %s%s%s\n", PC[p], CR, CB, plab[p], CR, CD, plong[p], CR
  tin_all = total_input + total_ccreate + total_cread
  printf "\n  %sTotal%s  %s%s%s  ·  %s calls  ·  %s tokens  ·  hit rate %s  ·  %d active days  ·  peak %s %s\n", \
    CB, CR, CB CG, money(total_cost), CR, commas(uniq_u), format_tokens(total_tokens), \
    pct(total_cread, tin_all), num_active, peak_label, money(peak_cost)

  # ---- Comparison (or summary for one period) ----
  colw = (nper > 3) ? 17 : 20
  section(nper > 1 ? "Comparison" : "Summary")
  printf "  %-22s", ""
  for (p = 1; p <= nper; p++) printf " %s%*s%s", PC[p] CB, colw, substr(plab[p], 1, colw), CR
  if (nper > 1) printf " %s%10s%s", CD, "vs prev", CR
  printf "\n  %s%s%s\n", CD, repeat("─", 22 + (colw + 1) * nper + (nper > 1 ? 11 : 0)), CR
  n2 = nper; n1 = nper - 1
  for (p = 1; p <= nper; p++) v[p] = commas(P_calls[p]);                                          crow("API calls", v, "", chg(P_calls, 0))
  for (p = 1; p <= nper; p++) { tv[p] = P_in[p] + P_cw5[p] + P_cw1h[p] + P_cr[p]; v[p] = format_tokens(tv[p]) }; crow("Input tokens", v, "", chg(tv, 0))
  for (p = 1; p <= nper; p++) v[p] = format_tokens(P_cr[p]) " · " money(P_ccr[p]);               crow("  Cache read (hit)", v, "d", chg(P_ccr, 1))
  for (p = 1; p <= nper; p++) v[p] = format_tokens(P_cw5[p]);                                    crow("  Cache write 5 min", v, "d", chg(P_cw5, 0))
  for (p = 1; p <= nper; p++) v[p] = format_tokens(P_cw1h[p]);                                   crow("  Cache write 1 hour", v, "d", chg(P_cw1h, 0))
  for (p = 1; p <= nper; p++) v[p] = format_tokens(P_cw5[p] + P_cw1h[p]) " · " money(P_ccw[p]); crow("  Cache writes (miss)", v, "d", chg(P_ccw, 1))
  for (p = 1; p <= nper; p++) v[p] = format_tokens(P_in[p]) " · " money(P_cin[p]);               crow("  Not cached (miss)", v, "d", chg(P_cin, 1))
  for (p = 1; p <= nper; p++) { hr[p] = (tv[p] > 0) ? P_cr[p] / tv[p] * 100 : 0; v[p] = pct(P_cr[p], tv[p]) }; crow("  Cache hit rate", v, "d", chg_pt(hr))
  for (p = 1; p <= nper; p++) v[p] = format_tokens(P_out[p]) " · " money(P_cout[p]);             crow("Output tokens", v, "", chg(P_cout, 1))
  for (p = 1; p <= nper; p++) v[p] = money(P_cost[p]);                                           crow("Est. API cost", v, "b", chg(P_cost, 1))
  for (p = 1; p <= nper; p++) v[p] = money(P_nc[p]);                                             crow("Cost with no cache", v, "d", chg(P_nc, 0))

  # ---- Where the money goes ----
  section("Where the money goes")
  split("Cache read|Cache write|Output|Input", kname, "|")
  printf "  "
  for (j = 1; j <= 4; j++) printf "%s%s%s %s   ", KC[j], (nocolor ? substr("█▓▒░", (j - 1) * 3 + 1, 3) : "■"), CR, kname[j]
  printf "\n\n"
  for (p = 1; p <= nper; p++) {
    kc[1] = P_ccr[p]; kc[2] = P_ccw[p]; kc[3] = P_cout[p]; kc[4] = P_cin[p]
    printf "  %s%-11s%s %s %s%10s%s  %sread %s · write %s · output %s%s\n", PC[p], substr(plab[p], 1, 11), CR, \
      stackbar(kc, P_cost[p], 40), CB, money(P_cost[p]), CR, CD, pct(kc[1], P_cost[p]), pct(kc[2], P_cost[p]), pct(kc[3], P_cost[p]), CR
  }
  printf "\n  Caching saved %s%s%s: the same tokens without cache would cost %s (%.0f%% less).\n", CB CG, money(nocache_cost - total_cost), CR, \
    money(nocache_cost), (nocache_cost > 0 ? (nocache_cost - total_cost) / nocache_cost * 100 : 0)

  # ---- Cost chart, one step below the compared period ----
  section("Cost per " unit_word(bucket_unit))
  n = sort_keys(B_cost, sorted_buckets)
  max_cost = 0
  for (i = 1; i <= n; i++) if (B_cost[sorted_buckets[i]] > max_cost) max_cost = B_cost[sorted_buckets[i]]
  if (max_cost <= 0) max_cost = 1
  lw = 0
  for (i = 1; i <= n; i++) if (dw(bucket_label(sorted_buckets[i], bucket_unit)) > lw) lw = dw(bucket_label(sorted_buckets[i], bucket_unit))
  for (i = 1; i <= n; i++) {
    bk = sorted_buckets[i]
    # colour a bar by the period holding most of its cost
    bp = 1; bmax = -1
    for (p = 1; p <= nper; p++) if (B_cost_p[bk, p] + 0 > bmax) { bmax = B_cost_p[bk, p] + 0; bp = p }
    printf "  %s  %s%s%s %9s  %s%s calls%s\n", rp(bucket_label(bk, bucket_unit), lw), PC[bp], hbar(B_cost[bk] / max_cost, 36), CR, \
      money(B_cost[bk]), CD, commas(B_calls[bk] + 0), CR
  }

  # ---- Models ----
  section("Models")
  nmod = sort_desc(mod_cost, mord)
  mw = (nper > 3) ? 10 : 12
  printf "  %s%-28s%s", CD, "Model", CR
  for (p = 1; p <= nper; p++) printf " %s%*s%s", PC[p] CB, mw, substr(plab[p], 1, mw), CR
  if (nper > 1) printf " %s%*s%s", CB, mw, "Total", CR
  printf " %s%7s %9s%s\n", CD, "Share", "Calls", CR
  printf "  %s%s%s\n", CD, repeat("─", 28 + (mw + 1) * (nper + (nper > 1)) + 18), CR
  for (i = 1; i <= nmod; i++) {
    mk = mord[i]
    printf "  %s", rp(substr(mk, 1, 26) ((mk in unpriced) ? " *" : ""), 28)
    for (p = 1; p <= nper; p++) {
      if (PM_calls[p, mk] + 0 == 0) printf " %s%s%s", CD, lp("–", mw), CR
      else printf " %*s", mw, money(PM_cost[p, mk])
    }
    if (nper > 1) printf " %s%*s%s", CB, mw, money(mod_cost[mk]), CR
    printf " %7s %9s\n", pct(mod_cost[mk], total_cost), commas(mod_calls[mk])
  }
  nun = 0
  for (k in unpriced) nun++
  if (nun > 0) printf "\n  %s* no price found; costed at default Sonnet rates%s\n", CD, CR

  # ---- Monthly breakdown: only for one range that spans several months ----
  nm = sort_keys(month_cost, sorted_months)
  if (nper == 1 && nm > 1) {
    section("By month")
    for (i = 1; i <= nm; i++) {
      ym = sorted_months[i]
      printf "  %-10s %12s %10s\n", months_arr[substr(ym, 6, 2) + 0] " " substr(ym, 1, 4), format_tokens(month_tokens[ym]), money(month_cost[ym])
    }
  }

  # ---- Top tools / MCP / skills / commands / subagents ----
  for (ci = 1; ci <= ncat; ci++) print_top(cats[ci])

  # ---- Uniqueness ----
  section("Counted once each")
  printf "  %s%-22s %12s %12s %12s   %s%s\n", CD, "", "Log lines", "Unique", "Copies", "Unique by", CR
  printf "  %-22s %12s %12s %12s   %s%s%s\n", "API responses", commas(raw_u), commas(uniq_u), commas(raw_u - uniq_u), CD, "message id", CR
  printf "  %-22s %12s %12s %12s   %s%s%s\n", "Tool and MCP calls", commas(raw_t), commas(uniq_t), commas(raw_t - uniq_t), CD, "tool_use id", CR
  printf "  %-22s %12s %12s %12s   %s%s%s\n", "Slash commands", commas(raw_c), commas(uniq_c), commas(raw_c - uniq_c), CD, "message uuid", CR
  printf "  %sCopies come from streamed replies (one line per block) and resumed or forked sessions.%s\n", CD, CR

  printf "\n  %sCosts are estimates at API list prices, not your subscription bill.%s\n", CD, CR

  if (html_file != "") {
    write_html()
    printf "\n  %sHTML report:%s %s\n", CB, CR, html_file
  }
  printf "\n"
}

function tc(code) { return nocolor ? "" : "\033[" code "m" }

# Display width of a UTF-8 string (awk runs with LC_ALL=C, so length() counts bytes)
function dw(s,    t, n) { t = s; n = gsub(/[\200-\277]/, "", t); return length(s) - n }
function lp(s, w) { return repeat(" ", w - dw(s)) s }
function rp(s, w) { return s repeat(" ", w - dw(s)) }

function section(t) { printf "\n  %s▍%s%s\n\n", CB CC, t, CR }

# One comparison row; style "b" bold, "d" dim label; chg is the "vs prev" cell
function crow(label, vals, style, change,    p) {
  if (style == "b")      printf "  %s%-22s%s", CB, label, CR
  else if (style == "d") printf "  %s%-22s%s", CD, label, CR
  else                   printf "  %-22s", label
  for (p = 1; p <= nper; p++) printf " %s%s%s", (style == "b" ? CB : ""), lp(vals[p], colw), CR
  if (nper > 1) printf " %s", change
  printf "\n"
}

# Change of the last period against the one before, as a 10-wide cell.
# cost = 1 colours a rise red and a fall green; otherwise it stays dim.
function chg(arr, cost,    a, b, d, s, col) {
  a = arr[nper - 1] + 0; b = arr[nper] + 0
  if (a == 0) return CD lp("–", 10) CR
  d = (b - a) / a * 100
  s = sprintf("%+.0f%%", d)
  col = CD
  if (cost && d >= 0.5)  col = CRD
  if (cost && d <= -0.5) col = CG
  return col sprintf("%10s", s) CR
}

function chg_pt(arr,    d, col) {
  d = arr[nper] - arr[nper - 1]
  if (d > -0.05 && d < 0.05) d = 0   # no "-0.0 pt"
  col = (d > 0.05) ? CG : ((d < -0.05) ? CRD : CD)
  return col sprintf("%10s", sprintf("%+.1f pt", d)) CR
}

# Horizontal bar with eighth-block resolution, padded to width cells
function hbar(frac, width,    cells, full, part, s) {
  if (frac < 0) frac = 0
  if (frac > 1) frac = 1
  cells = frac * width
  full = int(cells)
  part = int((cells - full) * 8)
  s = repeat("█", full)
  if (part > 0) { s = s substr("▏▎▍▌▋▊▉", (part - 1) * 3 + 1, 3); full++ }
  else if (full == 0 && frac > 0) { s = "▏"; full = 1 }
  return s repeat(" ", width - full)
}

# Stacked bar of the four cost kinds, width cells
function stackbar(kc, total, width,    j, cells, used, s, w) {
  s = ""; used = 0
  if (total <= 0) return repeat(" ", width)
  for (j = 1; j <= 4; j++) {
    w = (j == 4) ? width - used : int(kc[j] / total * width + 0.5)
    if (used + w > width) w = width - used
    if (w < 0) w = 0
    # without colour each kind gets its own shade so the split stays readable
    s = s KC[j] repeat(nocolor ? substr("█▓▒░", (j - 1) * 3 + 1, 3) : "█", w) CR
    used += w
  }
  return s
}

function print_top(cat,    tot, ord, n, i, p, key, lim, nw) {
  delete tot
  n = cat_totals(cat, tot)
  section("Top " cat_title[cat])
  if (n == 0) { printf "  %s(none)%s\n", CD, CR; return }
  n = sort_desc(tot, ord)
  lim = (n < top_n) ? n : top_n
  nw = 34
  printf "  %-*s", nw, ""
  for (p = 1; p <= nper; p++) printf " %s%10s%s", PC[p] CB, substr(plab[p], 1, 10), CR
  if (nper > 1) printf " %s%10s%s", CB, "Total", CR
  printf "\n  %s%s%s\n", CD, repeat("─", nw + 11 * (nper + (nper > 1))), CR
  for (i = 1; i <= lim; i++) {
    key = ord[i]
    printf "  %-*s", nw, substr(key, 1, nw)
    for (p = 1; p <= nper; p++) {
      if (cnt[cat, p, key] + 0 == 0) printf " %s%s%s", CD, lp("–", 10), CR
      else printf " %10s", commas(cnt[cat, p, key])
    }
    if (nper > 1) printf " %s%10s%s", CB, commas(tot[key]), CR
    printf "\n"
  }
  if (n > lim) printf "  %s… %d more%s\n", CD, n - lim, CR
}

function repeat(s, n,    r) {
  r = ""
  while (n-- > 0) r = r s
  return r
}

# ============================ HTML REPORT ============================
function o(s) { print s > html_file }

function pcolor(p) { return "var(--p" ((p - 1) % 5 + 1) ")" }

function write_html(    sh, p, i, j, n, key, tot, ord, lim, mx, w, maxday, days, nd, d, c, cat, ci, seg, parts, kinds, kcol, kfg, ktok, kc, kn, tin, mord2, nm2, mk) {
  o("<!doctype html><html lang='en'><head><meta charset='utf-8'>")
  o("<meta name='viewport' content='width=device-width,initial-scale=1'>")
  o("<title>Claude Code Usage</title>")
  o("<style>")
  o(":root{--bg:#f6f5f1;--card:#ffffff;--ink:#1d1c19;--muted:#6f6d66;--line:#e7e4dc;--soft:#f1efe9;")
  o("--p1:#5b6cf0;--p2:#e08a2e;--p3:#1f9e8a;--p4:#c2527a;--p5:#8b5cf6;--k1:#6c7cf5;--k2:#e3a33b;--k3:#2eaf8f;--k4:#b8b4aa;--good:#23915a}")
  o("@media (prefers-color-scheme:dark){:root:not([data-theme='light']){--bg:#131311;--card:#1c1c19;--ink:#ecebe5;--muted:#9c9a91;--line:#2d2c28;--soft:#24231f}}")
  o(":root[data-theme='dark']{--bg:#131311;--card:#1c1c19;--ink:#ecebe5;--muted:#9c9a91;--line:#2d2c28;--soft:#24231f}")
  o(":root{--ok:#1f8a52;--info:#2f6fd6;--bad:#d03b3b}@media (prefers-color-scheme:dark){:root:not([data-theme='light']){--ok:#4cc38a;--info:#6ea8ff;--bad:#ff6b6b}}:root[data-theme='dark']{--ok:#4cc38a;--info:#6ea8ff;--bad:#ff6b6b}")
  o("*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased}")
  o(".wrap{max-width:1160px;margin:0 auto;padding:40px 16px 72px}")
  o("h1{font-size:30px;letter-spacing:-.02em;margin:0 0 6px}h2{font-size:19px;letter-spacing:-.01em;margin:0 0 14px}")
  o(".sub{color:var(--muted);margin:0}.legend{display:flex;flex-wrap:wrap;gap:8px 18px;margin-top:14px;color:var(--muted);font-size:14px}")
  o(".chip{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:7px;vertical-align:0}")
  o("section{margin-top:40px}.grid{display:grid;gap:16px;grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}.grid.one{grid-template-columns:1fr}")
  o(".card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:18px 20px;min-width:0}")
  o(".kh{display:flex;align-items:center;gap:8px;font-weight:600}.kl{color:var(--muted);font-size:13px;margin:2px 0 12px}")
  o(".big{font-size:32px;font-weight:700;letter-spacing:-.02em;font-variant-numeric:tabular-nums}")
  o(".stats{display:grid;grid-template-columns:1fr 1fr;gap:10px 16px;margin-top:12px}.stats div{font-size:13px;color:var(--muted)}.stats b{display:block;font-size:16px;color:var(--ink);font-variant-numeric:tabular-nums}")
  o(".tw{overflow-x:auto}table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums;font-size:14px}")
  o("th,td{padding:9px 10px;border-bottom:1px solid var(--line);text-align:right;white-space:nowrap}th{color:var(--muted);font-weight:600;font-size:13px}")
  o("th:first-child,td:first-child{text-align:left}tr.sub td:first-child{padding-left:28px;color:var(--muted)}tr.tot td{font-weight:700}")
  o("td.list{text-align:left;white-space:normal;min-width:130px;font-size:13px;color:var(--muted)}td.list b{color:var(--ink);font-weight:600}")
  o(".stack{display:flex;height:24px;border-radius:8px;overflow:hidden;background:var(--soft)}.stack span{display:flex;align-items:center;justify-content:center;height:100%;font-size:11px;font-weight:600;white-space:nowrap;overflow:hidden}.cap{margin:-2px 0 10px 80px;font-size:12px;color:var(--muted);font-variant-numeric:tabular-nums}")
  o(".row{display:grid;grid-template-columns:68px 1fr 84px;gap:12px;align-items:center;margin:6px 0;font-size:13px;font-variant-numeric:tabular-nums}.row .v{text-align:right}")
  o(".top{list-style:none;margin:0;padding:0}.top li{padding:8px 0;border-bottom:1px solid var(--line)}.top li:last-child{border-bottom:0}")
  o(".top .name{display:flex;justify-content:space-between;gap:10px;font-size:14px}.top .name span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}")
  o(".top .name b{font-variant-numeric:tabular-nums}.bars{margin-top:5px;display:grid;gap:3px}")
  o(".bar{display:grid;grid-template-columns:1fr 72px;gap:8px;align-items:center;font-size:12px;color:var(--muted);font-variant-numeric:tabular-nums}")
  o(".bar i{display:block;height:6px;border-radius:3px}.bar em{font-style:normal;text-align:right}")
  o(".keys{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:13px;color:var(--muted);margin-bottom:12px}")
  o(".note{color:var(--muted);font-size:14px}.note li{margin:6px 0}")
  o(".grid.cards{grid-template-columns:repeat(auto-fit,minmax(200px,1fr))}.grid.cards .big{font-size:28px}.grid.cards .stats{gap:8px 12px}")
  o(".chartwrap{overflow-x:auto}.chart{display:block;width:100%;min-width:640px;height:auto}.chart text{fill:var(--muted);font-size:12px;font-family:inherit}")
  o(".chart .gl{stroke:var(--line)}.chart .ln{fill:none;stroke:var(--ink);stroke-width:2;opacity:.75}.chart .dot{fill:var(--card);stroke:var(--ink);stroke-width:1.5;opacity:.85}.chart .hit{fill:transparent}.chart .hit:hover{fill:var(--soft);opacity:.5}")
  o(".lk{display:inline-block;width:18px;height:0;border-top:2px solid var(--ink);opacity:.75;margin-right:7px;vertical-align:4px}")
  o("td small{display:block;color:var(--muted);font-size:12px;font-weight:400}td b{font-weight:650}")
  o(".tv{position:absolute;opacity:0;pointer-events:none}.tvl{display:inline-block;padding:7px 16px;border:1px solid var(--line);background:var(--card);color:var(--muted);cursor:pointer;font-size:14px;user-select:none}")
  o(".tvl.lm{border-radius:0;margin-left:-1px}.tvl.l1{border-radius:10px 0 0 10px}.tvl.l2{border-radius:0 10px 10px 0;margin-left:-1px}.tv:checked+.tvl{background:var(--ink);color:var(--bg);border-color:var(--ink)}.tv:focus-visible+.tvl{outline:2px solid var(--p1);outline-offset:2px}")
  o(".views{margin-top:16px}.views .by-item,.views .by-period{display:none}#tv1:checked~.views .by-item{display:grid}#tv2:checked~.views .by-period{display:block}")
  o(".pcard{margin-bottom:16px}.pgrid{display:grid;gap:18px 24px;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));margin-top:12px}")
  o(".pgrid h3{font-size:13px;color:var(--muted);font-weight:600;margin:0 0 6px;text-transform:uppercase;letter-spacing:.04em}")
  o(".mini{list-style:none;margin:0;padding:0}.mini li{padding:5px 0;font-size:13px}.mini .name{display:flex;justify-content:space-between;gap:8px}.mini .name span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}")
  o(".mini i{display:block;height:4px;border-radius:2px;margin-top:4px}")
  o(".top small.sh{color:var(--muted);font-weight:400;font-size:12px;margin-left:4px}.top small.tr{color:var(--muted);font-size:11px;margin-left:8px;font-weight:400}.top small.tr.new{color:var(--good);font-weight:600}")
  o(".sv{font-weight:600;cursor:help}.sv.g{color:var(--ok)}.sv.b{color:var(--info)}.sv.r{color:var(--bad)}")
  o("h3.ch{font-size:15px;margin:26px 0 4px}p.cd{margin:0 0 10px;max-width:900px}")
  o("summary{cursor:pointer;list-style:none;display:flex;align-items:center;gap:10px;font-size:19px;font-weight:700;letter-spacing:-.01em;margin:0 0 14px;user-select:none}summary::-webkit-details-marker{display:none}")
  o("summary::before{content:'';width:8px;height:8px;border-right:2px solid var(--muted);border-bottom:2px solid var(--muted);transform:rotate(-45deg);transition:transform .15s;flex:none}details[open]>summary::before{transform:rotate(45deg)}details:not([open])>summary{margin-bottom:0}summary:focus-visible{outline:2px solid var(--p1);outline-offset:4px;border-radius:4px}")
  o("</style></head><body><div class='wrap'>")

  # --- Header ---
  o("<header><h1>Claude Code usage</h1>")
  o("<p class='sub'>Costs are estimates at public API prices, not your bill · prices from " (loaded_live > 0 ? "LiteLLM (" loaded_live " models)" : "a built-in list") " · made " hesc(gen_time) "</p>")
  o("<div class='legend'>")
  for (p = 1; p <= nper; p++)
    o("<span><i class='chip' style='background:" pcolor(p) "'></i><b>" hesc(plab[p]) "</b> · " hesc(plong[p]) "</span>")
  o("</div></header>")

  # --- Period cards ---
  o("<section><div class='grid cards'>")
  for (p = 1; p <= nper; p++) {
    tin = P_in[p] + P_cw5[p] + P_cw1h[p] + P_cr[p]
    o("<div class='card'><div class='kh'><i class='chip' style='background:" pcolor(p) "'></i>" hesc(plab[p]) "</div>")
    o("<div class='kl'>" hesc(plong[p]) "</div><div class='big'>" money(P_cost[p]) "</div>")
    o("<div class='stats'><div>API calls<b>" commas(P_calls[p]) "</b></div><div>Hit rate<b>" pct(P_cr[p], tin) "</b></div>")
    o("<div>Input<b>" format_tokens(tin) "</b></div><div>Output<b>" format_tokens(P_out[p]) "</b></div>")
    o("<div>Tool calls<b>" commas(csum["tool", p] + csum["mcp", p]) "</b></div><div>No cache<b>" money(P_nc[p]) "</b></div></div></div>")
  }
  o("</div></section>")

  # --- Comparison table ---
  o("<section><details open><summary>" (nper > 1 ? "Comparison" : "Summary") "</summary><p class='note cd'>The same numbers for each period, side by side. <b>Input</b> is everything sent to the model, which includes the whole conversation again on every call. The lines under it show how much of that input was cheap (read from cache) and how much was expensive (written to cache or not cached). Some numbers are colored: <span class='sv g'>green</span> is healthy, <span class='sv b'>blue</span> is worth a look, <span class='sv r'>red</span> means something is wrong. Hover a colored number to see why.</p><div class='card tw'><table><thead><tr><th></th>")
  for (p = 1; p <= nper; p++) o("<th><i class='chip' style='background:" pcolor(p) "'></i>" hesc(plab[p]) "</th>")
  o("</tr></thead><tbody>")
  for (p = 1; p <= nper; p++) v[p] = commas(P_calls[p]);                                             hrow("API calls", v, "")
  for (p = 1; p <= nper; p++) v[p] = format_tokens(P_in[p] + P_cw5[p] + P_cw1h[p] + P_cr[p]);       hrow("Input tokens, total", v, "")
  for (p = 1; p <= nper; p++) v[p] = format_tokens(P_cr[p]) " · " money(P_ccr[p]);                   hrow("Cache read (hit)", v, "sub")
  for (p = 1; p <= nper; p++) v[p] = format_tokens(P_cw5[p]);                                        hrow("Cache write, 5 min", v, "sub")
  for (p = 1; p <= nper; p++) v[p] = format_tokens(P_cw1h[p]);                                       hrow("Cache write, 1 hour", v, "sub")
  for (p = 1; p <= nper; p++) { sh = pcts(P_cw5[p] + P_cw1h[p], tin_of(p)); v[p] = paint(lvl_lo(sh, 3, 8), format_tokens(P_cw5[p] + P_cw1h[p]) " · " money(P_ccw[p]), sprintf("%.1f%% of input tokens were cache writes. Under 3%% is healthy, over 8%% needs attention.", sh)) };  hrow("Cache writes (miss)", v, "sub")
  for (p = 1; p <= nper; p++) { sh = pcts(P_in[p], tin_of(p)); v[p] = paint(lvl_lo(sh, 0.5, 2), format_tokens(P_in[p]) " · " money(P_cin[p]), sprintf("%.2f%% of input tokens were not cached. Under 0.5%% is healthy, over 2%% needs attention.", sh)) };  hrow("Not cached (miss)", v, "sub")
  for (p = 1; p <= nper; p++) { sh = pcts(P_cr[p], tin_of(p)); v[p] = paint(lvl_hi(sh, 95, 90), pct(P_cr[p], tin_of(p)), sprintf("%.1f%% of input tokens were cache reads. 95%% or more is healthy, under 90%% needs attention.", sh)) };  hrow("Cache hit rate", v, "sub")
  for (p = 1; p <= nper; p++) v[p] = format_tokens(P_out[p]) " · " money(P_cout[p]);                 hrow("Output tokens", v, "")
  for (p = 1; p <= nper; p++) {
    if (p > 1 && pe[p] <= now && P_cost[p - 1] > 0) { sh = (P_cost[p] / P_cost[p - 1] - 1) * 100; v[p] = paint(lvl_lo(sh, 10.0001, 30), money(P_cost[p]), sprintf("%+.0f%% vs %s. Flat, or up to 10%%, is fine; up 10%% to 30%% is worth a look; up over 30%% needs attention.", sh, plab[p - 1])) }
    else v[p] = money(P_cost[p])
  }
  hrow("Est. API cost", v, "tot")
  for (p = 1; p <= nper; p++) v[p] = money(P_nc[p]);                                                 hrow("Cost with no cache", v, "")
  for (ci = 1; ci <= nhcat; ci++) {
    cat = hcats[ci]
    o("<tr><td>Top " tolower(cat_title[cat]) "</td>")
    for (p = 1; p <= nper; p++) o("<td class='list'>" top_inline(cat, p, 5) "</td>")
    o("</tr>")
  }
  o("</tbody></table></div></details></section>")

  # --- Where the money goes ---
  split("Cache read (hit) · good|Cache write (miss) · avoid|Output|Input, not cached · avoid", kinds, "|")
  split("var(--k1)|var(--k2)|var(--k3)|var(--k4)", kcol, "|")
  split("#fff|#1d1c19|#fff|#1d1c19", kfg, "|")
  o("<section><details open><summary>Where the money goes</summary><div class='card'>")
  o("<p class='note' style='margin:0 0 12px'>Each bar splits that period's cost by what you paid for. <b>Cache read is the good part</b>: the model re-reads a conversation it already stored, at about a tenth of the normal price. <b>Cache write is the part to avoid</b>: it means storing the conversation again, at 1.25 to 2 times the normal price. <b>Input, not cached</b> is full price. <b>Output</b> is what the model wrote back. Under each bar, the same split in tokens shows how well the cache is working.</p><div class='keys'>")
  for (j = 1; j <= 4; j++) o("<span><i class='chip' style='background:" kcol[j] "'></i>" kinds[j] "</span>")
  o("</div>")
  for (p = 1; p <= nper; p++) {
    kc[1] = P_ccr[p]; kc[2] = P_ccw[p]; kc[3] = P_cout[p]; kc[4] = P_cin[p]
    o("<div class='row'><span>" hesc(plab[p]) "</span><div class='stack'>")
    for (j = 1; j <= 4; j++) {
      w = (P_cost[p] > 0) ? kc[j] / P_cost[p] * 100 : 0
      if (w > 0) o("<span style='width:" sprintf("%.2f", w) "%;background:" kcol[j] ";color:" kfg[j] "' title='" kinds[j] ": " money(kc[j]) " (" sprintf("%.1f", w) "% of cost)'>" ((w >= 6) ? sprintf("%.0f%%", w) : "") "</span>")
    }
    o("</div><span class='v'>" money(P_cost[p]) "</span></div>")
    tin = P_in[p] + P_cw5[p] + P_cw1h[p] + P_cr[p]
    o("<div class='cap'>Of input tokens: <b>" pct(P_cr[p], tin) "</b> cache read · " pct(P_cw5[p] + P_cw1h[p], tin) " cache write · " pct(P_in[p], tin) " not cached</div>")
  }
  o("</div></details></section>")

  write_cache()
  write_context()
  write_models()
  write_activity()
  write_top()

  # --- Notes ---
  o("<section><details open><summary>How to read this</summary><div class='card'><ul class='note' style='margin:0;padding-left:18px'>")
  o("<li><b>These costs are estimates.</b> They use public API prices, so they are not your Pro or Max bill, which is measured differently.</li>")
  o("<li><b>Three kinds of input.</b> <b>Cache read</b>: the model re-reads a conversation it already stored, at about a tenth of the normal price. <b>Cache write</b>: the model stores new content, for 5 minutes (1.25x the price) or 1 hour (2x). <b>Not cached</b>: normal price (1x). Output is never cached.</li>")
  o("<li><b>What makes the cost go up:</b> the number of calls, times the size of the conversation, times the model's price. Every tool call is one more call that re-reads the whole conversation.</li>")
  o("<li><b>Each thing is counted once.</b> Some log lines are copies (from streamed replies, or from resumed and forked sessions). API responses go from " commas(raw_u) " log lines to " commas(uniq_u) " unique ones, tool and MCP calls from " commas(raw_t) " to " commas(uniq_t) ", and slash commands from " commas(raw_c) " to " commas(uniq_c) ". Each is counted at its earliest time. Days use your local time.</li>")
  o("</ul></div></details></section>")
  o("</div></body></html>")
  close(html_file)
}

# --- Cache: how much of the input was read from cache, against written or not cached ---
function write_cache(    lo, hi, p, tin, w, j, kn, kc, kf, kv, nb, bk, i, k, r, rmin, ymin, W, H, L, R, T, B, pw, ph, g, y, x, pts, step, tip, slot) {
  split("Cache read (hit) · good|Cache write (miss) · avoid|Not cached · avoid", kn, "|")
  split("var(--k1)|var(--k2)|var(--k4)", kc, "|")
  split("#fff|#1d1c19|#1d1c19", kf, "|")
  o("<section><details open><summary>Cache: read vs write</summary><div class='card'>")
  o("<p class='note' style='margin:0 0 12px'>The same spending, counted in <b>tokens</b> instead of dollars. Almost every token should be a <b>cache read</b>: the model is re-reading a conversation it already stored, which is cheap. A <b>cache write</b> means it had to store the conversation again, usually because you were idle for a while or changed the conversation. More reads and fewer writes means a lower bill.</p><div class='keys'>")
  for (j = 1; j <= 3; j++) o("<span><i class='chip' style='background:" kc[j] "'></i>" kn[j] "</span>")
  o("</div>")
  for (p = 1; p <= nper; p++) {
    tin = P_in[p] + P_cw5[p] + P_cw1h[p] + P_cr[p]
    if (tin <= 0) continue
    kv[1] = P_cr[p]; kv[2] = P_cw5[p] + P_cw1h[p]; kv[3] = P_in[p]
    o("<div class='row'><span>" hesc(plab[p]) "</span><div class='stack'>")
    for (j = 1; j <= 3; j++) {
      w = kv[j] / tin * 100
      if (w > 0) o("<span style='width:" sprintf("%.2f", w) "%;background:" kc[j] ";color:" kf[j] "' title='" kn[j] ": " format_tokens(kv[j]) " tokens (" sprintf("%.1f", w) "% of input)'>" ((w >= 6) ? sprintf("%.0f%%", w) : "") "</span>")
    }
    o("</div><span class='v'>" format_tokens(tin) "</span></div>")
    o("<div class='cap'><b>" pct(P_cr[p], tin) "</b> cache read · " pct(kv[2], tin) " cache write · " pct(P_in[p], tin) " not cached" ((kv[2] > 0) ? " · <b>" sprintf("%.0f", P_cr[p] / kv[2]) " tokens read for every token written</b>" : "") "</div>")
  }
  # hit rate per bucket
  nb = sort_keys(B_in, bk)
  rmin = 100
  for (i = 1; i <= nb; i++) if (B_in[bk[i]] > 0) { r = B_cr[bk[i]] / B_in[bk[i]] * 100; if (r < rmin) rmin = r }
  if (nb >= 2) {
    ymin = 80                                  # hit rates sit near the top, so start at 80% (lower only if the data does)
    if (rmin < 80) ymin = int((rmin - 1) / 5) * 5
    if (ymin < 0) ymin = 0
    W = 1100; H = 300; L = 70; R = 24; T = 16; B = 44
    pw = W - L - R; ph = H - T - B; slot = pw / nb
    o("<h3 class='ch'>How well did the cache hold up each " unit_word(bucket_unit) "?</h3>")
    o("<p class='note cd'>The <b>cache hit rate</b> is the share of tokens that were read from cache. Higher is better. A dip means the stored conversation had gone cold (you were idle for a while, started a new session or cleared the chat), so it had to be stored again at a higher price. The axis starts at " ymin "%, not at zero, so small dips are easy to see. The colors match the numbers in the table: green is 95% or more, blue is 90% to 95%, red is under 90%.</p>")
    o("<div class='chartwrap'><svg class='chart' viewBox='0 0 " W " " H "' role='img' aria-label='Cache hit rate per " unit_word(bucket_unit) "'>")
    for (g = 0; g <= 4; g++) {
      y = T + ph - ph * g / 4
      o("<line class='gl' x1='" L "' x2='" (W - R) "' y1='" sprintf("%.1f", y) "' y2='" sprintf("%.1f", y) "'/>")
      o("<text x='" (L - 10) "' y='" sprintf("%.1f", y + 4) "' text-anchor='end'>" sprintf("%g", ymin + (100 - ymin) * g / 4) "%</text>")
    }
    # colored bands match the status marks: 95%+ healthy, 90 to 95% worth a look, under 90% needs attention
    for (g = 1; g <= 3; g++) {
      lo = (g == 1) ? ymin : (g == 2) ? 90 : 95
      hi = (g == 1) ? 90 : (g == 2) ? 95 : 100
      if (lo < ymin) lo = ymin
      if (hi <= ymin) continue
      o("<rect x='" L "' width='" pw "' y='" sprintf("%.1f", T + ph - (hi - ymin) / (100 - ymin) * ph) "' height='" sprintf("%.1f", (hi - lo) / (100 - ymin) * ph) "' fill='" ((g == 1) ? "#d64545" : (g == 2) ? "#3b82f6" : "#23915a") "' opacity='.09'/>")
    }
    pts = ""
    for (i = 1; i <= nb; i++) {
      k = bk[i]
      if (B_in[k] <= 0) continue
      r = B_cr[k] / B_in[k] * 100
      x = L + slot * (i - 0.5); y = T + ph - (r - ymin) / (100 - ymin) * ph
      pts = pts sprintf("%.1f,%.1f ", x, y)
      tip = bucket_label(k, bucket_unit) ": " sprintf("%.1f", r) "% hit rate · " format_tokens(B_cr[k]) " of " format_tokens(B_in[k]) " input tokens read from cache"
      o("<g><title>" hesc(tip) "</title><rect class='hit' x='" sprintf("%.1f", L + slot * (i - 1)) "' y='" T "' width='" sprintf("%.2f", slot) "' height='" ph "'/>" ((nb <= 60) ? "<circle class='dot' cx='" sprintf("%.1f", x) "' cy='" sprintf("%.1f", y) "' r='3'/>" : "") "</g>")
    }
    o("<polyline class='ln' style='stroke:var(--p1)' points='" pts "'/>")
    step = int((nb + 11) / 12)
    if (step < 1) step = 1
    for (i = 1; i <= nb; i += step)
      o("<text x='" sprintf("%.1f", L + slot * (i - 0.5)) "' y='" (H - B + 22) "' text-anchor='middle'>" hesc(bucket_tick(bk[i], bucket_unit)) "</text>")
    o("</svg></div>")
  }
  o("</div></details></section>")
}

# --- Cost chart: bars = cost (left axis, stacked by period), line = API calls (right axis) ---
function write_chart(    nb, bk, i, p, maxc, maxn, yc, yn, W, H, L, R, T, B, pw, ph, slot, bw, x, y, h, c, g, step, pts, cx, cy, tip, lab) {
  nb = sort_keys(B_cost, bk)
  if (nb == 0) return
  maxc = 0; maxn = 0
  for (i = 1; i <= nb; i++) {
    if (B_cost[bk[i]] > maxc) maxc = B_cost[bk[i]]
    if (B_calls[bk[i]] > maxn) maxn = B_calls[bk[i]]
  }
  yc = nice_max(maxc); yn = nice_max(maxn)
  W = 1100; H = 360; L = 70; R = 64; T = 16; B = 44
  pw = W - L - R; ph = H - T - B
  slot = pw / nb; bw = slot * 0.7
  if (bw < 1) bw = 1
  o("<h3 class='ch'>Cost and requests per " unit_word(bucket_unit) "</h3><p class='note cd'>The bars show what each " unit_word(bucket_unit) " cost (left scale). The line shows how many API calls (requests) you made (right scale). Cost usually goes up and down with the number of requests.</p><div class='keys'>")
  if (nper > 1) for (p = 1; p <= nper; p++) o("<span><i class='chip' style='background:" pcolor(p) "'></i>" hesc(plab[p]) "</span>")
  else o("<span><i class='chip' style='background:" pcolor(1) "'></i>Cost (left axis)</span>")
  o("<span><i class='lk'></i>API calls (right axis)</span></div><div class='chartwrap'>")
  o("<svg class='chart' viewBox='0 0 " W " " H "' role='img' aria-label='Cost and API calls per " unit_word(bucket_unit) "'>")
  for (g = 0; g <= 4; g++) {
    y = T + ph - ph * g / 4
    o("<line class='gl' x1='" L "' x2='" (W - R) "' y1='" sprintf("%.1f", y) "' y2='" sprintf("%.1f", y) "'/>")
    o("<text x='" (L - 10) "' y='" sprintf("%.1f", y + 4) "' text-anchor='end'>" money(yc * g / 4) "</text>")
    o("<text x='" (W - R + 10) "' y='" sprintf("%.1f", y + 4) "'>" format_tokens(yn * g / 4) "</text>")
  }
  pts = ""
  for (i = 1; i <= nb; i++) {
    k = bk[i]
    x = L + slot * (i - 1) + (slot - bw) / 2
    lab = bucket_label(k, bucket_unit)
    tip = lab ": " money(B_cost[k]) " · " commas(B_calls[k] + 0) " calls"
    o("<g><title>" hesc(tip) "</title><rect class='hit' x='" sprintf("%.1f", L + slot * (i - 1)) "' y='" T "' width='" sprintf("%.2f", slot) "' height='" ph "'/>")
    y = T + ph
    for (p = 1; p <= nper; p++) {
      c = B_cost_p[k, p] + 0
      if (c <= 0) continue
      h = c / yc * ph
      y -= h
      o("<rect x='" sprintf("%.1f", x) "' y='" sprintf("%.1f", y) "' width='" sprintf("%.2f", bw) "' height='" sprintf("%.2f", h) "' rx='" (bw > 6 ? 2 : 0) "' fill='" pcolor(p) "'/>")
    }
    o("</g>")
    cx = L + slot * (i - 0.5); cy = T + ph - (B_calls[k] + 0) / yn * ph
    pts = pts sprintf("%.1f,%.1f ", cx, cy)
  }
  o("<polyline class='ln' points='" pts "'/>")
  if (nb <= 60)
    for (i = 1; i <= nb; i++) {
      k = bk[i]
      o("<circle class='dot' cx='" sprintf("%.1f", L + slot * (i - 0.5)) "' cy='" sprintf("%.1f", T + ph - (B_calls[k] + 0) / yn * ph) "' r='3'><title>" hesc(bucket_label(k, bucket_unit) ": " commas(B_calls[k] + 0) " calls") "</title></circle>")
    }
  # about 12-16 ticks; hourly ticks sit on round hours so each midnight shows its date
  if (bucket_unit == "hour") {
    split("1 2 3 6 12 24", hs, " ")
    for (g = 1; g <= 6; g++) { step = hs[g] + 0; if (nb / step <= 16) break }
    for (i = 1; i <= nb; i++)
      if ((substr(bk[i], 12, 2) + 0) % step == 0)
        o("<text x='" sprintf("%.1f", L + slot * (i - 0.5)) "' y='" (H - B + 22) "' text-anchor='middle'>" hesc(bucket_tick(bk[i], bucket_unit)) "</text>")
  } else {
    step = int((nb + 11) / 12)
    if (step < 1) step = 1
    for (i = 1; i <= nb; i += step)
      o("<text x='" sprintf("%.1f", L + slot * (i - 0.5)) "' y='" (H - B + 22) "' text-anchor='middle'>" hesc(bucket_tick(bk[i], bucket_unit)) "</text>")
  }
  o("</svg></div>")
}

# --- Context size ---
# One API call re-sends the whole conversation, so its context is input + cache write + cache read.
# Main conversation only (subagents start small and would pull the numbers down); they get their own row.
# Percentiles come from fixed-width bins (CTX_BIN tokens) instead of a sort: exact to one bin, and fast.
function ctx_bin(x,    b) { b = int(x / CTX_BIN); return (b > CTX_MAXBIN) ? CTX_MAXBIN : b }

# q-quantile of hist[key, 0..maxb] holding `total` values; the middle of the bin it falls in
function hist_pct(hist, key, maxb, total, q, width,    b, run, need) {
  need = total * q; run = 0
  for (b = 0; b <= maxb; b++) {
    run += hist[key, b]
    if (run > 0 && run >= need) return (b + 0.5) * width
  }
  return 0
}

# shell sort of one session's calls by time (the readers give them in no order)
function sess_sort(s, n,    gap, i, j, te, tc, tp) {
  for (gap = int(n / 2); gap > 0; gap = int(gap / 2))
    for (i = gap + 1; i <= n; i++) {
      te = se[s, i]; tc = sc[s, i]; tp = sp[s, i]
      for (j = i; j > gap && se[s, j - gap] > te; j -= gap) {
        se[s, j] = se[s, j - gap]; sc[s, j] = sc[s, j - gap]; sp[s, j] = sp[s, j - gap]
      }
      se[s, j] = te; sc[s, j] = tc; sp[s, j] = tp
    }
}

function analyze_context(    k, s, n, j, p, x, b, ctx, pk, nc, sp1, sn, sids, ns) {
  CTX_BIN = 5000; CTX_MAXBIN = 260       # up to 1.3M tokens
  CTX_MAXIDX = 400; CTX_MINSESS = 5      # chart: call numbers 1..400, while at least 5 sessions get that far
  CALL_CAP = 3000
  for (k in dk_ep) {
    ctx = dk_input[k] + dk_ccreate[k] + dk_cread[k]
    p = dk_period[k]
    if (dk_side[k]) {
      if (p > 0) { SA_n[p]++; SA_sum[p] += ctx; SA_h[p, ctx_bin(ctx)]++ }
      continue
    }
    if (dk_sid[k] == "") {
      if (p > 0) note_call(p, ctx)
      continue
    }
    sn[dk_sid[k]]++
    se[dk_sid[k], sn[dk_sid[k]]] = dk_ep[k]; sc[dk_sid[k], sn[dk_sid[k]]] = ctx; sp[dk_sid[k], sn[dk_sid[k]]] = p
  }
  for (s in sn) {
    n = sn[s]
    sess_sort(s, n)
    nc = 0; pk = 0; sp1 = 0
    for (j = 1; j <= n; j++) {
      p = sp[s, j]
      if (p == 0) continue
      ctx = sc[s, j]
      note_call(p, ctx)
      if (sp1 == 0) sp1 = p
      nc++
      if (ctx > pk) pk = ctx
      if (j <= CTX_MAXIDX) { IX_n[j]++; IX_sum[j] += ctx; IX_h[j, ctx_bin(ctx)]++ }
    }
    if (nc > 0) {
      SS_n[sp1]++; SS_calls_sum[sp1] += nc; SS_calls_h[sp1, (nc > CALL_CAP) ? CALL_CAP : nc]++
      SS_pk_sum[sp1] += pk; SS_pk_h[sp1, ctx_bin(pk)]++
    }
  }
  ix_max = 0
  for (j = 1; j <= CTX_MAXIDX; j++) { if (IX_n[j] < CTX_MINSESS) break; ix_max = j }
}

function note_call(p, ctx,    b) {
  CT_n[p]++; CT_sum[p] += ctx; CT_h[p, ctx_bin(ctx)]++
  if (ctx > CT_max[p]) CT_max[p] = ctx
}

# "12.3k" style, from format_tokens, for a tokens value
function ctxfmt(x) { return format_tokens(x) }

# % of a period's calls whose context is at or above bin `from` (bins are CTX_BIN tokens wide)
function share_over(p, from,    b, run) {
  run = 0
  for (b = from; b <= CTX_MAXBIN; b++) run += CT_h[p, b]
  return (CT_n[p] > 0) ? run / CT_n[p] * 100 : 0
}

# "250k", "1M" for axis labels
function kfmt(x) { return (x >= 1000000) ? sprintf("%gM", x / 1000000) : sprintf("%gk", x / 1000) }

# Line chart, one line per period. LY[p, i] = y in %, LXL[i] = label of point i, n points, an axis label every tk points.
function line_chart(title, desc, xtitle, ytitle, n, tk,    p, i, W, H, L, R, T, B, pw, ph, ymax, g, y, x, pts, tip, hw, cnt) {
  ymax = 0; cnt = 0
  for (p = 1; p <= nper; p++) if (LOK[p]) { cnt++; for (i = 1; i <= n; i++) if (LY[p, i] > ymax) ymax = LY[p, i] }
  if (cnt == 0 || ymax <= 0) return
  ymax = nice_max(ymax)
  W = 1100; H = 320; L = 70; R = 24; T = 16; B = 50
  pw = W - L - R; ph = H - T - B; hw = pw / (n - 1)
  o("<h3 class='ch'>" hesc(title) "</h3><p class='note cd'>" desc "</p>")
  if (nper > 1) {
    o("<div class='keys'>")
    for (p = 1; p <= nper; p++) if (LOK[p]) o("<span><i class='chip' style='background:" pcolor(p) "'></i>" hesc(plab[p]) "</span>")
    o("</div>")
  }
  o("<div class='chartwrap'><svg class='chart' viewBox='0 0 " W " " H "' role='img' aria-label='" hesc(title) "'>")
  for (g = 0; g <= 4; g++) {
    y = T + ph - ph * g / 4
    o("<line class='gl' x1='" L "' x2='" (W - R) "' y1='" sprintf("%.1f", y) "' y2='" sprintf("%.1f", y) "'/>")
    o("<text x='" (L - 10) "' y='" sprintf("%.1f", y + 4) "' text-anchor='end'>" sprintf("%g", ymax * g / 4) "%</text>")
  }
  for (i = 1; i <= n; i += tk)
    o("<text x='" sprintf("%.1f", L + hw * (i - 1)) "' y='" (H - B + 20) "' text-anchor='middle'>" LXL[i] "</text>")
  o("<text x='" (L + pw / 2) "' y='" (H - 8) "' text-anchor='middle'>" xtitle "</text>")
  o("<text x='14' y='" (T + ph / 2) "' text-anchor='middle' transform='rotate(-90 14 " (T + ph / 2) ")'>" ytitle "</text>")
  for (p = 1; p <= nper; p++) {
    if (!LOK[p]) continue
    pts = ""
    for (i = 1; i <= n; i++) pts = pts sprintf("%.1f,%.1f ", L + hw * (i - 1), T + ph - LY[p, i] / ymax * ph)
    o("<polyline class='ln' style='stroke:" pcolor(p) "' points='" pts "'/>")
    if (n <= 25) for (i = 1; i <= n; i++)
      o("<circle cx='" sprintf("%.1f", L + hw * (i - 1)) "' cy='" sprintf("%.1f", T + ph - LY[p, i] / ymax * ph) "' r='3' fill='" pcolor(p) "'/>")
  }
  for (i = 1; i <= n; i++) {
    tip = LXL[i] ":"
    for (p = 1; p <= nper; p++) if (LOK[p]) tip = tip " " ((nper > 1) ? plab[p] " " : "") sprintf("%.1f%%", LY[p, i]) ((p < nper) ? " ·" : "")
    o("<g><title>" hesc(tip) "</title><rect class='hit' x='" sprintf("%.1f", L + hw * (i - 1) - hw / 2) "' y='" T "' width='" sprintf("%.2f", hw) "' height='" ph "'/></g>")
  }
  o("</svg></div>")
}

function write_context(    sh, p, i, v, k, W, H, L, R, T, B, pw, ph, ymax, g, y, x, ptsA, ptsM, ptsP, slot, tip, step, bins, j, share, lo, hi, kcol, kfg, kname, tot, run, b, lab) {
  o("<section><details open><summary>Context size</summary><div class='card'>")
  o("<p class='note' style='margin:0 0 14px'>Each time Claude answers, it reads the whole conversation so far. The size of that conversation, in tokens, is the <b>context</b>. A bigger context makes every call cost more. This is counted for every API call, not for every message you type, because one message can make Claude call the API many times (for example to use tools). Only your main conversation is counted; helper agents (subagents) get their own row.</p>")
  # per-period table
  o("<div class='tw'><table><thead><tr><th></th>")
  for (p = 1; p <= nper; p++) o("<th><i class='chip' style='background:" pcolor(p) "'></i>" hesc(plab[p]) "</th>")
  o("</tr></thead><tbody>")
  for (p = 1; p <= nper; p++) v[p] = commas(CT_n[p] + 0);                                                   hrow("Main-thread API calls", v, "")
  for (p = 1; p <= nper; p++) {
    if (CT_n[p] > 0) { sh = share_over(p, 40); v[p] = paint(lvl_lo(sh, 25, 50), ctxfmt(CT_sum[p] / CT_n[p]), sprintf("%.0f%% of calls had over 200k tokens of context. Under 25%% is healthy, over 50%% needs attention (bigger conversations cost more on every call).", sh)) }
    else v[p] = "–"
  }
  hrow("Context per call, average", v, "tot")
  for (p = 1; p <= nper; p++) v[p] = (CT_n[p] > 0) ? ctxfmt(hist_pct(CT_h, p, CTX_MAXBIN, CT_n[p], 0.5, CTX_BIN)) : "–";  hrow("Median (50th percentile)", v, "sub")
  for (p = 1; p <= nper; p++) v[p] = (CT_n[p] > 0) ? ctxfmt(hist_pct(CT_h, p, CTX_MAXBIN, CT_n[p], 0.95, CTX_BIN)) : "–"; hrow("95th percentile", v, "sub")
  for (p = 1; p <= nper; p++) v[p] = (CT_n[p] > 0) ? ctxfmt(CT_max[p]) : "–";                               hrow("Largest", v, "sub")
  for (p = 1; p <= nper; p++) v[p] = commas(SS_n[p] + 0);                                                   hrow("Sessions", v, "")
  for (p = 1; p <= nper; p++) v[p] = (SS_n[p] > 0) ? sprintf("%.0f", SS_calls_sum[p] / SS_n[p]) : "–";     hrow("API calls per session, average", v, "sub")
  for (p = 1; p <= nper; p++) v[p] = (SS_n[p] > 0) ? sprintf("%.0f", hist_pct(SS_calls_h, p, CALL_CAP, SS_n[p], 0.5, 1) - 0.5) : "–"; hrow("Median", v, "sub")
  for (p = 1; p <= nper; p++) v[p] = (SS_n[p] > 0) ? sprintf("%.0f", hist_pct(SS_calls_h, p, CALL_CAP, SS_n[p], 0.95, 1) - 0.5) : "–"; hrow("95th percentile", v, "sub")
  for (p = 1; p <= nper; p++) v[p] = (SS_n[p] > 0) ? ctxfmt(SS_pk_sum[p] / SS_n[p]) : "–";                  hrow("Peak context per session, average", v, "")
  for (p = 1; p <= nper; p++) v[p] = (SS_n[p] > 0) ? ctxfmt(hist_pct(SS_pk_h, p, CTX_MAXBIN, SS_n[p], 0.5, CTX_BIN)) : "–"; hrow("Median", v, "sub")
  for (p = 1; p <= nper; p++) v[p] = (SS_n[p] > 0) ? ctxfmt(hist_pct(SS_pk_h, p, CTX_MAXBIN, SS_n[p], 0.95, CTX_BIN)) : "–"; hrow("95th percentile", v, "sub")
  for (p = 1; p <= nper; p++) v[p] = (SA_n[p] > 0) ? commas(SA_n[p]) " calls · avg " ctxfmt(SA_sum[p] / SA_n[p]) " · p95 " ctxfmt(hist_pct(SA_h, p, CTX_MAXBIN, SA_n[p], 0.95, CTX_BIN)) : "–"; hrow("Subagent calls", v, "")
  o("</tbody></table></div>")

  # 1. How many calls are over a given size: share of calls at or above each size
  for (p = 1; p <= nper; p++) {
    LOK[p] = (CT_n[p] > 0)
    run = 0
    for (b = CTX_MAXBIN; b >= 0; b--) {
      run += CT_h[p, b]
      if (b % 5 == 0) LY[p, b / 5 + 1] = (CT_n[p] > 0) ? run / CT_n[p] * 100 : 0
    }
  }
  for (i = 1; i <= 41; i++) LXL[i] = kfmt((i - 1) * 25000)
  line_chart("How many calls go over a given size?", "Pick a size on the bottom axis. The line shows what <b>% of calls</b> had a bigger conversation than that. It starts at 100% and only goes down. If the line stays high toward the right, many of your calls ran with a very large conversation, which costs more.", "Context size (tokens)", "% of calls above this size", 41, 4)

  # 2. Peak context per session: share of sessions whose peak reached at least each size.
  # Cumulative, so it stays a smooth falling line even when a week has only a few sessions.
  for (p = 1; p <= nper; p++) {
    LOK[p] = (SS_n[p] > 0)
    run = 0
    for (b = CTX_MAXBIN; b >= 0; b--) {
      run += SS_pk_h[p, b]
      if (b % 5 == 0) LY[p, b / 5 + 1] = (SS_n[p] > 0) ? run / SS_n[p] * 100 : 0
    }
  }
  for (i = 1; i <= 41; i++) LXL[i] = kfmt((i - 1) * 25000)
  line_chart("How large does a session's context get?", "A session grows until it ends. Its <b>peak</b> is the biggest conversation it reached. Pick a size on the bottom axis: the line shows what <b>% of sessions</b> got at least that big. If the line stays high toward 1M, many sessions grew until they hit the limit.", "Context size (tokens)", "% of sessions that reached it", 41, 4)

  # 3. Session length: share of sessions with more than N API calls (cumulative, like the two above)
  for (p = 1; p <= nper; p++) {
    LOK[p] = (SS_n[p] > 0)
    run = 0
    for (b = CALL_CAP; b >= 1; b--) {
      run += SS_calls_h[p, b]
      if (b % 50 == 1 && b <= 1001) LY[p, (b - 1) / 50 + 1] = (SS_n[p] > 0) ? run / SS_n[p] * 100 : 0   # sessions with more than b-1 calls
    }
    LY[p, 1] = (SS_n[p] > 0) ? 100 : 0
  }
  for (i = 1; i <= 21; i++) LXL[i] = (i - 1) * 50
  line_chart("How long are your sessions?", "Pick a number of calls on the bottom axis. The line shows what <b>% of sessions</b> lasted longer than that. Short sessions are cheap. Long sessions get more expensive, because the conversation keeps growing and is re-read on every call.", "API calls in the session", "% of sessions longer than this", 21, 2)

  # 4. Context by call number in the session
  if (ix_max >= 2) {
    W = 1100; H = 340; L = 70; R = 24; T = 16; B = 44
    pw = W - L - R; ph = H - T - B
    ymax = 0
    for (i = 1; i <= ix_max; i++) {
      x = hist_pct(IX_h, i, CTX_MAXBIN, IX_n[i], 0.95, CTX_BIN)
      if (x > ymax) ymax = x
      if (IX_sum[i] / IX_n[i] > ymax) ymax = IX_sum[i] / IX_n[i]
    }
    ymax = nice_max(ymax)
    slot = pw / ix_max
    o("<h3 class='ch'>How does context grow as a session goes on?</h3>")
    o("<p class='note cd'>This shows how the conversation grows during a session. At call number N (bottom axis), the lines show how big the conversation was: on <b>average</b>, for the <b>median</b> session (half of sessions are smaller), and for a big one, the <b>95th percentile</b> (only 1 session in 20 is bigger). The dotted line marks 200k tokens. A steep line means the conversation fills up fast.</p>")
    o("<div class='keys'><span><i class='lk' style='border-color:var(--p1)'></i>Average</span><span><i class='lk' style='border-color:var(--p3);border-top-style:dashed'></i>Median</span><span><i class='lk' style='border-color:var(--p2)'></i>95th percentile</span><span>A point needs at least " CTX_MINSESS " sessions that reach that call</span></div>")
    o("<div class='chartwrap'><svg class='chart' viewBox='0 0 " W " " H "' role='img' aria-label='Context size by call number in the session'>")
    for (g = 0; g <= 4; g++) {
      y = T + ph - ph * g / 4
      o("<line class='gl' x1='" L "' x2='" (W - R) "' y1='" sprintf("%.1f", y) "' y2='" sprintf("%.1f", y) "'/>")
      o("<text x='" (L - 10) "' y='" sprintf("%.1f", y + 4) "' text-anchor='end'>" ctxfmt(ymax * g / 4) "</text>")
    }
    if (200000 < ymax) {
      y = T + ph - 200000 / ymax * ph
      o("<line x1='" L "' x2='" (W - R) "' y1='" sprintf("%.1f", y) "' y2='" sprintf("%.1f", y) "' stroke='var(--muted)' stroke-dasharray='2 4'/><text x='" (W - R) "' y='" sprintf("%.1f", y - 5) "' text-anchor='end'>200k</text>")
    }
    ptsA = ptsM = ptsP = ""
    for (i = 1; i <= ix_max; i++) {
      x = L + slot * (i - 0.5)
      v[1] = IX_sum[i] / IX_n[i]
      v[2] = hist_pct(IX_h, i, CTX_MAXBIN, IX_n[i], 0.5, CTX_BIN)
      v[3] = hist_pct(IX_h, i, CTX_MAXBIN, IX_n[i], 0.95, CTX_BIN)
      ptsA = ptsA sprintf("%.1f,%.1f ", x, T + ph - v[1] / ymax * ph)
      ptsM = ptsM sprintf("%.1f,%.1f ", x, T + ph - v[2] / ymax * ph)
      ptsP = ptsP sprintf("%.1f,%.1f ", x, T + ph - v[3] / ymax * ph)
      tip = "Call " i ": average " ctxfmt(v[1]) " · median " ctxfmt(v[2]) " · p95 " ctxfmt(v[3]) " · " commas(IX_n[i]) " sessions"
      o("<g><title>" hesc(tip) "</title><rect class='hit' x='" sprintf("%.1f", L + slot * (i - 1)) "' y='" T "' width='" sprintf("%.2f", slot) "' height='" ph "'/></g>")
    }
    o("<polyline class='ln' style='stroke:var(--p2)' points='" ptsP "'/>")
    o("<polyline class='ln' style='stroke:var(--p3);stroke-dasharray:5 4' points='" ptsM "'/>")
    o("<polyline class='ln' style='stroke:var(--p1)' points='" ptsA "'/>")
    step = (ix_max <= 20) ? 1 : (ix_max <= 60) ? 5 : (ix_max <= 160) ? 10 : (ix_max <= 300) ? 25 : 50
    for (i = step; i <= ix_max; i += step)
      o("<text x='" sprintf("%.1f", L + slot * (i - 0.5)) "' y='" (H - B + 22) "' text-anchor='middle'>" i "</text>")
    o("<text x='" (L + pw / 2) "' y='" (H - 6) "' text-anchor='middle'>API call number in the session</text>")
    o("</svg></div>")
  }

  # 5. Share of calls by context size band
  split("Under 50k|50k to 100k|100k to 200k|200k to 500k|Over 500k", kname, "|")
  split("var(--k3)|var(--k1)|var(--k2)|var(--p2)|var(--p4)", kcol, "|")
  split("#fff|#fff|#1d1c19|#1d1c19|#fff", kfg, "|")
  o("<h3 class='ch'>Where do your calls land?</h3><p class='note cd'>The same calls as the first chart, put into five size groups. Each bar is 100% of the calls in that period. The more orange and pink, the more calls ran with a conversation over 200k tokens.</p><div class='keys'>")
  for (j = 1; j <= 5; j++) o("<span><i class='chip' style='background:" kcol[j] "'></i>" kname[j] "</span>")
  o("</div>")
  split("0 10 20 40 100 100000", bins, " ")   # bin edges in units of CTX_BIN: 0, 50k, 100k, 200k, 500k, end
  for (p = 1; p <= nper; p++) {
    if (CT_n[p] == 0) continue
    o("<div class='row'><span>" hesc(plab[p]) "</span><div class='stack'>")
    for (j = 1; j <= 5; j++) {
      lo = bins[j] + 0; hi = bins[j + 1] + 0
      tot = 0
      for (i = lo; i < hi && i <= CTX_MAXBIN; i++) tot += CT_h[p, i]
      share = tot / CT_n[p] * 100
      if (share > 0) o("<span style='width:" sprintf("%.2f", share) "%;background:" kcol[j] ";color:" kfg[j] "' title='" kname[j] ": " sprintf("%.1f", share) "% of calls'>" ((share >= 6) ? sprintf("%.0f%%", share) : "") "</span>")
    }
    o("</div><span class='v'>" commas(CT_n[p]) " calls</span></div>")
  }
  o("</div></details></section>")
}

# Status color for a number: g = healthy, b = worth a look, r = needs attention (hover shows why)
function paint(l, text, tip) { return "<span class='sv " l "' title='" hesc(tip) "'>" text "</span>" }
function lvl_hi(x, g, b) { return (x >= g) ? "g" : (x >= b) ? "b" : "r" }   # higher is better
function lvl_lo(x, g, b) { return (x < g) ? "g" : (x <= b) ? "b" : "r" }    # lower is better
function pcts(a, b) { return (b > 0) ? a / b * 100 : 0 }
function tin_of(p) { return P_in[p] + P_cw5[p] + P_cw1h[p] + P_cr[p] }

# --- Cost by model: one bar per period, one segment per model ---
function write_model_chart(    n, ord, i, p, j, mk, mc, fg, nm, names, c, other, w, tot, cost) {
  n = sort_desc(mod_cost, ord)
  if (n == 0) return
  split("#5b6cf0|#e08a2e|#1f9e8a|#c2527a|#8b5cf6|#3b82f6|#d4a72c|#b8b4aa", mc, "|")
  split("#fff|#1d1c19|#fff|#fff|#fff|#fff|#1d1c19|#1d1c19", fg, "|")
  nm = (n > 7) ? 7 : n
  o("<div class='card' style='margin-bottom:16px'><div class='keys'>")
  for (i = 1; i <= nm; i++) o("<span><i class='chip' style='background:" mc[i] "'></i>" hesc(ord[i]) "</span>")
  if (n > nm) o("<span><i class='chip' style='background:" mc[8] "'></i>Other (" (n - nm) ")</span>")
  o("</div>")
  for (p = 1; p <= nper; p++) {
    if (P_cost[p] <= 0) continue
    o("<div class='row'><span>" hesc(plab[p]) "</span><div class='stack'>")
    other = 0
    for (i = 1; i <= n; i++) {
      c = PM_cost[p, ord[i]] + 0
      if (i > nm) { other += c; continue }
      w = c / P_cost[p] * 100
      if (w > 0) o("<span style='width:" sprintf("%.2f", w) "%;background:" mc[i] ";color:" fg[i] "' title='" hesc(ord[i]) ": " money(c) " (" sprintf("%.1f", w) "% of cost)'>" ((w >= 6) ? sprintf("%.0f%%", w) : "") "</span>")
    }
    if (other > 0) {
      w = other / P_cost[p] * 100
      o("<span style='width:" sprintf("%.2f", w) "%;background:" mc[8] ";color:" fg[8] "' title='Other models: " money(other) " (" sprintf("%.1f", w) "% of cost)'>" ((w >= 6) ? sprintf("%.0f%%", w) : "") "</span>")
    }
    o("</div><span class='v'>" money(P_cost[p]) "</span></div>")
  }
  o("</div>")
}

# --- Models: one row per model, one column per period ---
function write_models(    n, ord, i, p, mk, c) {
  n = sort_desc(mod_cost, ord)
  o("<section><details open><summary>Models</summary><p class='note cd'>Which models your money went to. Each bar is 100% of that period's cost, so a shift between colors from one period to the next shows a change in which model you lean on. A pricier model (such as Opus) costs more for the same work than a cheaper one (such as Sonnet or Haiku). The table below gives the dollars and calls for each model. A model name in red has no known price, so it was costed at a default price.</p>")
  write_model_chart()
  o("<div class='card tw'><table><thead><tr><th>Model</th>")
  for (p = 1; p <= nper; p++) o("<th><i class='chip' style='background:" pcolor(p) "'></i>" hesc(plab[p]) "</th>")
  if (nper > 1) o("<th>Total</th>")
  o("</tr></thead><tbody>")
  for (i = 1; i <= n; i++) {
    mk = ord[i]
    o("<tr><td>" ((mk in unpriced) ? paint("r", hesc(mk), "No price found for this model, so it was costed at the default Sonnet rates") : hesc(mk)) "</td>")
    for (p = 1; p <= nper; p++) {
      c = PM_cost[p, mk] + 0
      if (PM_calls[p, mk] + 0 == 0) o("<td><small>–</small></td>")
      else o("<td><b>" money(c) "</b><small>" commas(PM_calls[p, mk]) " calls · " pct(c, P_cost[p]) "</small></td>")
    }
    if (nper > 1) o("<td><b>" money(mod_cost[mk]) "</b><small>" commas(mod_calls[mk]) " calls · " pct(mod_cost[mk], total_cost) "</small></td>")
    o("</tr>")
  }
  o("<tr class='tot'><td>All models</td>")
  for (p = 1; p <= nper; p++) o("<td>" money(P_cost[p]) "<small>" commas(P_calls[p]) " calls</small></td>")
  if (nper > 1) o("<td>" money(total_cost) "<small>" commas(uniq_u) " calls</small></td>")
  o("</tr></tbody></table></div>")
  o("</details></section>")
}

# One period's list for one category, highest first; returns the count of keys
function period_list(cat, p, keys, vals,    k, kp, n) {
  delete vals
  for (k in cnt) {
    split(k, kp, SUBSEP)
    # skip zero entries: reading cnt[] elsewhere creates them
    if (kp[1] == cat && kp[2] == p && cnt[k] > 0) vals[kp[3]] = cnt[k]
  }
  return sort_desc(vals, keys)
}

# --- Top lists: by item (bars per period) or by period (lists per period) ---
function write_top(    tl, trend, a0, a1, ci, cat, tot, ord, n, lim, mx, i, p, key, w, keys, vals) {
  o("<section><details open><summary>What was used · top " top_n "</summary><p class='note cd'>The tools, MCP servers, individual MCP tools, Bash commands (the first word of each), files read, skills, slash commands, helper agents (subagents) and projects you used most. Each number is how many times it was used (for projects, how many API calls), with its share of that list. \"By item\" ranks them. " ((nper > 1) ? "\"By " ((compare_unit != "") ? compare_unit : "period") "\" lists the top items in each period. " : "") "The small note next to a name shows how use changed in the last finished period compared with the one before it (new, or up or down by more than 10%). A period still in progress is left out of that comparison.</p>")
  o("<input type='radio' name='tv' id='tv1' class='tv' checked><label for='tv1' class='tvl l1'>By item</label>")
  if (nper > 1) o("<input type='radio' name='tv' id='tv2' class='tv'><label for='tv2' class='tvl l2'>By " ((compare_unit != "") ? compare_unit : "period") "</label>")
  tl = (pe[nper] > now) ? nper - 1 : nper   # trend compares the last finished period with the one before it
  o("<div class='views'><div class='by-item grid'>")
  for (ci = 1; ci <= nhcat; ci++) {
    cat = hcats[ci]
    delete tot; delete ord
    n = cat_totals(cat, tot)
    o("<div class='card'><div class='kh' style='margin-bottom:6px'>" cat_title[cat] "</div>")
    if (n == 0) { o("<p class='note'>None in this range.</p></div>"); continue }
    n = sort_desc(tot, ord)
    gtot[cat] = 0
    for (i = 1; i <= n; i++) gtot[cat] += tot[ord[i]]
    lim = (n < top_n) ? n : top_n
    mx = 0
    for (i = 1; i <= lim; i++) for (p = 1; p <= nper; p++) if (cnt[cat, p, ord[i]] > mx) mx = cnt[cat, p, ord[i]]
    o("<ul class='top'>")
    for (i = 1; i <= lim; i++) {
      key = ord[i]
      trend = ""
      if (tl > 1) {
        a1 = cnt[cat, tl, key] + 0; a0 = cnt[cat, tl - 1, key] + 0
        if (a1 > 0 && a0 == 0) trend = "<small class='tr new'>new</small>"
        else if (a0 > 0 && a1 == 0) trend = "<small class='tr'>not used</small>"
        else if (a0 > 0 && a1 > a0 * 1.1) trend = sprintf("<small class='tr'>▲ %.0f%%</small>", (a1 - a0) / a0 * 100)
        else if (a0 > 0 && a1 < a0 * 0.9) trend = sprintf("<small class='tr'>▼ %.0f%%</small>", (a0 - a1) / a0 * 100)
      }
      o("<li><div class='name'><span title='" hesc(key) "'>" hesc(key) trend "</span><b>" commas(tot[key]) " <small class='sh'>" pct(tot[key], gtot[cat]) "</small></b></div><div class='bars'>")
      for (p = 1; p <= nper; p++) {
        w = (mx > 0) ? (cnt[cat, p, key] + 0) / mx * 100 : 0
        if (w > 0 && w < 1) w = 1
        o("<div class='bar' title='" hesc(plab[p]) "'><i style='width:" sprintf("%.2f", w) "%;background:" pcolor(p) "'></i><em>" (nper > 1 ? commas(cnt[cat, p, key] + 0) : "") "</em></div>")
      }
      o("</div></li>")
    }
    o("</ul>")
    if (n > lim) o("<p class='note' style='margin:8px 0 0'>… " (n - lim) " more</p>")
    o("</div>")
  }
  o("</div>")
  if (nper > 1) {
    o("<div class='by-period'>")
    for (p = 1; p <= nper; p++) {
      o("<div class='card pcard'><div class='kh'><i class='chip' style='background:" pcolor(p) "'></i>" hesc(plab[p]) "</div><div class='kl' style='margin-bottom:0'>" hesc(plong[p]) "</div><div class='pgrid'>")
      for (ci = 1; ci <= nhcat; ci++) {
        cat = hcats[ci]
        n = period_list(cat, p, keys, vals)
        o("<div><h3>" cat_title[cat] "</h3>")
        if (n == 0) { o("<p class='note' style='margin:0'>None</p></div>"); continue }
        lim = (n < top_n) ? n : top_n
        mx = vals[keys[1]]
        o("<ul class='mini'>")
        for (i = 1; i <= lim; i++) {
          key = keys[i]
          o("<li><div class='name'><span title='" hesc(key) "'>" hesc(key) "</span><b>" commas(vals[key]) "</b></div><i style='width:" sprintf("%.1f", vals[key] / mx * 100) "%;background:" pcolor(p) "'></i></li>")
        }
        o("</ul>")
        if (n > lim) o("<p class='note' style='margin:4px 0 0;font-size:12px'>… " (n - lim) " more</p>")
        o("</div>")
      }
      o("</div></div>")
    }
    o("</div>")
  }
  o("</div></details></section>")
}

# --- Requests and cost: per day, by hour of the day, by day of the week, and per project ---
function write_activity(    ) {
  o("<section><details open><summary>Requests and cost</summary><p class='note cd'>When you use Claude Code and where the money goes. A <b>request</b> is one API call. The charts show cost and requests over time, then by hour of the day and day of the week (your local time), and last by project.</p><div class='card'>")
  write_chart()
  write_hour_charts()
  write_project_cost()
  o("</div></details></section>")
}

# Bars = cost stacked by period (left axis), line = requests (right axis), for n slots such as hours or weekdays
function combo_chart(title, desc, n, lab, isday, tick,    p, i, W, H, L, R, T, B, pw, ph, slot, bw, maxc, maxn, yc, yn, g, y, x, h, c, tip, tot, cost, pts) {
  maxc = 0; maxn = 0
  for (i = 1; i <= n; i++) {
    tot = 0; cost = 0
    for (p = 1; p <= nper; p++) { tot += (isday ? TW_n[p, i - 1] : TH_n[p, i - 1]) + 0; cost += (isday ? TW_c[p, i - 1] : TH_c[p, i - 1]) + 0 }
    if (tot > maxn) maxn = tot
    if (cost > maxc) maxc = cost
  }
  if (maxn == 0) return
  yc = nice_max(maxc); yn = nice_max(maxn)
  W = 1100; H = 300; L = 70; R = 64; T = 14; B = 36
  pw = W - L - R; ph = H - T - B; slot = pw / n; bw = slot * 0.7
  o("<h3 class='ch'>" title "</h3><p class='note cd'>" desc "</p><div class='keys'>")
  if (nper > 1) for (p = 1; p <= nper; p++) o("<span><i class='chip' style='background:" pcolor(p) "'></i>" hesc(plab[p]) "</span>")
  else o("<span><i class='chip' style='background:" pcolor(1) "'></i>Cost (left axis)</span>")
  o("<span><i class='lk'></i>Requests (right axis)</span></div><div class='chartwrap'>")
  o("<svg class='chart' viewBox='0 0 " W " " H "' role='img' aria-label='" hesc(title) "'>")
  for (g = 0; g <= 4; g++) {
    y = T + ph - ph * g / 4
    o("<line class='gl' x1='" L "' x2='" (W - R) "' y1='" sprintf("%.1f", y) "' y2='" sprintf("%.1f", y) "'/>")
    o("<text x='" (L - 10) "' y='" sprintf("%.1f", y + 4) "' text-anchor='end'>" money(yc * g / 4) "</text>")
    o("<text x='" (W - R + 10) "' y='" sprintf("%.1f", y + 4) "'>" format_tokens(yn * g / 4) "</text>")
  }
  pts = ""
  for (i = 1; i <= n; i++) {
    x = L + slot * (i - 1) + (slot - bw) / 2
    tot = 0; cost = 0
    for (p = 1; p <= nper; p++) { tot += (isday ? TW_n[p, i - 1] : TH_n[p, i - 1]) + 0; cost += (isday ? TW_c[p, i - 1] : TH_c[p, i - 1]) + 0 }
    tip = lab[i] ": " money(cost) " · " commas(tot) " requests"
    o("<g><title>" hesc(tip) "</title><rect class='hit' x='" sprintf("%.1f", L + slot * (i - 1)) "' y='" T "' width='" sprintf("%.2f", slot) "' height='" ph "'/>")
    y = T + ph
    for (p = 1; p <= nper; p++) {
      c = (isday ? TW_c[p, i - 1] : TH_c[p, i - 1]) + 0
      if (c <= 0) continue
      h = c / yc * ph; y -= h
      o("<rect x='" sprintf("%.1f", x) "' y='" sprintf("%.1f", y) "' width='" sprintf("%.2f", bw) "' height='" sprintf("%.2f", h) "' rx='" (bw > 6 ? 2 : 0) "' fill='" pcolor(p) "'/>")
    }
    o("</g>")
    pts = pts sprintf("%.1f,%.1f ", L + slot * (i - 0.5), T + ph - tot / yn * ph)
    if ((i - 1) % tick == 0) o("<text x='" sprintf("%.1f", L + slot * (i - 0.5)) "' y='" (H - B + 22) "' text-anchor='middle'>" lab[i] "</text>")
  }
  o("<polyline class='ln' points='" pts "'/>")
  o("</svg></div>")
}

function write_hour_charts(    i, lab) {
  for (i = 1; i <= 24; i++) lab[i] = sprintf("%02d", i - 1)
  combo_chart("Cost and requests by hour of the day", "All your days added together and split into the 24 hours of the day (your local time, 24-hour clock). The bars show the cost in each hour; the line shows the requests. Tall bars are the hours you use Claude Code the most.", 24, lab, 0, 2)
  split("Mon Tue Wed Thu Fri Sat Sun", lab, " ")
  combo_chart("Cost and requests by day of the week", "The same numbers grouped by day of the week. The bars show the cost; the line shows the requests. It shows which days you lean on Claude Code the most.", 7, lab, 1, 1)
}

# Cost per project: the folder each session ran in. Horizontal bars, one row per project, stacked by period.
function write_project_cost(    ord, n, i, lim, p, key, mx, tc, W, H, L, R, T, B, rh, pw, ph, x, y, g, w, run, tot, lab) {
  n = sort_desc(PJ_t, ord)
  if (n == 0) return
  lim = (n < top_n) ? n : top_n
  tc = 0
  for (i = 1; i <= n; i++) tc += PJ_t[ord[i]]
  mx = 0
  for (i = 1; i <= lim; i++) if (PJ_t[ord[i]] > mx) mx = PJ_t[ord[i]]
  mx = nice_max(mx)
  rh = 34; W = 1100; L = 190; R = 150; T = 10; B = 30
  pw = W - L - R; ph = lim * rh; H = T + ph + B
  o("<h3 class='ch'>Cost per project</h3><p class='note cd'>What each project cost, where a project is the folder a session ran in. Each row is one project and the bar length is its cost" ((nper > 1) ? ", split by period" : "") ". The label on the right is the total and its share of all cost. Showing the top " lim " of " n " projects.</p>")
  if (nper > 1) {
    o("<div class='keys'>")
    for (p = 1; p <= nper; p++) o("<span><i class='chip' style='background:" pcolor(p) "'></i>" hesc(plab[p]) "</span>")
    o("</div>")
  }
  o("<div class='chartwrap'><svg class='chart' viewBox='0 0 " W " " H "' role='img' aria-label='Cost per project'>")
  for (g = 0; g <= 4; g++) {
    x = L + pw * g / 4
    o("<line class='gl' x1='" sprintf("%.1f", x) "' x2='" sprintf("%.1f", x) "' y1='" T "' y2='" (T + ph) "'/>")
    o("<text x='" sprintf("%.1f", x) "' y='" (T + ph + 20) "' text-anchor='middle'>" money(mx * g / 4) "</text>")
  }
  for (i = 1; i <= lim; i++) {
    key = ord[i]
    y = T + rh * (i - 1)
    lab = key
    if (length(lab) > 26) lab = substr(lab, 1, 25) "…"
    o("<g><title>" hesc(key ": " money(PJ_t[key]) " · " pct(PJ_t[key], tc) " of all cost") "</title><text x='" (L - 10) "' y='" sprintf("%.1f", y + rh / 2 + 4) "' text-anchor='end'>" hesc(lab) "</text>")
    run = 0
    for (p = 1; p <= nper; p++) {
      w = (PJ_c[p, key] + 0) / mx * pw
      if (w <= 0) continue
      o("<rect x='" sprintf("%.1f", L + run) "' y='" sprintf("%.1f", y + 5) "' width='" sprintf("%.2f", w) "' height='" (rh - 10) "' fill='" pcolor(p) "'><title>" hesc(key " · " plab[p] ": " money(PJ_c[p, key]) " · " commas(PJ_n[p, key]) " requests") "</title></rect>")
      run += w
    }
    tot = 0
    for (p = 1; p <= nper; p++) tot += PJ_n[p, key]
    o("<text x='" sprintf("%.1f", L + run + 8) "' y='" sprintf("%.1f", y + rh / 2 + 4) "'>" money(PJ_t[key]) " · " pct(PJ_t[key], tc) "</text></g>")
  }
  o("</svg></div>")
}

function hrow(label, vals, cls,    p) {
  o("<tr" (cls != "" ? " class='" cls "'" : "") "><td>" label "</td>")
  for (p = 1; p <= nper; p++) o("<td>" vals[p] "</td>")
  o("</tr>")
}

# "name 12 · name 9 · …" for one period, highest first
function top_inline(cat, p,  lim,    tmp, ord, k, kp, n, i, s) {
  delete tmp
  for (k in cnt) {
    split(k, kp, SUBSEP)
    if (kp[1] == cat && kp[2] == p && cnt[k] > 0) tmp[kp[3]] = cnt[k]
  }
  n = sort_desc(tmp, ord)
  s = ""
  for (i = 1; i <= n && i <= lim; i++)
    s = s (s == "" ? "" : " · ") "<b>" hesc(ord[i]) "</b> " commas(tmp[ord[i]])
  return (s == "") ? "–" : s
}
AWK
REDUCE_PROG="${COMMON_AWK}${REDUCE_PROG_MAIN}"

# Read files in parallel: each batch is grep-filtered to the lines that matter
# (API responses and slash commands) and turned into small records in its own
# part file, so parallel output never interleaves. LC_ALL=C treats text as bytes.
JOBS=$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) | head -1 )
BATCH=$(( (FILE_COUNT + JOBS * 4 - 1) / (JOBS * 4) ))
[[ "$BATCH" -lt 1 ]] && BATCH=1
PARTS_DIR=$(mktemp -d)
# CLAUDECOST_READER=awk forces the awk-only reader (for testing or when perl misbehaves)
READER="${CLAUDECOST_READER:-}"
if [[ -z "$READER" ]]; then
  if command -v perl >/dev/null 2>&1; then READER=perl; else READER=awk; fi
fi
export MAP_PROG FRAG_PROG PERL_PROG READER PERIOD_FILE TZ_OFF_MIN MONTH PARTS_DIR
xargs -0 -P "$JOBS" -n "$BATCH" sh -c '
  # echo after each file: a log without a final newline must not glue its last
  # line onto the next file'"'"'s first line.
  # Each batch writes a unique part file (mktemp: process ids get reused).
  out=$(mktemp "$PARTS_DIR/part.XXXXXX")
  if [ "$READER" = perl ]; then
    for f in "$@"; do cat "$f" 2>/dev/null; echo; done \
      | LC_ALL=C perl -ne "$PERL_PROG" \
      | LC_ALL=C awk -v wid="$$" -v period_file="$PERIOD_FILE" -v tz_off="$TZ_OFF_MIN" \
          "$FRAG_PROG" > "$out"
  else
    for f in "$@"; do cat "$f" 2>/dev/null; echo; done \
      | LC_ALL=C grep -F -e "\"usage\"" -e "\"content\":\"<command-" -e "\"role\":\"user\",\"content\":\"/" \
      | LC_ALL=C awk -v wid="$$" -v period_file="$PERIOD_FILE" -v tz_off="$TZ_OFF_MIN" \
          "$MAP_PROG" > "$out"
  fi
' sh < "$FILE_LIST" || true

find "$PARTS_DIR" -name 'part.*' -type f -print0 | xargs -0 cat | LC_ALL=C awk -F'\t' \
  -v tz_off="${TZ_OFF_MIN}" \
  -v bucket_unit="${BUCKET}" \
  -v compare_unit="${COMPARE}" \
  -v now="${NOW}" \
  -v pricing_file="${PRICING_FILE:-}" \
  -v period_file="${PERIOD_FILE}" \
  -v html_file="${HTML_OUT}" \
  -v top_n="${TOP_N}" \
  -v nocolor="${NOCOLOR}" \
  -v gen_time="${GEN_TIME}" \
  "$REDUCE_PROG"

# Clean up temp files
rm -f "$FILE_LIST" "$PERIOD_FILE"
rm -rf "$PARTS_DIR"
[[ -n "${TMPTSV:-}" ]] && rm -f "$TMPTSV" 2>/dev/null

echo ""
