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

- It reads tickets and adds private notes.
  Those are the only two actions.
- It never replies to the customer, never posts a public note, and never changes a ticket's status, priority, assignment, tags or fields.
- The rule is enforced in code, not only in the instructions: the script has no command for any other write, refuses any option that asks for one, and its HTTP layer refuses every request except reads and a POST to a ticket's notes.
  The note always carries `"private": true` (as `private=true` when it has attachments), and the test suite proves it.

## Install

```bash
npx skills add MarceloCajueiro/freshdesk-skill
```

The installer asks which agent to install into.
Then set up credentials once:

```bash
# the path is printed by the installer; in Claude Code it is:
~/.claude/skills/freshdesk/fd.sh setup
```

It asks for your Freshdesk domain and your API key, hiding the key as you type.
There is no default domain.
Non-interactive, for a dotfiles or provisioning script, pipe the key on stdin:

```bash
# the key from a secret manager, never typed on the command line
op read "op://Private/Freshdesk/api key" | fd.sh setup --domain yourcompany

# or two lines on stdin, in this order: the domain, then the key
some-command-that-prints-them | fd.sh setup
```

There is no `--api-key` flag: a key in the arguments is visible to every process on the machine through `ps`, and stays in the shell history.
The domain can be given as `yourcompany`, `yourcompany.freshdesk.com` or a full URL.
A URL is reduced to its host, and a domain carrying a user, a port or a query is refused.
Credentials are stored in `${XDG_CONFIG_HOME:-~/.config}/freshdesk/config` with mode `600`, in a directory with mode `700`.
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
| "... and attach this log" | Same, with the file attached to the private note; the confirmation lists each file's name and size |

Posting always asks for confirmation first.
A note goes out in your name and notifies people.

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
fd.sh note 4521 "text" --attach error.log --attach screen.png   # private note with files
```

`--notify` and `--attach` are repeatable, and work on `note` and `note-file` alike.

Search output is TSV: `updated<TAB>#id<TAB>status<TAB>subject<TAB>link`.

A note is plain text: line breaks are kept, URLs become links, and `<`, `>` and `&` are shown literally.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `FD_CONVERSATIONS` | `5` | How many of the latest conversations `ticket` shows |
| `FD_SEARCH_DAYS` | `90` | How far back a plain-word search looks |
| `FD_SEARCH_PAGES` | `3` | How many pages of 100 tickets a plain-word search scans |
| `FD_HTTP_TIMEOUT` | `20` | Per-request timeout, in seconds |
| `FD_UPLOAD_TIMEOUT` | `120` | Timeout for a note with attachments, in seconds |

## Claude Desktop

Same verdict as for [rocketchat-skill](https://github.com/MarceloCajueiro/rocketchat-skill#claude-desktop), and for the same reasons:

- **Claude Code tab**: works as-is.
- **Cowork**: probably works with `XDG_CONFIG_HOME` pointed at your real `~/.config`; untested.
- **Chat window** (Customize → Skills): does not work.
  That sandbox has no route to your Freshdesk account and no access to your credentials file.

## Tests

```bash
brew install bats-core      # or your platform's package
bats tests/fd.bats
FD_BASH=/bin/bash bats tests/fd.bats    # exercise bash 3.2 on macOS
```

The suite never touches the network: `tests/bin/curl` shadows `curl` on `PATH`, answers from fixtures with the HTTP status the script asks for, and logs every call, its arguments and its payload.
That log is what the private-only rule is tested against: across every command, the only write is a POST to a ticket's notes, and every payload says `"private": true`.

CI also plants the one defect this skill must never ship - a note sent as public, in the JSON request and in the multipart one used for attachments - and requires the suite to go red.
A test that cannot fail proves nothing.

The documented install-path lookup in `SKILL.md` is extracted from the file and executed, so the instructions the agent follows cannot silently drift from what actually works.

## Design notes

**There is no free-text ticket search in the Freshdesk API.** `/api/v2/search/tickets` takes a filter language over fields (`status:2 AND tag:'x'`), not words.
So a query with `field:` goes there as is, and plain words scan the most recently updated tickets and match their subjects.
The list endpoint returns only tickets created in the last 30 days unless asked otherwise, so the scan passes `updated_since` explicitly, and the output always states how many tickets it covered.
"No match among the last 300" is not "no such ticket".

**The latest conversations are on the last page.** Freshdesk lists a ticket's conversations oldest first, so `ticket` reads every page before taking the tail.

**The API key never reaches argv.** It is handed to `curl` through `--config` on stdin, because command-line arguments are visible to every process on the machine through `ps`.

**The key only travels to your Freshdesk host, over HTTPS.** `curl` runs with `-q`, so nothing in `~/.curlrc` (`insecure`, `proxy`, `location`) applies, with `--proto =https`, and without `-L`, so a redirect is reported as an error and never followed.
The domain and the key are validated on every run, including when they come from the environment: a domain with `@`, a port or a query, or a key with a quote, is refused before any request.

**Ticket content is untrusted.** Customers write it, so the script strips control characters before printing it, and `SKILL.md` tells the agent to treat it as data and never as instructions.
A note that contains the API key is refused, so pointing `note-file` at the config file cannot publish it.

**Attachments go as multipart, with every other field sent literally.** Freshdesk takes files only as `multipart/form-data`, so a note with `--attach` is sent that way and without the JSON `Content-Type`, which would hide the boundary curl writes.
The body, `private=true` and each notify address go through `curl --form-string`, never `-F`: with `-F`, a note starting with `@` or `<` would make curl read a file from this machine into it.
Only the attachments use `-F`, and a path curl's `-F` syntax would misread (`;`, `,`, `"`, `\`, a line break) is refused with a hint to copy the file to a plain name.

**Attachments are checked before anything is sent.** Each file must exist, be a regular readable file and not be empty.
The config file is refused by identity (symlinks included), and any file containing the API key is refused by content, binary files too; the key reaches `grep` on stdin, not in its arguments.
Files adding up to more than 20 MB are refused.
That is Freshdesk's limit for all of a ticket's attachments together, so the API can still refuse a smaller set when the ticket already has some, and the error says so.
The success line is followed by the attachment names Freshdesk reports, and a warning when it lists fewer than were sent.

**A note is never retried.** Reads retry on transient failures; the POST does not, because a timeout can hide a note that was in fact created.
When that happens the output says the note may or may not exist, and points at the ticket to check.

## License

MIT
