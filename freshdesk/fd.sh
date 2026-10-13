#!/usr/bin/env bash
# Freshdesk REST helper for the `freshdesk` agent skill.
# Credentials: run `fd.sh setup`. They are stored in
# ${XDG_CONFIG_HOME:-~/.config}/freshdesk/config with mode 600.
# Environment variables of the same name always win over the config file.
#
# HARD RULE: this script reads tickets, adds PRIVATE notes and edits the text of
# a private note the key's own agent wrote. Nothing else. It never replies to a
# customer, never posts or makes a note public, and never changes a ticket's
# status, assignment or fields. fd_curl enforces that for every call.
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/freshdesk"
CONFIG_FILE="$CONFIG_DIR/config"

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
# A value that came from the environment stays a plain shell variable: curl
# and jq, the only child processes, have no use for the key in theirs.
export -n FRESHDESK_DOMAIN FRESHDESK_API_KEY

# Dependencies, checked once with an actionable message instead of a cryptic failure.
for _fd_dep in curl jq; do
  command -v "$_fd_dep" >/dev/null 2>&1 || {
    echo "ERROR: '$_fd_dep' is required but was not found in PATH." >&2
    exit 1
  }
done
unset _fd_dep

# Accepts "acme", "acme.freshdesk.com" or a full URL, returns the host.
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

# A host name and nothing else: no userinfo (`x@evil.example`), port, query or
# fragment can ride along into the URL that carries the key.
fd_valid_domain() {
  case "$1" in
    ""|.*|*.|*..*|*[!A-Za-z0-9.-]*) return 1 ;;
  esac
}

# The key is written into curl's config as a quoted string, and into the config
# file one line per value. A quote, backslash, space or control character could
# break out of either, so such a key is refused. Freshdesk keys are alphanumeric.
fd_valid_key() {
  case "$1" in
    ""|*[![:graph:]]*|*[\"\\]*) return 1 ;;
  esac
}

cmd_setup() {
  local domain="" key="" have_domain=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain)  domain="${2:-}"; have_domain=1; shift 2 ;;
      --api-key|--api-key=*)
        echo "ERROR: --api-key is not accepted: a key in the arguments is visible to every process through 'ps' and stays in the shell history." >&2
        echo "Run 'fd.sh setup' in a terminal to type it at a hidden prompt, or pipe it: <command that prints the key> | fd.sh setup --domain DOMAIN" >&2
        return 1 ;;
      -h|--help)
        echo "usage: fd.sh setup [--domain DOMAIN]"
        echo "In a terminal, prompts for the domain (unless given) and the API key, hidden."
        echo "Otherwise reads them from stdin, one per line: the domain (unless --domain is given), then the key."
        echo "DOMAIN is acme, acme.freshdesk.com or https://acme.freshdesk.com."
        return 0 ;;
      *) echo "unknown option: $1" >&2; return 1 ;;
    esac
  done

  # Only a terminal gets the prompts; a pipe feeding the lines still works.
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
      # A last line with no newline (`pbpaste | fd.sh setup ...`) ends in EOF,
      # status 1, and is kept; only a timeout (status above 128) discards input.
      read -r ${fd_read_opts[@]+"${fd_read_opts[@]}"} __value || { [ $? -le 128 ] || __value=""; }
    fi
    printf -v "$__var" '%s' "$__value"
  }

  [ "$have_domain" -eq 1 ] || fd_prompt domain 'Freshdesk domain (acme, acme.freshdesk.com or a URL): '
  domain="$(fd_normalize_domain "$domain")"
  if [ -z "$domain" ]; then
    echo "ERROR: setup needs your Freshdesk domain. Run it in a terminal, or pipe two lines: the domain, then the API key." >&2
    return 1
  fi
  if ! fd_valid_domain "$domain"; then
    echo "ERROR: not a Freshdesk domain: $domain. Use acme, acme.freshdesk.com or https://acme.freshdesk.com." >&2
    return 1
  fi

  fd_prompt key 'API key (input hidden): ' hidden
  if [ -z "$key" ]; then
    echo "ERROR: setup needs the API key. Run it in a terminal, or pipe it on stdin." >&2
    return 1
  fi
  if ! fd_valid_key "$key"; then
    echo "ERROR: that API key has spaces, quotes or other characters a Freshdesk key never has. Copy it again from Freshdesk." >&2
    return 1
  fi

  # umask first, so neither the directory nor the file ever exists with wider
  # permissions. The file is written beside the config and renamed over it: an
  # existing file or symlink in its place is replaced, never written through.
  umask 077
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  local tmp
  tmp=$(mktemp "$CONFIG_DIR/config.XXXXXX")
  printf 'FRESHDESK_DOMAIN=%s\nFRESHDESK_API_KEY=%s\n' "$domain" "$key" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"

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

# Checked on every run, not only at setup: the environment can override the
# file, and a bad value here would put the key in a request to the wrong host,
# or inject a directive into curl's config.
if [ "${1:-}" != "setup" ] && [ -n "${1:-}" ]; then
  fd_valid_domain "$FRESHDESK_DOMAIN" || {
    echo "ERROR: FRESHDESK_DOMAIN is not a host name: $FRESHDESK_DOMAIN. Run 'fd.sh setup' again." >&2
    exit 1
  }
  fd_valid_key "$FRESHDESK_API_KEY" || {
    echo "ERROR: FRESHDESK_API_KEY has characters a Freshdesk key never has. Run 'fd.sh setup' again." >&2
    exit 1
  }
fi

# The single door to the API. Prints the response body, then a last line with
# the HTTP status (000 when the network failed, `refused` when the allowlist
# blocked the call).
#
# The allowlist below is the hard rule in code: GET anything under /api/v2/,
# POST only to a ticket's notes, and PUT only the body of the one note
# fd_check_own_note cleared. Reply, update, assign, delete and every other write
# are refused here, before curl runs, whatever the caller asked for.
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
    "PUT /api/v2/conversations/"*)
      # The endpoint takes a body and new attachments, nothing else. A JSON
      # object holding only `body` can neither make the note public nor touch
      # the files already on it; any other shape is refused.
      local cid="${path#/api/v2/conversations/}"
      case "$cid" in
        ""|*[!0-9]*) printf '%s %s\nrefused\n' "$method" "$path"; return 0 ;;
      esac
      if [ "$cid" != "${FD_EDITABLE_NOTE:-}" ] || [ $# -ne 2 ] || [ "$1" != "-d" ] ||
         ! printf '%s' "$2" | jq -e 'type == "object" and keys == ["body"] and (.body | type) == "string"' >/dev/null 2>&1; then
        printf '%s %s\nrefused\n' "$method" "$path"; return 0
      fi
      ;;
    *) printf '%s %s\nrefused\n' "$method" "$path"; return 0 ;;
  esac

  # A timeout on a write may hide a note that was in fact created or changed:
  # retrying a POST could post the same note twice. Only reads are retried.
  local retry=()
  [ "$method" = "GET" ] && retry=(--retry 2 --retry-connrefused)

  # A form field among the arguments makes it a multipart upload. curl writes
  # that Content-Type itself, with the boundary the body is cut by; a JSON one
  # forced on top would leave Freshdesk unable to parse the request. Uploads
  # get a longer timeout: 20 MB on a slow link takes more than 20 seconds.
  local ctype=(-H "Content-Type: application/json") timeout="${FD_HTTP_TIMEOUT:-20}" a
  for a in "$@"; do
    case "$a" in
      -F|--form|--form-string) ctype=(); timeout="${FD_UPLOAD_TIMEOUT:-120}"; break ;;
    esac
  done

  # The key goes in through --config on stdin, never as an argument: argv is
  # readable by every process on the machine through `ps`.
  # -q, first, skips ~/.curlrc, so no `insecure`, `location` or `proxy` set there
  # applies to a request carrying the key. --proto keeps it on HTTPS. There is
  # no -L: a redirect is answered as a non-200, never followed to another host.
  # -X and the URL come after the caller's arguments, so they always win.
  local out
  if ! out=$(printf 'user = "%s:X"\n' "$FRESHDESK_API_KEY" \
      | curl -q -sS --config - --proto =https --max-time "$timeout" ${retry[@]+"${retry[@]}"} \
          ${ctype[@]+"${ctype[@]}"} \
          -w '\n%{http_code}' \
          "$@" \
          -X "$method" "$BASE$path" 2>/dev/null); then
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
    refused) echo "ERROR: refused by this skill: $body. It only reads tickets, adds private notes and edits your own private notes." ;;
    000) echo "ERROR: network failure talking to Freshdesk ($BASE)" ;;
    401) echo "ERROR: invalid API key (401). Run 'fd.sh setup' again with a current key." ;;
    403) echo "ERROR: forbidden (403): this agent has no access to that $what${detail:+ - $detail}" ;;
    404) echo "ERROR: not found (404): no such $what, or this agent cannot see it" ;;
    413) echo "ERROR: request too large (413): Freshdesk refused the size of what was sent" ;;
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
# scrub runs over every response before it is printed: ticket text is written by
# customers, and an escape sequence in it would reach the terminal raw.
# shellcheck disable=SC2016
FD_JQ_DEFS='
  def status_name: {"2":"Open","3":"Pending","4":"Resolved","5":"Closed",
                    "6":"Waiting on Customer","7":"Waiting on Third Party"}[tostring] // "status \(.)";
  def priority_name: {"1":"Low","2":"Medium","3":"High","4":"Urgent"}[tostring] // "priority \(.)";
  def day: if . == null then "?" else sub("\\.[0-9]+"; "") | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M") end;
  def scrub: if type == "string" then gsub("[[:cntrl:]]+"; " ")
             elif type == "object" then map_values(scrub)
             elif type == "array" then map(scrub) else . end;
  def scrub_lines: gsub("\r\n?"; "\n") | gsub("[^\\n[:^cntrl:]]+"; " ");
  def kind: if .private == true then "PRIVATE NOTE"
            elif .source == 2 then "PUBLIC NOTE"
            elif .incoming == true then "PUBLIC, from customer"
            else "PUBLIC REPLY" end;
  def oneline: gsub("[[:cntrl:]]+"; " ") | gsub("  +"; " ") | ltrimstr(" ") | rtrimstr(" ");
  def clip($n): if length > $n then .[0:$n] + " [...]" else . end;
'

# Internal: every conversation of a ticket, oldest first, as one JSON array, or
# one ERROR line. They come a page at a time and the most recent ones are on the
# last page, so every page is read until a short one ends the list, up to
# FD_CONVERSATION_PAGES pages of FD_CONVERSATIONS_PER_PAGE.
FD_CONVERSATIONS_PER_PAGE=100
fd_conversations() {
  local id="$1" per="$FD_CONVERSATIONS_PER_PAGE" page=1 all='[]' chunk n
  while [ "$page" -le "${FD_CONVERSATION_PAGES:-10}" ]; do
    chunk=$(fd_get "/api/v2/tickets/$id/conversations?per_page=$per&page=$page" "ticket")
    case "$chunk" in ERROR:*) printf '%s\n' "$chunk"; return 0 ;; esac
    all=$(jq -n --argjson a "$all" --argjson b "$chunk" '$a + $b')
    n=$(printf '%s' "$chunk" | jq 'length')
    [ "$n" -lt "$per" ] && break
    page=$((page + 1))
  done
  printf '%s' "$all"
}

# Internal: true when a ticket's conversations filled every page read, so more
# may exist beyond them. $1 is the array fd_conversations printed.
fd_conversations_capped() {
  [ "$(printf '%s' "$1" | jq 'length')" -ge $(( ${FD_CONVERSATION_PAGES:-10} * FD_CONVERSATIONS_PER_PAGE )) ]
}

# Internal: the id of the agent the API key belongs to, or one ERROR line.
fd_my_id() {
  local me myid
  me=$(fd_get "/api/v2/agents/me" "agent")
  case "$me" in ERROR:*) printf '%s\n' "$me"; return 0 ;; esac
  myid=$(printf '%s' "$me" | jq -r '.id // empty')
  case "$myid" in
    ""|*[!0-9]*) echo "ERROR: Freshdesk did not say which agent this API key belongs to" ;;
    *) printf '%s' "$myid" ;;
  esac
}

cmd_whoami() {
  local body
  body=$(fd_get "/api/v2/agents/me" "agent")
  case "$body" in ERROR:*) printf '%s\n' "$body"; return 0 ;; esac
  printf '%s' "$body" | jq -r "$FD_JQ_DEFS"'scrub | "\(.contact.name // "?") <\(.contact.email // "?")>"'
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

  local all
  all=$(fd_conversations "$id")
  case "$all" in ERROR:*) printf '%s\n' "$all"; return 0 ;; esac

  printf '%s' "$ticket" | jq -r --arg link "$(fd_ticket_link "$id")" \
    --argjson convs "$all" --argjson last "${FD_CONVERSATIONS:-5}" "$FD_JQ_DEFS"'
    scrub | ($convs | scrub) as $convs |
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
          | kind as $kind
          | "\(.created_at | day)\t\($kind)\t\(.from_email // "user \(.user_id // "?")")\t\((.body_text // "") | oneline | clip(300))")
       end)'
}

# Internal: prints one TSV line per ticket of a JSON array.
fd_ticket_rows() {
  jq -r --arg base "$BASE" "$FD_JQ_DEFS"'
    .[] | scrub | [(.updated_at | day), "#\(.id)", (.status | status_name),
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
# breaks, and turns bare URLs into links. Quotes are escaped too, and a URL
# stops at one: otherwise `https://x"onclick="...` would add an attribute.
FD_JQ_HTML='
  gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")
  | gsub("\""; "&quot;") | gsub("\u0027"; "&#39;")
  | gsub("(?<u>https?://(?:(?!&quot;|&#39;)[^\\s<])+)"; "<a href=\"\(.u)\">\(.u)</a>")
  | gsub("\r?\n"; "<br>")
'

# Freshdesk caps the attachments of a whole ticket at 20 MB, not those of one
# note: files already on the ticket count against the same limit.
FD_ATTACH_MAX_BYTES=$((20 * 1024 * 1024))

# Internal: checks every file in FD_ATTACH before anything is sent, and prints
# one ERROR line for the first that cannot go. An attachment is read by every
# agent on the ticket, so the checks guard what leaves this machine as much as
# what curl is able to upload.
fd_check_attachments() {
  local f shown size total=0 rc
  for f in ${FD_ATTACH[@]+"${FD_ATTACH[@]}"}; do
    # The path is echoed back with control characters replaced: a line break or
    # an escape sequence in it must not reach the terminal raw.
    shown=$(printf '%s' "$f" | tr '[:cntrl:]' '?')
    # curl -F reads `;` as the start of `type=` or `filename=`, `,` as a list of
    # files and `"` or `\` as quoting, so such a path uploads something else, or
    # nothing. Escaping it is fragile across curl versions; a plain name is not.
    case "$f" in
      *[\;,\"\\]*|*[[:cntrl:]]*)
        echo "ERROR: the attachment path has a character curl cannot upload from (; , \" \\ or a line break): $shown. Copy or rename the file to a plain name and attach that."
        return 1 ;;
    esac
    [ -e "$f" ] || { echo "ERROR: attachment not found: $shown"; return 1; }
    [ -f "$f" ] || { echo "ERROR: attachment is not a regular file: $shown"; return 1; }
    [ -r "$f" ] || { echo "ERROR: attachment is not readable: $shown"; return 1; }
    [ -s "$f" ] || { echo "ERROR: attachment is empty: $shown"; return 1; }
    # Refused by identity, not only by content: a key from the environment wins
    # over the file's, so the file can hold another key the content check below
    # does not look for. -ef follows symlinks and sees through `..` paths.
    if [ "$f" -ef "$CONFIG_FILE" ]; then
      echo "ERROR: $shown is this skill's credentials file; it was not sent."
      return 1
    fi
    # wc pads its number with spaces on BSD; the arithmetic drops them.
    size=$(( $(wc -c < "$f") ))
    total=$((total + size))
  done

  if [ "$total" -gt "$FD_ATTACH_MAX_BYTES" ]; then
    echo "ERROR: the attachments add up to $(awk -v b="$total" 'BEGIN { printf "%.1f", b / 1048576 }') MB, over Freshdesk's 20 MB. That limit is for all of a ticket's attachments together, so even less can be refused when the ticket already has some. Nothing was sent."
    return 1
  fi

  # Last, because it reads every byte. The key reaches grep on stdin, never as
  # an argument, where `ps` would show it. -a reads a binary file as text
  # instead of skipping it, and a file grep cannot read is refused, not sent.
  # A relative path gets ./ in front, as it does when sent: to grep, a file
  # named `-` is the stdin the key was just read from, and `-x` is an option.
  for f in ${FD_ATTACH[@]+"${FD_ATTACH[@]}"}; do
    shown=$(printf '%s' "$f" | tr '[:cntrl:]' '?')
    case "$f" in /*) ;; *) f="./$f" ;; esac
    rc=0
    printf '%s\n' "$FRESHDESK_API_KEY" | LC_ALL=C grep -qaF -f - "$f" || rc=$?
    case "$rc" in
      1) ;;
      0) echo "ERROR: the attachment $shown contains your Freshdesk API key; it was not sent."; return 1 ;;
      *) echo "ERROR: could not read the attachment: $shown"; return 1 ;;
    esac
  done
}

# Internal: posts a private note. $1 ticket arg, $2 text. The agents to notify
# and the files to attach come from fd_note_args, in FD_NOTIFY and FD_ATTACH.
fd_post_note() {
  local arg="$1" text="$2"
  local id
  id=$(fd_ticket_id "$arg")
  [ -n "$id" ] || { echo "ERROR: not a ticket id or ticket link: $arg"; return 1; }
  [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ] || { echo "ERROR: the note is empty"; return 1; }
  # A note is read by everyone on the ticket. `note-file` on the config file,
  # by mistake or because a ticket asked for it, must not publish the key.
  case "$text" in
    *"$FRESHDESK_API_KEY"*) echo "ERROR: the note contains your Freshdesk API key; it was not sent."; return 1 ;;
  esac

  local e
  for e in ${FD_NOTIFY[@]+"${FD_NOTIFY[@]}"}; do
    case "$e" in
      *@*.*) ;;
      *) echo "ERROR: not an email address: $e"; return 1 ;;
    esac
  done

  local nattach=${#FD_ATTACH[@]}
  if [ "$nattach" -gt 0 ]; then
    fd_check_attachments || return 1
  fi

  # `private` is a literal in both forms of the request: no argument, flag or
  # variable can reach it.
  local req=()
  if [ "$nattach" -eq 0 ]; then
    local emails='[]' payload
    for e in ${FD_NOTIFY[@]+"${FD_NOTIFY[@]}"}; do
      emails=$(jq -n --argjson a "$emails" --arg e "$e" '$a + [$e]')
    done
    payload=$(jq -n --arg t "$text" --argjson n "$emails" "
      {body: (\$t | $FD_JQ_HTML), private: true}
      + (if (\$n | length) > 0 then {notify_emails: \$n} else {} end)")
    req=(-d "$payload")
  else
    # Files go as multipart/form-data, the only form the API takes them in.
    # Every value that is not a file goes through --form-string, which sends it
    # as is: with -F, a note starting with `@` or `<` would have curl read a
    # file from this machine into the note.
    local html f
    html=$(jq -rn --arg t "$text" "\$t | $FD_JQ_HTML")
    req=(--form-string "body=$html" --form-string "private=true")
    for e in ${FD_NOTIFY[@]+"${FD_NOTIFY[@]}"}; do
      req+=(--form-string "notify_emails[]=$e")
    done
    for f in "${FD_ATTACH[@]}"; do
      # A file named `-` would be `@-`, which curl reads from stdin instead.
      case "$f" in /*) ;; *) f="./$f" ;; esac
      req+=(-F "attachments[]=@$f")
    done
  fi

  local res status body msg
  res=$(fd_curl POST "/api/v2/tickets/$id/notes" "${req[@]}")
  status=$(fd_status "$res")
  body=$(fd_body "$res")
  case "$status" in
    200|201) ;;
    000) echo "ERROR: network failure talking to Freshdesk ($BASE). The note may or may not have been created: check $(fd_ticket_link "$id") before sending again."; return 0 ;;
    *)
      msg=$(fd_error "$status" "$body" "ticket")
      # Only the API knows what the ticket already holds, so the local 20 MB
      # check cannot rule this out.
      if [ "$nattach" -gt 0 ]; then
        case "$status:$msg" in
          413:*|400:*[Aa]ttachment*)
            msg="$msg. All of a ticket's attachments together cannot exceed 20 MB, counting those already on it: send fewer or smaller files, or link to them instead." ;;
        esac
      fi
      printf '%s\n' "$msg"
      return 0 ;;
  esac

  local nid private
  nid=$(printf '%s' "$body" | jq -r '.id // empty' 2>/dev/null || true)
  private=$(printf '%s' "$body" | jq -r '.private' 2>/dev/null || true)
  if [ "$private" = "false" ]; then
    echo "ERROR: Freshdesk stored note $nid as PUBLIC. Open $(fd_ticket_link "$id") and delete or fix it now."
    return 1
  fi
  echo "OK: private note ${nid:-?} added to ticket #$id - $(fd_ticket_link "$id")"

  [ "$nattach" -gt 0 ] || return 0
  # The names come from Freshdesk, not from the arguments: they are what the
  # ticket actually holds.
  local got names
  got=$(printf '%s' "$body" | jq -r '(.attachments // []) | length' 2>/dev/null || echo 0)
  names=$(printf '%s' "$body" | jq -r "$FD_JQ_DEFS"'
    [(.attachments // [])[] | (.name // "?") | tostring | oneline] | join(", ")' 2>/dev/null || true)
  echo "Attachments ($got): ${names:--}"
  if [ "$got" != "$nattach" ]; then
    echo "WARNING: $nattach file(s) sent, but Freshdesk lists $got on the note. Check $(fd_ticket_link "$id")."
  fi
}

# Internal: parses `[--notify email]... [--attach file]...` after the positional
# arguments. Anything else is refused, including every attempt at a public note.
fd_note_args() {
  FD_NOTIFY=()
  FD_ATTACH=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --notify) [ -n "${2:-}" ] || { echo "ERROR: --notify needs an email address"; return 1; }
                FD_NOTIFY+=("$2"); shift 2 ;;
      --attach) [ -n "${2:-}" ] || { echo "ERROR: --attach needs a file"; return 1; }
                FD_ATTACH+=("$2"); shift 2 ;;
      *) echo "ERROR: unknown option: $1. Notes are always private; this skill cannot reply to a customer or post a public note."; return 1 ;;
    esac
  done
}

# note <ticket> <text> [--notify email]... [--attach file]...
cmd_note() {
  local usage="usage: fd.sh note <ticket> <text> [--notify agent@example.com]... [--attach file]..."
  [ $# -ge 2 ] || { echo "$usage" >&2; return 1; }
  local ticket="$1" text="$2"
  shift 2
  fd_note_args "$@" || return 1
  fd_post_note "$ticket" "$text"
}

# Internal: refuses this skill's own config file as the text of a note. The
# content check on the text only knows the key in use, and a key from the
# environment wins over the file's, so the file can hold another one.
fd_not_config_file() {
  if [ "$1" -ef "$CONFIG_FILE" ]; then
    echo "ERROR: $1 is this skill's credentials file; it was not sent."
    return 1
  fi
}

# note-file <ticket> <file> [--notify email]... [--attach file]... - the text comes from a file
cmd_note_file() {
  local usage="usage: fd.sh note-file <ticket> <file> [--notify agent@example.com]... [--attach file]..."
  [ $# -ge 2 ] || { echo "$usage" >&2; return 1; }
  local ticket="$1" file="$2"
  shift 2
  fd_note_args "$@" || return 1
  [ -e "$file" ] || { echo "ERROR: note file not found: $file"; return 1; }
  [ -r "$file" ] || { echo "ERROR: note file is not readable: $file"; return 1; }
  [ -s "$file" ] || { echo "ERROR: note file is empty: $file"; return 1; }
  fd_not_config_file "$file" || return 1
  local text
  text=$(cat "$file") || { echo "ERROR: could not read the note file: $file"; return 1; }
  fd_post_note "$ticket" "$text"
}

# notes <ticket> [note_id] - the notes of a ticket with their ids, or the whole
# text of one of them. Replies and customer messages are not notes, and are left out.
cmd_notes() {
  local usage="usage: fd.sh notes <ticket> [note_id]"
  [ $# -ge 1 ] && [ $# -le 2 ] || { echo "$usage" >&2; return 1; }
  local id nid="${2:-}"
  id=$(fd_ticket_id "$1")
  [ -n "$id" ] || { echo "ERROR: not a ticket id or ticket link: $1"; return 1; }
  case "$nid" in *[!0-9]*) echo "ERROR: not a note id: $nid"; return 1 ;; esac

  local myid all
  myid=$(fd_my_id)
  case "$myid" in ERROR:*) printf '%s\n' "$myid"; return 0 ;; esac
  all=$(fd_conversations "$id")
  case "$all" in ERROR:*) printf '%s\n' "$all"; return 0 ;; esac

  local capped=0
  fd_conversations_capped "$all" && capped=1

  if [ -z "$nid" ]; then
    printf '%s' "$all" | jq -r --argjson me "$myid" --argjson capped "$capped" "$FD_JQ_DEFS"'
      [.[] | select(.source == 2)] as $notes
      | if ($notes | length) == 0 then "NONE"
        else "INFO: \($notes | length) notes on this ticket, oldest first\(if $capped == 1 then ", from its first \(length) conversations" else "" end). \"you\" marks the notes you wrote.",
          ($notes[] | scrub
           | [(.id | tostring), (.created_at | day), kind,
              (if .user_id == $me then "you" else "user \(.user_id // "?")" end),
              "\((.attachments // []) | length) file(s)",
              ((.body_text // "") | oneline | clip(120))] | @tsv)
        end'
    return 0
  fi

  local note
  note=$(printf '%s' "$all" | jq --argjson n "$nid" 'map(select(.id == $n)) | first // empty')
  if [ -z "$note" ]; then
    fd_note_not_found "$id" "$nid" "$capped"
    return 0
  fi
  printf '%s' "$note" | jq -r --argjson me "$myid" "$FD_JQ_DEFS"'
    (.attachments // []) as $files
    | (.body_text // "") as $text
    | scrub
    | "Note \(.id) on ticket #\(.ticket_id // "?"): \(if .source == 2 then kind else "not a note (\(kind))" end), by \(if .user_id == $me then "you" else "user \(.user_id // "?")" end), \(.created_at | day)\(if .last_edited_at then ", edited \(.last_edited_at | day)" else "" end)",
      "Attachments (\($files | length)): \(if ($files | length) == 0 then "-" else [$files[] | (.name // "?") | tostring | oneline] | join(", ") end)",
      "",
      ($text | scrub_lines)'
}

# Internal: the ERROR for a note id the ticket's conversations do not hold.
fd_note_not_found() {
  local id="$1" nid="$2" capped="$3"
  if [ "$capped" = 1 ]; then
    echo "ERROR: note $nid is not among the conversations read of ticket #$id, which stop at FD_CONVERSATION_PAGES=${FD_CONVERSATION_PAGES:-10} pages. Raise it and retry."
  else
    echo "ERROR: note $nid is not on ticket #$id. Run 'fd.sh notes $id' to see its notes."
  fi
}

# Internal: refuses, with one ERROR line, a note this skill must not edit, and
# prints its attachment count when it may. $1 ticket id, $2 note id.
# A note may be edited only when it is on that ticket, is a note and not a
# reply, is private, and was written by the agent the API key belongs to.
fd_check_own_note() {
  local id="$1" nid="$2" myid all note
  myid=$(fd_my_id)
  case "$myid" in ERROR:*) printf '%s\n' "$myid"; return 1 ;; esac
  all=$(fd_conversations "$id")
  case "$all" in ERROR:*) printf '%s\n' "$all"; return 1 ;; esac

  note=$(printf '%s' "$all" | jq --argjson n "$nid" 'map(select(.id == $n)) | first // empty')
  if [ -z "$note" ]; then
    local capped=0
    fd_conversations_capped "$all" && capped=1
    fd_note_not_found "$id" "$nid" "$capped"
    return 1
  fi

  local on_ticket is_note is_private owner
  on_ticket=$(printf '%s' "$note" | jq -r --argjson t "$id" '(.ticket_id // $t) == $t')
  is_note=$(printf '%s' "$note" | jq -r '.source == 2')
  is_private=$(printf '%s' "$note" | jq -r '.private == true')
  owner=$(printf '%s' "$note" | jq -r '.user_id // "?" | tostring')

  [ "$on_ticket" = true ] || { echo "ERROR: Freshdesk lists conversation $nid under ticket #$id, but says it belongs to another ticket. Nothing was changed."; return 1; }
  [ "$is_note" = true ] || { echo "ERROR: conversation $nid is a reply or a customer message, not a note. This skill edits only private notes."; return 1; }
  [ "$is_private" = true ] || { echo "ERROR: note $nid is PUBLIC: the customer may see it. This skill edits only private notes."; return 1; }
  [ "$owner" = "$myid" ] || { echo "ERROR: note $nid was written by user $owner, not by you (agent $myid). This skill edits only your own notes."; return 1; }

  printf '%s' "$note" | jq '(.attachments // []) | length'
}

# edit-note <ticket> <note_id> <file> - replaces the text of one of your own
# private notes with the text of a file. Its attachments stay, and it stays private.
cmd_edit_note() {
  local usage="usage: fd.sh edit-note <ticket> <note_id> <file>"
  if [ $# -ne 3 ]; then
    echo "$usage" >&2
    echo "It replaces the text of one of your own private notes, and nothing else: there is no option to make a note public." >&2
    return 1
  fi
  local id nid="$2" file="$3"
  id=$(fd_ticket_id "$1")
  [ -n "$id" ] || { echo "ERROR: not a ticket id or ticket link: $1"; return 1; }
  case "$nid" in ""|*[!0-9]*) echo "ERROR: not a note id: $nid"; return 1 ;; esac

  [ -e "$file" ] || { echo "ERROR: note file not found: $file"; return 1; }
  [ -r "$file" ] || { echo "ERROR: note file is not readable: $file"; return 1; }
  [ -s "$file" ] || { echo "ERROR: note file is empty: $file"; return 1; }
  fd_not_config_file "$file" || return 1
  local text
  text=$(cat "$file") || { echo "ERROR: could not read the note file: $file"; return 1; }
  [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ] || { echo "ERROR: the note is empty"; return 1; }
  case "$text" in
    *"$FRESHDESK_API_KEY"*) echo "ERROR: the note contains your Freshdesk API key; it was not sent."; return 1 ;;
  esac

  local before
  before=$(fd_check_own_note "$id" "$nid") || { printf '%s\n' "$before"; return 1; }

  # Only `body`: the request has no field that could make the note public, and
  # without `attachments` the files already on the note are left as they are.
  local payload res status body
  payload=$(jq -n --arg t "$text" "{body: (\$t | $FD_JQ_HTML)}")
  FD_EDITABLE_NOTE="$nid"
  res=$(fd_curl PUT "/api/v2/conversations/$nid" -d "$payload")
  FD_EDITABLE_NOTE=""
  status=$(fd_status "$res")
  body=$(fd_body "$res")
  case "$status" in
    200) ;;
    000) echo "ERROR: network failure talking to Freshdesk ($BASE). The note may or may not have been changed: check it with 'fd.sh notes $id $nid' before editing again."; return 0 ;;
    *) fd_error "$status" "$body" "note"; return 0 ;;
  esac

  local private got names
  private=$(printf '%s' "$body" | jq -r '.private' 2>/dev/null || true)
  case "$private" in
    true) ;;
    false)
      echo "ERROR: after the edit, Freshdesk reports note $nid as PUBLIC. Open $(fd_ticket_link "$id") and check it now."
      return 1 ;;
    *)
      echo "ERROR: the edit was sent, but Freshdesk's answer does not confirm note $nid is still private. Open $(fd_ticket_link "$id") and check it now."
      return 1 ;;
  esac
  echo "OK: private note $nid on ticket #$id updated - $(fd_ticket_link "$id")"

  got=$(printf '%s' "$body" | jq -r '(.attachments // []) | length' 2>/dev/null || echo 0)
  names=$(printf '%s' "$body" | jq -r "$FD_JQ_DEFS"'
    [(.attachments // [])[] | (.name // "?") | tostring | oneline] | join(", ")' 2>/dev/null || true)
  [ "$before" -eq 0 ] && [ "$got" -eq 0 ] && return 0
  echo "Attachments ($got): ${names:--}"
  if [ "$got" -lt "$before" ]; then
    echo "WARNING: the note had $before file(s) before the edit, and Freshdesk now lists $got. Check $(fd_ticket_link "$id")."
  fi
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
  notes)     shift; cmd_notes "$@" ;;
  edit-note) shift; cmd_edit_note "$@" ;;
  *) echo "usage: fd.sh {setup|whoami|ticket <id|url>|search <words|filter-query> [count]|note <ticket> <text> [--notify email]... [--attach file]...|note-file <ticket> <file> [--notify email]... [--attach file]...|notes <ticket> [note_id]|edit-note <ticket> <note_id> <file>}" >&2
     echo "Read-only, plus private notes and edits to your own private notes. There is no reply, public note or ticket update, by design." >&2
     exit 1 ;;
esac
