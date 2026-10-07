# freshdesk-skill

An agent skill that lets your coding agent read Freshdesk tickets and leave **private notes** for the support team, from the terminal.

Ask in plain language and the agent does the rest:

> what is ticket 4521 about?

> is there a ticket about the report card PDF?

> tell support on 4521 that the fix is out and ask them to confirm with the school

It works with any agent that supports skills - Claude Code, Codex, Cursor, OpenCode and others.

## Private notes only

The skill talks to your **support team**, never to the customer.
Support reads private notes on the ticket faster than comments on a GitHub issue, so that is where the agent writes.

- It reads tickets and adds private notes. Those are the only two actions.
- It never replies to the customer, never posts a public note, and never changes a ticket's status, priority, assignment, tags or fields.
- The rule is enforced in code, not only in the instructions: the script has no command for any other write, refuses any option that asks for one, and its HTTP layer refuses every request except reads and a POST to a ticket's notes. The note payload always carries `"private": true`, and the test suite proves it.

## Install

```bash
npx skills add MarceloCajueiro/freshdesk-skill
```

The installer asks which agent to install into. Then set up credentials once:

```bash
# the path is printed by the installer; in Claude Code it is:
~/.claude/skills/freshdesk/fd.sh setup
```

It prompts for the Freshdesk domain (default `portabilis.freshdesk.com`) and your API key, hiding the key as you type.
Non-interactive, for a dotfiles or provisioning script:

```bash
fd.sh setup --domain yourcompany.freshdesk.com --api-key YOUR_KEY

# or two lines on stdin, in this order (an empty first line takes the default domain):
printf '%s\n' "yourcompany.freshdesk.com" "YOUR_KEY" | fd.sh setup
```

The domain can be given as `yourcompany`, `yourcompany.freshdesk.com` or a full URL.
Credentials are stored in `${XDG_CONFIG_HOME:-~/.config}/freshdesk/config` with mode `600`.
Environment variables of the same name (`FRESHDESK_DOMAIN`, `FRESHDESK_API_KEY`) always take precedence, which is handy in CI.

Verify:

```bash
fd.sh whoami     # prints "Your Name <you@example.com>"
```

## Getting an API key

In Freshdesk, in the browser:

1. Click your profile picture, top right.
2. **Profile settings**.
3. **View API key**, then copy it.

The key acts as you: notes are posted in your name, and you see only the tickets your role allows.
Regenerating it in Freshdesk invalidates the old one; run `fd.sh setup` again afterwards.

## Requirements

- `bash` (3.2 or later, so stock macOS works), `curl` and `jq`
- A Freshdesk agent account with API access

## What the agent can do

| Ask | What happens |
|---|---|
| "what is ticket 4521 about?" *(or a pasted ticket link)* | Summary of the ticket: subject, status, priority, requester, company, tags and the latest conversations, each marked private or public |
| "is there a ticket about X?" | Matches words in the subjects of recently updated tickets, and says how many it scanned |
| "open urgent tickets tagged boletim" | Runs a Freshdesk filter query |
| "tell support on 4521 that ..." | Drafts a private note, **shows it to you, waits for approval**, then posts it |

Posting always asks for confirmation first. A note goes out in your name and notifies people.

## CLI reference

The agent drives this for you, but it is a normal script:

```bash
fd.sh setup                                   # store credentials
fd.sh whoami                                  # verify credentials
fd.sh ticket 4521                             # one ticket, by id, #id or link
fd.sh search "boletim pdf"                    # words in recent subjects
fd.sh search "status:2 AND priority:4"        # Freshdesk filter query
fd.sh note 4521 "text"                        # private note
fd.sh note-file 4521 note.txt                 # private note, text from a file
fd.sh note 4521 "text" --notify ana@example.com   # and email an agent about it
```

Search output is TSV: `updated<TAB>#id<TAB>status<TAB>subject<TAB>link`.

A note is plain text: line breaks are kept, URLs become links, and `<`, `>` and `&` are shown literally.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `FD_CONVERSATIONS` | `5` | How many of the latest conversations `ticket` shows |
| `FD_SEARCH_DAYS` | `90` | How far back a plain-word search looks |
| `FD_SEARCH_PAGES` | `3` | How many pages of 100 tickets a plain-word search scans |
| `FD_HTTP_TIMEOUT` | `20` | Per-request timeout, in seconds |

## Claude Desktop

Same verdict as for [rocketchat-skill](https://github.com/MarceloCajueiro/rocketchat-skill#claude-desktop), and for the same reasons:

- **Claude Code tab**: works as-is.
- **Cowork**: probably works with `XDG_CONFIG_HOME` pointed at your real `~/.config`; untested.
- **Chat window** (Customize → Skills): does not work. That sandbox has no route to your Freshdesk account and no access to your credentials file.

## Tests

```bash
brew install bats-core      # or your platform's package
bats tests/fd.bats
FD_BASH=/bin/bash bats tests/fd.bats    # exercise bash 3.2 on macOS
```

The suite never touches the network: `tests/bin/curl` shadows `curl` on `PATH`, answers from fixtures with the HTTP status the script asks for, and logs every call, its arguments and its payload.
That log is what the private-only rule is tested against: across every command, the only write is a POST to a ticket's notes, and every payload says `"private": true`.

CI also plants the one defect this skill must never ship - a note sent as public - and requires the suite to go red. A test that cannot fail proves nothing.

The documented install-path lookup in `SKILL.md` is extracted from the file and executed, so the instructions the agent follows cannot silently drift from what actually works.

## Design notes

**There is no free-text ticket search in the Freshdesk API.** `/api/v2/search/tickets` takes a filter language over fields (`status:2 AND tag:'x'`), not words. So a query with `field:` goes there as is, and plain words scan the most recently updated tickets and match their subjects. The list endpoint returns only tickets created in the last 30 days unless asked otherwise, so the scan passes `updated_since` explicitly, and the output always states how many tickets it covered. "No match among the last 300" is not "no such ticket".

**The latest conversations are on the last page.** Freshdesk lists a ticket's conversations oldest first, so `ticket` reads every page before taking the tail.

**The API key never reaches argv.** It is handed to `curl` through `--config` on stdin, because command-line arguments are visible to every process on the machine through `ps`.

**A note is never retried.** Reads retry on transient failures; the POST does not, because a timeout can hide a note that was in fact created. When that happens the output says the note may or may not exist, and points at the ticket to check.

## License

MIT
