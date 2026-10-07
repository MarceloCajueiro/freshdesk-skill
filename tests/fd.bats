#!/usr/bin/env bats
#
# The suite runs against a `curl` shim on PATH (tests/bin/curl), so no test
# touches the network or a real Freshdesk account.
#
# FD and SKILL_MD can point at another revision, so the suite can be checked
# against a version that carries a defect: a test that cannot fail proves nothing.
#
# FD_BASH selects the interpreter, so the same tests run under bash 3.2
# (stock macOS) and modern bash.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FD="${FD:-$REPO_ROOT/freshdesk/fd.sh}"
  SKILL_MD="${SKILL_MD:-$REPO_ROOT/freshdesk/SKILL.md}"
  FD_BASH="${FD_BASH:-bash}"

  export FIXTURES="$REPO_ROOT/tests/fixtures"
  export PATH="$REPO_ROOT/tests/bin:$PATH"
  export TZ=UTC

  TMP="$(mktemp -d)"
  export CURL_LOG="$TMP/curl.log"; : > "$CURL_LOG"
  export CURL_ARGV_LOG="$TMP/argv.log"; : > "$CURL_ARGV_LOG"
  export CURL_CONFIG_LOG="$TMP/config.log"; : > "$CURL_CONFIG_LOG"
  export CURL_BODY_DIR="$TMP/bodies"; mkdir -p "$CURL_BODY_DIR"
  export XDG_CONFIG_HOME="$TMP/config"
  mkdir -p "$XDG_CONFIG_HOME/freshdesk"
  printf 'FRESHDESK_DOMAIN=acme.freshdesk.com\nFRESHDESK_API_KEY=FAKEKEY\n' \
    > "$XDG_CONFIG_HOME/freshdesk/config"
  chmod 600 "$XDG_CONFIG_HOME/freshdesk/config"

  unset FRESHDESK_DOMAIN FRESHDESK_API_KEY CURL_HTTP_STATUS CURL_HTTP_BODY CURL_FAIL_URLS CURL_NOTE_PUBLIC
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

fd() {
  run "$FD_BASH" "$FD" "$@"
}

# The JSON payload of the n-th request (0-based) that carried one.
payload() {
  cat "$CURL_BODY_DIR/body.${1:-0}.json"
}

# Every request that is not a read, as "METHOD url".
writes() {
  grep -v '^GET ' "$CURL_LOG" || true
}

file_mode() {
  # GNU stat uses -c, BSD stat uses -f. On Linux `stat -f` is valid but reports
  # the filesystem, so pick by what the platform's stat actually supports.
  if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

# Extracts the shell block containing the install-path lookup from SKILL.md,
# so the documented snippet is tested rather than a copy that can drift.
lookup_snippet() {
  awk '/^```bash$/{buf=""; inb=1; next} /^```$/{if (inb && buf ~ /for p in/) {printf "%s", buf; exit} inb=0} inb{buf = buf $0 "\n"}' "$SKILL_MD"
}

# A bare `! cmd` does not fail a bats test unless it is the last line, so every
# negative assertion below compares a count instead.

# --- credentials ------------------------------------------------------------

@test "fails with a clear message when no credentials are configured" {
  rm -rf "$XDG_CONFIG_HOME/freshdesk"
  fd whoami
  [ "$status" -ne 0 ]
  [[ "$output" == *"no credentials"* ]]
  [[ "$output" == *"fd.sh setup"* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "setup stores credentials from flags with mode 600" {
  rm -rf "$XDG_CONFIG_HOME/freshdesk"
  fd setup --domain https://acme.freshdesk.com/ --api-key K1
  [ "$status" -eq 0 ]
  local cfg="$XDG_CONFIG_HOME/freshdesk/config"
  [ "$(file_mode "$cfg")" = "600" ]
  grep -qx 'FRESHDESK_DOMAIN=acme.freshdesk.com' "$cfg"   # scheme and slash stripped
  grep -qx 'FRESHDESK_API_KEY=K1' "$cfg"
  [[ "$output" == *"Jane Doe <jane.doe@example.com>"* ]]   # verified right away
}

@test "setup defaults the domain to portabilis.freshdesk.com" {
  rm -rf "$XDG_CONFIG_HOME/freshdesk"
  fd setup --api-key K1
  [ "$status" -eq 0 ]
  grep -qx 'FRESHDESK_DOMAIN=portabilis.freshdesk.com' "$XDG_CONFIG_HOME/freshdesk/config"
}

@test "setup accepts two piped lines, and an empty domain line takes the default" {
  rm -rf "$XDG_CONFIG_HOME/freshdesk"
  run "$FD_BASH" -c "printf '%s\n' '' K2 | '$FD' setup"
  [ "$status" -eq 0 ]
  grep -qx 'FRESHDESK_DOMAIN=portabilis.freshdesk.com' "$XDG_CONFIG_HOME/freshdesk/config"
  grep -qx 'FRESHDESK_API_KEY=K2' "$XDG_CONFIG_HOME/freshdesk/config"

  rm -rf "$XDG_CONFIG_HOME/freshdesk"
  run "$FD_BASH" -c "printf '%s\n' other K3 | '$FD' setup"
  grep -qx 'FRESHDESK_DOMAIN=other.freshdesk.com' "$XDG_CONFIG_HOME/freshdesk/config"
}

@test "setup never echoes the API key" {
  rm -rf "$XDG_CONFIG_HOME/freshdesk"
  fd setup --api-key SECRETKEY123
  [[ "$output" != *"SECRETKEY123"* ]]
  run "$FD_BASH" -c "printf '%s\n' '' SECRETKEY456 | '$FD' setup"
  [[ "$output" != *"SECRETKEY456"* ]]
}

@test "setup fails fast on closed stdin instead of hanging" {
  rm -rf "$XDG_CONFIG_HOME/freshdesk"
  local start=$SECONDS
  run "$FD_BASH" -c "'$FD' setup < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminal"* ]]
  [ $((SECONDS - start)) -lt 5 ]
  [ ! -f "$XDG_CONFIG_HOME/freshdesk/config" ]
}

@test "setup times out on stdin that never delivers a line" {
  rm -rf "$XDG_CONFIG_HOME/freshdesk"
  local start=$SECONDS
  run env FD_SETUP_READ_TIMEOUT=1 "$FD_BASH" -c "'$FD' setup < /dev/zero"
  [ "$status" -ne 0 ]
  [ $((SECONDS - start)) -lt 15 ]
}

@test "the config file is parsed, never executed" {
  printf 'FRESHDESK_DOMAIN=acme.freshdesk.com\nFRESHDESK_API_KEY=FAKEKEY\ntouch %s/pwned\n$(touch %s/pwned2)\n' "$TMP" "$TMP" \
    > "$XDG_CONFIG_HOME/freshdesk/config"
  fd whoami
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/pwned" ]
  [ ! -e "$TMP/pwned2" ]
}

@test "environment variables win over the config file" {
  run env FRESHDESK_DOMAIN=other.freshdesk.com FRESHDESK_API_KEY=ENVKEY "$FD_BASH" "$FD" whoami
  [ "$status" -eq 0 ]
  grep -q 'https://other.freshdesk.com/api/v2/agents/me' "$CURL_LOG"
  [ "$(grep -c 'acme.freshdesk.com' "$CURL_LOG")" -eq 0 ]
  grep -qx 'user = "ENVKEY:X"' "$CURL_CONFIG_LOG"
}

@test "authenticates as <api key>:X through curl's stdin, never through argv" {
  fd whoami
  grep -qx 'user = "FAKEKEY:X"' "$CURL_CONFIG_LOG"
  [ "$(grep -c 'FAKEKEY' "$CURL_ARGV_LOG")" -eq 0 ]
}

@test "the API key never appears in output" {
  local c
  for c in "whoami" "ticket 123" "search boletim" "search status:2" "note 123 hello"; do
    # shellcheck disable=SC2086
    fd $c
    [[ "$output" != *"FAKEKEY"* ]]
  done
  [ "$(grep -c 'FAKEKEY' "$CURL_ARGV_LOG")" -eq 0 ]
}

# --- whoami -------------------------------------------------------------------

@test "whoami prints the agent's name and email" {
  fd whoami
  [ "$status" -eq 0 ]
  [ "$output" = "Jane Doe <jane.doe@example.com>" ]
  grep -qx 'GET https://acme.freshdesk.com/api/v2/agents/me' "$CURL_LOG"
}

# --- ticket -------------------------------------------------------------------

@test "ticket accepts an id, a #id and a ticket link" {
  local a
  for a in 123 '#123' 'https://acme.freshdesk.com/a/tickets/123' \
           'https://acme.freshdesk.com/helpdesk/tickets/123?foo=bar'; do
    : > "$CURL_LOG"
    fd ticket "$a"
    [ "$status" -eq 0 ]
    grep -q '/api/v2/tickets/123?include=requester,company' "$CURL_LOG"
  done
}

@test "ticket refuses something that is not a ticket, before any request" {
  fd ticket 'https://acme.freshdesk.com/a/contacts/9'
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a ticket"* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "ticket summarizes subject, status, priority, requester, company and tags" {
  fd ticket 123
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "#123  Boletim nao gera PDF" ]]
  [[ "$output" == *"Status: Open | Priority: High | Type: Incident"* ]]
  [[ "$output" == *"Requester: Maria Silva <maria@escola.example.org>"* ]]
  [[ "$output" == *"Company: Prefeitura de Exemplo"* ]]
  [[ "$output" == *"Tags: boletim, pdf"* ]]
  [[ "$output" == *"Link: https://acme.freshdesk.com/a/tickets/123"* ]]
  [[ "$output" == *"Description: Ao clicar em gerar boletim da turma 5A nada acontece."* ]]
}

@test "ticket marks every conversation as private or public" {
  fd ticket 123
  [[ "$output" == *$'\tPUBLIC, from customer\tmaria@escola.example.org\tPrimeira mensagem'* ]]
  [[ "$output" == *$'\tPRIVATE NOTE\tuser 9002\tEncaminhado'* ]]
  [[ "$output" == *$'\tPUBLIC REPLY\tsuporte@example.com\t'* ]]
  [[ "$output" == *$'\tPUBLIC NOTE\t'* ]]
}

@test "ticket shows the most recent conversations, reading every page" {
  # 150 conversations: the newest sit on page 2, which a single read would miss.
  cp -R "$FIXTURES" "$TMP/fx"
  jq -n '[range(1;101) | {id:., body_text:"msg \(.)", private:false, incoming:true, source:0,
          user_id:1, from_email:"c@x.org", created_at:"2026-10-01T10:00:00Z"}]' \
    > "$TMP/fx/tickets.123.conversations.json"
  jq -n '[range(101;151) | {id:., body_text:"msg \(.)", private:true, incoming:false, source:2,
          user_id:2, created_at:"2026-10-02T10:00:00Z"}]' \
    > "$TMP/fx/tickets.123.conversations.p2.json"
  FIXTURES="$TMP/fx" fd ticket 123
  [ "$status" -eq 0 ]
  [[ "$output" == *"Conversations (last 5 of 150, oldest first):"* ]]
  [[ "$output" == *"msg 150"* ]]
  [[ "$output" == *"msg 146"* ]]
  [[ "$output" != *"msg 145"* ]]
}

@test "ticket truncates long conversation text to 300 characters" {
  cp -R "$FIXTURES" "$TMP/fx"
  jq -n --arg t "$(printf 'x%.0s' $(seq 1 400))" \
    '[{id:1, body_text:$t, private:true, source:2, user_id:1, created_at:"2026-10-01T10:00:00Z"}]' \
    > "$TMP/fx/tickets.123.conversations.json"
  FIXTURES="$TMP/fx" fd ticket 123
  local text
  text="$(printf '%s\n' "$output" | grep 'PRIVATE NOTE' | awk -F'\t' '{print $4}')"
  [[ "$text" == *" [...]" ]]
  [ "${#text}" -lt 320 ]
}

@test "ticket reports a missing ticket as 404, not as empty output" {
  fd ticket 999
  [[ "$output" == "ERROR: not found (404)"* ]]
}

# --- search -------------------------------------------------------------------

@test "free-text search matches every word in recent subjects, as five TSV fields" {
  fd search "boletim pdf"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "INFO: matched subjects of the 4 most recently updated tickets"* ]]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(printf '%s\n' "${lines[1]}" | awk -F'\t' '{print NF}')" -eq 5 ]
  [[ "${lines[1]}" == *$'\t#123\tOpen\tBoletim nao gera PDF\thttps://acme.freshdesk.com/a/tickets/123' ]]
}

@test "free-text search is case-insensitive and lists newest first" {
  fd search BOLETIM
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[1]}" == *"#123"* ]]
  [[ "${lines[2]}" == *$'#125\tWaiting on Customer'* ]]
}

@test "free-text search asks for recently updated tickets, not the 30-day default" {
  fd search boletim
  grep -q 'GET https://acme.freshdesk.com/api/v2/tickets?order_by=updated_at&order_type=desc&per_page=100&page=1&updated_since=' "$CURL_LOG"
}

@test "free-text search reports NONE with its coverage" {
  fd search "nothing matches this"
  [[ "${lines[0]}" == "INFO: matched subjects"* ]]
  [ "${lines[1]}" = "NONE" ]
}

@test "a filter query goes to the search endpoint, quoted and encoded" {
  fd search "status:2 AND tag:'boletim'"
  [ "$status" -eq 0 ]
  grep -q "/api/v2/search/tickets?query=%22status%3A2%20AND%20tag%3A'boletim'%22" "$CURL_LOG" ||
    grep -q '/api/v2/search/tickets?query=%22status%3A2%20AND%20tag%3A%27boletim%27%22' "$CURL_LOG"
  [[ "$output" == *"INFO: showing 2 of 45 matches"* ]]
  [[ "$output" == *$'\t#124\tPending\tErro ao lancar nota\t'* ]]
}

@test "search refuses a count that is not a number" {
  fd search boletim abc
  [ "$status" -ne 0 ]
  [ ! -s "$CURL_LOG" ]
}

@test "a network failure surfaces as ERROR, never as NONE" {
  CURL_FAIL_URLS="api/v2/tickets" fd search boletim
  [[ "$output" == *"ERROR: network failure"* ]]
  [[ "$output" != *"NONE"* ]]
}

# --- HTTP errors --------------------------------------------------------------

@test "each HTTP error becomes one actionable line" {
  CURL_HTTP_STATUS=401 CURL_HTTP_BODY='{"code":"invalid_credentials","message":"You have to be logged in to perform this action."}' fd whoami
  [[ "$output" == "ERROR: invalid API key (401)"*"fd.sh setup"* ]]

  CURL_HTTP_STATUS=403 CURL_HTTP_BODY='{"code":"access_denied","message":"You are not authorized to perform this action."}' fd ticket 123
  [[ "$output" == "ERROR: forbidden (403)"*"not authorized"* ]]

  CURL_HTTP_STATUS=404 fd ticket 123
  [[ "$output" == "ERROR: not found (404)"* ]]

  CURL_HTTP_STATUS=429 fd search boletim
  [[ "$output" == "ERROR: rate limited (429)"* ]]

  CURL_HTTP_STATUS=400 CURL_HTTP_BODY='{"description":"Validation failed","errors":[{"field":"query","message":"Invalid value","code":"invalid_value"}]}' fd search status:x
  [[ "$output" == "ERROR: HTTP 400: Validation failed; query: Invalid value" ]]
}

@test "a non-JSON error page does not crash the script" {
  CURL_HTTP_STATUS=502 CURL_HTTP_BODY='<html><body>Bad Gateway</body></html>' fd ticket 123
  [ "$status" -eq 0 ]
  [ "$output" = "ERROR: HTTP 502" ]
}

# --- note: private, always ---------------------------------------------------

@test "note posts a private note to the ticket's notes endpoint" {
  fd note 123 "Can you check with the school?"
  [ "$status" -eq 0 ]
  [ "$output" = "OK: private note 7001 added to ticket #123 - https://acme.freshdesk.com/a/tickets/123" ]
  [ "$(writes)" = "POST https://acme.freshdesk.com/api/v2/tickets/123/notes" ]
  [ "$(payload | jq -r .private)" = "true" ]
  [ "$(payload | jq -r .body)" = "Can you check with the school?" ]
  [ "$(payload | jq -r 'has("notify_emails")')" = "false" ]
}

@test "note accepts a ticket link" {
  fd note 'https://acme.freshdesk.com/a/tickets/123' "x"
  [ "$status" -eq 0 ]
  [ "$(writes)" = "POST https://acme.freshdesk.com/api/v2/tickets/123/notes" ]
}

@test "note-file keeps line breaks, escapes markup and links URLs" {
  printf 'Line one & <two>\nSee https://github.com/acme/app/issues/42\n\nThanks\n' > "$TMP/note.txt"
  fd note-file 123 "$TMP/note.txt"
  [ "$status" -eq 0 ]
  [ "$(payload | jq -r .private)" = "true" ]
  [ "$(payload | jq -r .body)" = 'Line one &amp; &lt;two&gt;<br>See <a href="https://github.com/acme/app/issues/42">https://github.com/acme/app/issues/42</a><br><br>Thanks' ]
}

@test "--notify adds the agents to notify_emails, and the note stays private" {
  fd note 123 "heads up" --notify ana@example.com --notify bob@example.com
  [ "$status" -eq 0 ]
  [ "$(payload | jq -c .notify_emails)" = '["ana@example.com","bob@example.com"]' ]
  [ "$(payload | jq -r .private)" = "true" ]
}

@test "--notify refuses something that is not an email, before any request" {
  fd note 123 "x" --notify bob
  [ "$status" -ne 0 ]
  [ ! -s "$CURL_LOG" ]
}

@test "every attempt at a public note is refused before any request" {
  local opt
  for opt in --public --private=false "--private false" --reply --status=4 --assign; do
    : > "$CURL_LOG"
    # shellcheck disable=SC2086
    fd note 123 "text" $opt
    [ "$status" -ne 0 ]
    [[ "$output" == *"always private"* ]]
    [ ! -s "$CURL_LOG" ]
  done
}

@test "the note text cannot smuggle private:false into the payload" {
  fd note 123 '", "private": false, "x": "'
  [ "$(payload | jq -r .private)" = "true" ]
  [ "$(payload | jq -r 'keys | join(",")')" = "body,private" ]
}

@test "there is no command that replies, updates, assigns or deletes" {
  local c
  for c in reply forward update close assign delete status public-note; do
    : > "$CURL_LOG"
    fd "$c" 123 "text"
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage:"* ]]
    [ ! -s "$CURL_LOG" ]
  done
}

@test "across every command, the only write is a POST to a ticket's notes" {
  printf 'body\n' > "$TMP/n.txt"
  fd whoami
  fd ticket 123
  fd search boletim
  fd search status:2
  fd note 123 "a"
  fd note-file '#123' "$TMP/n.txt" --notify ana@example.com
  [ "$(writes | sort -u)" = "POST https://acme.freshdesk.com/api/v2/tickets/123/notes" ]
  local f
  for f in "$CURL_BODY_DIR"/body.*.json; do
    [ "$(jq -r .private "$f")" = "true" ]
  done
}

@test "the HTTP layer refuses every write except a POST to a ticket's notes" {
  # No command reaches these paths today; the allowlist is what keeps a future
  # command, or a crafted ticket argument, from replying to a customer.
  local call
  for call in "PUT /api/v2/tickets/123" \
              "POST /api/v2/tickets/123/reply" \
              "POST /api/v2/tickets/123/reply/notes" \
              "POST /api/v2/tickets/123/notes/../reply" \
              "POST /api/v2/tickets" \
              "DELETE /api/v2/tickets/123" \
              "GET /other/path"; do
    run "$FD_BASH" -c "source '$FD'; fd_curl $call"
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "refused" ]
  done
  [ ! -s "$CURL_LOG" ]

  run "$FD_BASH" -c "source '$FD'; fd_curl POST /api/v2/tickets/123/notes -d '{}'"
  [ "${lines[${#lines[@]}-1]}" = "201" ]
}

@test "reads are retried, a note is never retried" {
  # A retried POST after a timeout can create the same note twice.
  fd ticket 123
  fd note 123 "x"
  grep 'agents/me\|tickets/123?include' "$CURL_ARGV_LOG" | grep -q -- '--retry'
  [ "$(grep '/notes' "$CURL_ARGV_LOG" | grep -c -- '--retry')" -eq 0 ]
  grep -q '/notes' "$CURL_ARGV_LOG"
}

@test "a note Freshdesk stored as public is reported loudly" {
  CURL_NOTE_PUBLIC=1 fd note 123 "x"
  [ "$status" -ne 0 ]
  [[ "$output" == "ERROR: Freshdesk stored note 7001 as PUBLIC"* ]]
}

@test "note refuses an empty text or an unusable file before any request" {
  : > "$TMP/empty.txt"
  fd note 123 "   "
  [ "$status" -ne 0 ]
  fd note-file 123 "$TMP/empty.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"note file is empty"* ]]
  fd note-file 123 "$TMP/missing.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
  fd note abc "x"
  [ "$status" -ne 0 ]
  [ ! -s "$CURL_LOG" ]
}

@test "a network failure on a note is not reported as a clean failure" {
  # The POST may have landed before the connection dropped: say so, and do not retry.
  CURL_FAIL_URLS="notes" fd note 123 "x"
  [[ "$output" == *"may or may not have been created"* ]]
  [ "$(grep -c 'notes' "$CURL_LOG")" -eq 1 ]
}

@test "a note to a ticket that does not exist reports 404" {
  fd note 999 "x"
  [[ "$output" == "ERROR: not found (404)"* ]]
}

# --- the lookup snippet documented in SKILL.md ------------------------------

@test "SKILL.md still documents a lookup snippet" {
  [ -n "$(lookup_snippet)" ]
}

@test "documented lookup honours path priority over alphabetical order" {
  local h="$TMP/home" w="$TMP/work"
  mkdir -p "$h/.claude/skills/freshdesk" "$h/.agents/skills/freshdesk" "$w/.agents/skills/freshdesk"
  echo CLAUDE > "$h/.claude/skills/freshdesk/fd.sh"
  echo AGENTS > "$h/.agents/skills/freshdesk/fd.sh"
  echo CWD    > "$w/.agents/skills/freshdesk/fd.sh"
  run env HOME="$h" "$FD_BASH" -c "cd '$w' || exit 1
$(lookup_snippet)
cat \"\$FD\""
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE" ]
}

@test "documented lookup finds the sandbox mount path (Cowork)" {
  local h="$TMP/sessionhome" w="$TMP/nowhere"
  mkdir -p "$h/mnt/.skills/freshdesk" "$w"
  echo MOUNTED > "$h/mnt/.skills/freshdesk/fd.sh"
  run env HOME="$h" "$FD_BASH" -c "cd '$w' || exit 1
$(lookup_snippet)
cat \"\$FD\""
  [ "$status" -eq 0 ]
  [ "$output" = "MOUNTED" ]
}

@test "documented lookup reports a missing install instead of dying silently" {
  local h="$TMP/emptyhome" w="$TMP/neutral"
  mkdir -p "$h" "$w"
  run env HOME="$h" "$FD_BASH" -c "cd '$w' || exit 1
set -euo pipefail
$(lookup_snippet)
echo SHOULD_NOT_REACH"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD_NOT_REACH"* ]]
  [ -n "$output" ]
}
