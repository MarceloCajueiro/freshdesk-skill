#!/usr/bin/env bash
# Freshdesk REST helper for the `freshdesk` agent skill.
# Credentials: run `fd.sh setup`. They are stored in
# ${XDG_CONFIG_HOME:-~/.config}/freshdesk/config with mode 600.
# Environment variables of the same name always win over the config file.
#
# HARD RULE: this script reads tickets and adds PRIVATE notes. Nothing else.
# It never replies to a customer, never posts a public note, and never changes
# a ticket's status, assignment or fields. fd_curl enforces that for every call.
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/freshdesk"
CONFIG_FILE="$CONFIG_DIR/config"
FD_DEFAULT_DOMAIN="portabilis.freshdesk.com"

# Env wins over the config file, as CLI convention requires.
_fd_env_domain="${FRESHDESK_DOMAIN:-}"
_fd_env_key="${FRESHDESK_API_KEY:-}"
FRESHDESK_DOMAIN=""
FRESHDESK_API_KEY=""

# The file is parsed, never sourced: a value is data, and sourcing would run it.
if [ -f "$CONFIG_FILE" ]; then
  while IFS= read -r _fd_line || [ -n "$_fd_line" ]; do
    case "$_fd_line" in
      FRESHDESK_DOMAIN=*)  FRESHDESK_DOMAIN="${_fd_line#FRESHDESK_DOMAIN=}" ;;
      FRESHDESK_API_KEY=*) FRESHDESK_API_KEY="${_fd_line#FRESHDESK_API_KEY=}" ;;
    esac
  done < "$CONFIG_FILE"
  unset _fd_line
fi

FRESHDESK_DOMAIN="${_fd_env_domain:-$FRESHDESK_DOMAIN}"
FRESHDESK_API_KEY="${_fd_env_key:-$FRESHDESK_API_KEY}"
unset _fd_env_domain _fd_env_key

# Dependencies, checked once with an actionable message instead of a cryptic failure.
for _fd_dep in curl jq; do
  command -v "$_fd_dep" >/dev/null 2>&1 || {
    echo "ERROR: '$_fd_dep' is required but was not found in PATH." >&2
    exit 1
  }
done
unset _fd_dep

# Accepts "portabilis", "portabilis.freshdesk.com" or a full URL, returns the host.
fd_normalize_domain() {
  local d="$1"
  d="${d#http://}"
  d="${d#https://}"
  d="${d%%/*}"
  case "$d" in
    "") ;;
    *.*) ;;
    *) d="$d.freshdesk.com" ;;
  esac
  printf '%s' "$d"
}

cmd_setup() {
  local domain="" key="" have_domain=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain)  domain="${2:-}"; have_domain=1; shift 2 ;;
      --api-key) key="${2:-}"; shift 2 ;;
      -h|--help)
        echo "usage: fd.sh setup [--domain DOMAIN --api-key KEY]"
        echo "with no flags, prompts interactively. The domain defaults to $FD_DEFAULT_DOMAIN."
        return 0 ;;
      *) echo "unknown option: $1" >&2; return 1 ;;
    esac
  done

  if [ -z "$key" ]; then
    # Only a terminal gets the prompts; a pipe feeding two lines still works.
    # On stdin that never delivers - an agent's inherited descriptor - the read
    # times out instead of hanging until the caller's own timeout.
    local fd_read_opts=()
    if [ -t 0 ]; then
      echo "Freshdesk setup. Your API key is in Freshdesk, at:"
      echo "  Profile picture (top right) > Profile settings > View API key"
      echo
    else
      fd_read_opts=(-t "${FD_SETUP_READ_TIMEOUT:-10}")
    fi

    fd_prompt() {  # fd_prompt <var-name> <label> [hidden]
      local __var="$1" __label="$2" __hidden="${3:-}" __value=""
      [ -t 0 ] && printf '%s' "$__label"
      if [ -n "$__hidden" ] && [ -t 0 ]; then
        # read -s keeps the key off the screen and out of the shell history.
        read -rs ${fd_read_opts[@]+"${fd_read_opts[@]}"} __value || __value=""
        echo
      else
        read -r ${fd_read_opts[@]+"${fd_read_opts[@]}"} __value || __value=""
      fi
      printf -v "$__var" '%s' "$__value"
    }

    if [ "$have_domain" -eq 0 ]; then
      fd_prompt domain "Freshdesk domain [$FD_DEFAULT_DOMAIN]: "
    fi
    fd_prompt key 'API key (input hidden): ' hidden

    if [ -z "$key" ]; then
      echo "ERROR: setup needs a terminal, two piped lines (domain, API key), or the --api-key flag." >&2
      return 1
    fi
  fi

  [ -n "$domain" ] || domain="$FD_DEFAULT_DOMAIN"
  domain="$(fd_normalize_domain "$domain")"

  mkdir -p "$CONFIG_DIR"
  umask 077
  printf 'FRESHDESK_DOMAIN=%s\nFRESHDESK_API_KEY=%s\n' "$domain" "$key" > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"

  FRESHDESK_DOMAIN="$domain"
  FRESHDESK_API_KEY="$key"
  BASE="https://$domain"

  echo "Saved to $CONFIG_FILE"
  printf 'Checking credentials... '
  cmd_whoami
}

# Credentials are required by every command except setup itself, which creates them.
# The check runs here so an unconfigured install fails with one clear line.
if [ "${1:-}" != "setup" ] && [ -n "${1:-}" ] &&
   { [ -z "$FRESHDESK_DOMAIN" ] || [ -z "$FRESHDESK_API_KEY" ]; }; then
  echo "ERROR: no credentials. Run 'fd.sh setup' (or set FRESHDESK_DOMAIN and FRESHDESK_API_KEY)." >&2
  exit 1
fi

FRESHDESK_DOMAIN="$(fd_normalize_domain "$FRESHDESK_DOMAIN")"
BASE="https://$FRESHDESK_DOMAIN"

# The single door to the API. Prints the response body, then a last line with
# the HTTP status (000 when the network failed, `refused` when the allowlist
# blocked the call).
#
# The allowlist below is the hard rule in code: GET anything under /api/v2/,
# POST only to a ticket's notes. Reply, update, assign, delete and every other
# write are refused here, before curl runs, whatever the caller asked for.
fd_curl() {
  local method="$1" path="$2"
  shift 2
  case "$method $path" in
    "GET /api/v2/"*) ;;
    "POST /api/v2/tickets/"*/notes)
      local tid="${path#/api/v2/tickets/}"
      tid="${tid%/notes}"
      case "$tid" in
        ""|*[!0-9]*) printf '%s %s\nrefused\n' "$method" "$path"; return 0 ;;
      esac
      ;;
    *) printf '%s %s\nrefused\n' "$method" "$path"; return 0 ;;
  esac

  # A timeout on a POST may hide a note that was in fact created: retrying it
  # could post the same note twice. Only reads are retried.
  local retry=()
  [ "$method" = "GET" ] && retry=(--retry 2 --retry-connrefused)

  # The key goes in through --config on stdin, never as an argument: argv is
  # readable by every process on the machine through `ps`.
  local out
  if ! out=$(printf 'user = "%s:X"\n' "$FRESHDESK_API_KEY" \
      | curl -sS --config - --max-time "${FD_HTTP_TIMEOUT:-20}" ${retry[@]+"${retry[@]}"} \
          -X "$method" "$BASE$path" \
          -H "Content-Type: application/json" \
          -w '\n%{http_code}' \
          "$@" 2>/dev/null); then
    printf '\n000\n'
    return 0
  fi
  printf '%s\n' "$out"
}

# Splits fd_curl output. fd_status prints the code, fd_body everything before it.
fd_status() { printf '%s\n' "$1" | tail -n 1; }
fd_body()   { printf '%s\n' "$1" | sed '$d'; }

# Turns a non-2xx response into one ERROR line the user can act on.
# Freshdesk signals failure by status code; the body may be JSON, HTML or empty,
# so jq is never allowed to abort the caller.
fd_error() {
  local status="$1" body="$2" what="${3:-resource}" detail=""
  detail=$(printf '%s' "$body" | jq -r '
      [ (.message // .description // empty),
        ((.errors // [])[] | "\(.field // "?"): \(.message // .code // "?")") ]
      | map(select(type == "string" and . != "")) | join("; ")' 2>/dev/null || true)
  case "$status" in
    refused) echo "ERROR: refused by this skill: $body. It only reads tickets and adds private notes." ;;
    000) echo "ERROR: network failure talking to Freshdesk ($BASE)" ;;
    401) echo "ERROR: invalid API key (401). Run 'fd.sh setup' again with a current key." ;;
    403) echo "ERROR: forbidden (403): this agent has no access to that $what${detail:+ - $detail}" ;;
    404) echo "ERROR: not found (404): no such $what, or this agent cannot see it" ;;
    429) echo "ERROR: rate limited (429): the account's API quota is spent for now; wait a minute and retry" ;;
    *)   echo "ERROR: HTTP $status${detail:+: $detail}" ;;
  esac
}

# Internal: one GET. Prints the body on 200, or one ERROR line otherwise.
fd_get() {
  local path="$1" what="${2:-resource}" res status body
  res=$(fd_curl GET "$path")
  status=$(fd_status "$res")
  body=$(fd_body "$res")
  if [ "$status" != "200" ]; then
    fd_error "$status" "$body" "$what"
    return 0
  fi
  if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    echo "ERROR: unreadable response from Freshdesk"
    return 0
  fi
  printf '%s' "$body"
}

# Internal: the ticket id inside `123`, `#123` or a ticket URL
# (.../a/tickets/123, .../helpdesk/tickets/123?x). Empty when there is none.
fd_ticket_id() {
  local arg="$1" id="$1"
  case "$arg" in
    */tickets/*) id="${arg##*/tickets/}"; id="${id%%[/?#]*}" ;;
    \#*) id="${arg#\#}" ;;
  esac
  case "$id" in
    ""|*[!0-9]*) id="" ;;
  esac
  printf '%s' "$id"
}

fd_ticket_link() { printf '%s/a/tickets/%s' "$BASE" "$1"; }

# jq helpers shared by every view of a ticket. Single quotes: these are jq, not shell.
# shellcheck disable=SC2016
FD_JQ_DEFS='
  def status_name: {"2":"Open","3":"Pending","4":"Resolved","5":"Closed",
                    "6":"Waiting on Customer","7":"Waiting on Third Party"}[tostring] // "status \(.)";
  def priority_name: {"1":"Low","2":"Medium","3":"High","4":"Urgent"}[tostring] // "priority \(.)";
  def day: if . == null then "?" else sub("\\.[0-9]+"; "") | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M") end;
  def oneline: gsub("[\r\n\t]+"; " ") | gsub("  +"; " ") | ltrimstr(" ") | rtrimstr(" ");
  def clip($n): if length > $n then .[0:$n] + " [...]" else . end;
'

cmd_whoami() {
  local body
  body=$(fd_get "/api/v2/agents/me" "agent")
  case "$body" in ERROR:*) printf '%s\n' "$body"; return 0 ;; esac
  printf '%s' "$body" | jq -r '"\(.contact.name // "?") <\(.contact.email // "?")>"'
}

# ticket <id|#id|url> - summary of one ticket, with its most recent conversations.
cmd_ticket() {
  local arg="${1:?usage: fd.sh ticket <id|url>}"
  local id
  id=$(fd_ticket_id "$arg")
  [ -n "$id" ] || { echo "ERROR: not a ticket id or ticket link: $arg"; return 1; }

  local ticket
  ticket=$(fd_get "/api/v2/tickets/$id?include=requester,company" "ticket")
  case "$ticket" in ERROR:*) printf '%s\n' "$ticket"; return 0 ;; esac

  # Conversations come oldest first, a page at a time. The most recent ones are
  # on the last page, so every page is read until a short one ends the list.
  local per=100 page=1 all='[]' chunk n
  while [ "$page" -le "${FD_CONVERSATION_PAGES:-10}" ]; do
    chunk=$(fd_get "/api/v2/tickets/$id/conversations?per_page=$per&page=$page" "ticket")
    case "$chunk" in ERROR:*) printf '%s\n' "$chunk"; return 0 ;; esac
    all=$(jq -n --argjson a "$all" --argjson b "$chunk" '$a + $b')
    n=$(printf '%s' "$chunk" | jq 'length')
    [ "$n" -lt "$per" ] && break
    page=$((page + 1))
  done

  printf '%s' "$ticket" | jq -r --arg link "$(fd_ticket_link "$id")" \
    --argjson convs "$all" --argjson last "${FD_CONVERSATIONS:-5}" "$FD_JQ_DEFS"'
    "#\(.id)  \(.subject // "(no subject)")",
    "Status: \(.status | status_name) | Priority: \(.priority | priority_name)\(if .type then " | Type: \(.type)" else "" end)",
    "Requester: \(.requester.name // "?")\(if .requester.email then " <\(.requester.email)>" else "" end)",
    "Company: \(.company.name // "-")",
    "Tags: \(if (.tags // []) == [] then "-" else (.tags | join(", ")) end)",
    "Created: \(.created_at | day) | Updated: \(.updated_at | day)",
    "Link: \($link)",
    "",
    "Description: \((.description_text // "") | oneline | clip(500))",
    "",
    (($convs | length) as $total
     | if $total == 0 then "Conversations: none"
       else "Conversations (last \([$total, $last] | min) of \($total), oldest first):",
         ($convs[-$last:][]
          | (if .private == true then "PRIVATE NOTE"
             elif .source == 2 then "PUBLIC NOTE"
             elif .incoming == true then "PUBLIC, from customer"
             else "PUBLIC REPLY" end) as $kind
          | "\(.created_at | day)\t\($kind)\t\(.from_email // "user \(.user_id // "?")")\t\((.body_text // "") | oneline | clip(300))")
       end)'
}

# Internal: prints one TSV line per ticket of a JSON array.
fd_ticket_rows() {
  jq -r --arg base "$BASE" "$FD_JQ_DEFS"'
    .[] | [(.updated_at | day), "#\(.id)", (.status | status_name),
           ((.subject // "") | oneline | clip(200)), "\($base)/a/tickets/\(.id)"] | @tsv'
}

# search <term|filter-query> [count]
# Freshdesk has no free-text search over tickets in its public API. Two modes:
#   - a filter query (`status:2 AND tag:'x'`, anything with `field:`) goes to
#     /api/v2/search/tickets as is;
#   - plain words scan the most recently updated tickets and match the subject,
#     every word required, case-insensitive. Coverage is always stated.
cmd_search() {
  local term="${1:?usage: fd.sh search <words|filter-query> [count]}"
  local count="${2:-20}"
  case "$count" in ""|*[!0-9]*) echo "ERROR: count must be a number: $count"; return 1 ;; esac

  if printf '%s' "$term" | grep -Eq '[A-Za-z_]+:'; then
    local q body
    q=$(jq -rn --arg t "$term" '"\"\($t)\"" | @uri')
    body=$(fd_get "/api/v2/search/tickets?query=$q" "search")
    case "$body" in ERROR:*) printf '%s\n' "$body"; return 0 ;; esac
    local total shown
    total=$(printf '%s' "$body" | jq '.total // (.results | length)')
    shown=$(printf '%s' "$body" | jq --argjson c "$count" '[.results[0:$c][]] | length')
    if [ "$shown" -eq 0 ]; then echo "NONE"; return 0; fi
    [ "$total" -gt "$shown" ] && echo "INFO: showing $shown of $total matches"
    printf '%s' "$body" | jq --argjson c "$count" '.results[0:$c]' | fd_ticket_rows
    return 0
  fi

  local days="${FD_SEARCH_DAYS:-90}" pages="${FD_SEARCH_PAGES:-3}" since
  since=$(jq -rn --argjson d "$days" 'now - ($d * 86400) | strftime("%Y-%m-%dT%H:%M:%SZ")')
  local page=1 all='[]' chunk n
  while [ "$page" -le "$pages" ]; do
    chunk=$(fd_get "/api/v2/tickets?order_by=updated_at&order_type=desc&per_page=100&page=$page&updated_since=$since" "ticket list")
    case "$chunk" in ERROR:*) printf '%s\n' "$chunk"; return 0 ;; esac
    all=$(jq -n --argjson a "$all" --argjson b "$chunk" '$a + $b')
    n=$(printf '%s' "$chunk" | jq 'length')
    [ "$n" -lt 100 ] && break
    page=$((page + 1))
  done

  local scanned matches
  scanned=$(printf '%s' "$all" | jq 'length')
  matches=$(printf '%s' "$all" | jq --arg t "$term" --argjson c "$count" '
    ($t | ascii_downcase | [splits("\\s+")] | map(select(. != ""))) as $words
    | [.[] | select((.subject // "" | ascii_downcase) as $s | all($words[]; . as $w | $s | contains($w)))]
    | .[0:$c]')
  echo "INFO: matched subjects of the $scanned most recently updated tickets (last $days days)"
  if [ "$(printf '%s' "$matches" | jq 'length')" -eq 0 ]; then
    echo "NONE"
  else
    printf '%s' "$matches" | fd_ticket_rows
  fi
}

# Internal: plain text to the HTML a note body is. Escapes markup, keeps line
# breaks, and turns bare URLs into links.
FD_JQ_HTML='
  gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")
  | gsub("(?<u>https?://[^\\s<]+)"; "<a href=\"\(.u)\">\(.u)</a>")
  | gsub("\r?\n"; "<br>")
'

# Internal: posts a private note. $1 ticket arg, $2 text, rest: notify emails.
fd_post_note() {
  local arg="$1" text="$2"
  shift 2
  local id
  id=$(fd_ticket_id "$arg")
  [ -n "$id" ] || { echo "ERROR: not a ticket id or ticket link: $arg"; return 1; }
  [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ] || { echo "ERROR: the note is empty"; return 1; }

  local emails='[]' e
  for e in "$@"; do
    case "$e" in
      *@*.*) emails=$(jq -n --argjson a "$emails" --arg e "$e" '$a + [$e]') ;;
      *) echo "ERROR: not an email address: $e"; return 1 ;;
    esac
  done

  # `private: true` is a literal: no argument, flag or variable can reach it.
  local payload
  payload=$(jq -n --arg t "$text" --argjson n "$emails" "
    {body: (\$t | $FD_JQ_HTML), private: true}
    + (if (\$n | length) > 0 then {notify_emails: \$n} else {} end)")

  local res status body
  res=$(fd_curl POST "/api/v2/tickets/$id/notes" -d "$payload")
  status=$(fd_status "$res")
  body=$(fd_body "$res")
  case "$status" in
    200|201) ;;
    000) echo "ERROR: network failure talking to Freshdesk ($BASE). The note may or may not have been created: check $(fd_ticket_link "$id") before sending again."; return 0 ;;
    *) fd_error "$status" "$body" "ticket"; return 0 ;;
  esac

  local nid private
  nid=$(printf '%s' "$body" | jq -r '.id // empty' 2>/dev/null || true)
  private=$(printf '%s' "$body" | jq -r '.private' 2>/dev/null || true)
  if [ "$private" = "false" ]; then
    echo "ERROR: Freshdesk stored note $nid as PUBLIC. Open $(fd_ticket_link "$id") and delete or fix it now."
    return 1
  fi
  echo "OK: private note ${nid:-?} added to ticket #$id - $(fd_ticket_link "$id")"
}

# Internal: parses `[--notify email]...` after the positional arguments.
# Anything else is refused, including every attempt at a public note.
fd_note_args() {
  FD_NOTIFY=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --notify) [ -n "${2:-}" ] || { echo "ERROR: --notify needs an email address"; return 1; }
                FD_NOTIFY+=("$2"); shift 2 ;;
      *) echo "ERROR: unknown option: $1. Notes are always private; this skill cannot reply to a customer or post a public note."; return 1 ;;
    esac
  done
}

# note <ticket> <text> [--notify email]...
cmd_note() {
  local usage="usage: fd.sh note <ticket> <text> [--notify agent@example.com]..."
  [ $# -ge 2 ] || { echo "$usage" >&2; return 1; }
  local ticket="$1" text="$2"
  shift 2
  fd_note_args "$@" || return 1
  fd_post_note "$ticket" "$text" ${FD_NOTIFY[@]+"${FD_NOTIFY[@]}"}
}

# note-file <ticket> <file> [--notify email]... - the text comes from a file
cmd_note_file() {
  local usage="usage: fd.sh note-file <ticket> <file> [--notify agent@example.com]..."
  [ $# -ge 2 ] || { echo "$usage" >&2; return 1; }
  local ticket="$1" file="$2"
  shift 2
  fd_note_args "$@" || return 1
  [ -e "$file" ] || { echo "ERROR: note file not found: $file"; return 1; }
  [ -r "$file" ] || { echo "ERROR: note file is not readable: $file"; return 1; }
  [ -s "$file" ] || { echo "ERROR: note file is empty: $file"; return 1; }
  local text
  text=$(cat "$file") || { echo "ERROR: could not read the note file: $file"; return 1; }
  fd_post_note "$ticket" "$text" ${FD_NOTIFY[@]+"${FD_NOTIFY[@]}"}
}

# Sourced (by the test suite, to reach fd_curl directly): define, do not run.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

case "${1:-}" in
  setup)     shift; cmd_setup "$@" ;;
  whoami)    shift; cmd_whoami "$@" ;;
  ticket)    shift; cmd_ticket "$@" ;;
  search)    shift; cmd_search "$@" ;;
  note)      shift; cmd_note "$@" ;;
  note-file) shift; cmd_note_file "$@" ;;
  *) echo "usage: fd.sh {setup|whoami|ticket <id|url>|search <words|filter-query> [count]|note <ticket> <text> [--notify email]...|note-file <ticket> <file> [--notify email]...}" >&2
     echo "Read-only, plus private notes. There is no reply, public note or ticket update, by design." >&2
     exit 1 ;;
esac
