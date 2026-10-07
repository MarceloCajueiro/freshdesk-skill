---
name: freshdesk
description: Read Freshdesk tickets and add PRIVATE notes to them from the terminal, via the Freshdesk API v2. Use when the user wants to check a support ticket ("what is ticket 4521 about", "show me that Freshdesk ticket", pasting a ticket link), find tickets ("is there a ticket about the report card bug"), or pass something to the support team ("tell support that...", "ask support to check with the client", "leave a note on the ticket", "send this to support"). It never replies to the customer - private notes only.
---

# Freshdesk from the terminal

All access goes through `fd.sh`, in this skill's directory.
**Use the path of the directory this file was loaded from** - it is already known, and it is always correct.

If you need to locate it anyway, check the known install paths in order and take the first that exists.
Never use `find ~`: it takes almost a minute on a real home directory and can return an unrelated or outdated copy.
Do not use `ls` for this either - it sorts its arguments, so the first path listed is not the one you get back.

```bash
FD=
for p in "$HOME"/.claude/skills/freshdesk/fd.sh \
         "$HOME"/.agents/skills/freshdesk/fd.sh \
         "$HOME"/.codex/skills/freshdesk/fd.sh \
         "$HOME"/mnt/.skills/freshdesk/fd.sh \
         .agents/skills/freshdesk/fd.sh \
         .claude/skills/freshdesk/fd.sh; do
  [ -f "$p" ] && { FD=$p; break; }
done
[ -n "$FD" ] || { echo "ERROR: fd.sh not found; install with 'npx skills add MarceloCajueiro/freshdesk-skill'" >&2; exit 1; }
```

```bash
fd.sh setup                              # one-time: stores the domain and API key
fd.sh whoami                             # verify credentials, prints "Name <email>"
fd.sh ticket 4521                        # one ticket: summary + latest conversations
fd.sh ticket "<ticket link>"             # same, from a pasted link
fd.sh search "boletim pdf"               # words in the subject of recently updated tickets
fd.sh search "status:2 AND tag:'escola'" # Freshdesk filter query
fd.sh note 4521 "text"                   # add a PRIVATE note
fd.sh note-file 4521 note.txt            # PRIVATE note, long text read from a file
fd.sh note-file 4521 note.txt --notify ana@example.com   # and notify an agent
```

`ERROR: <reason>` when a call fails, `NONE` when a search finds nothing.

If any command answers `ERROR: no credentials`, tell the user to run `fd.sh setup` in their own terminal (in Claude Code: `! <path>/fd.sh setup`).
The prompt hides the API key as it is typed.
**Never ask the user to paste the API key into the chat**, and never print it, not even in debug output: a chat message lands in the transcript.

---

# The one rule: private notes only

This skill exists to talk to the **support team**, never to the customer.

- It reads tickets and adds **private notes**.
  Those are the only two actions.
- It **never replies to the customer**, never posts a public note, and never changes a ticket's status, priority, assignment, tags or fields.
- `fd.sh` has no command for any of that, and refuses any option that asks for it (`--public`, `--private=false`, `--reply`...).
  Its HTTP layer refuses every write except a POST to a ticket's notes, and the note payload always carries `"private": true`.

If the user asks to answer the customer, to close or reassign the ticket, or to make the note public, say plainly that this skill cannot do it, and offer a private note asking the support team to do it instead.
Never work around the rule with `curl` or any other tool.

---

# Finding the ticket

## A number or a link is not a search

When the user gives a ticket number (`4521`, `#4521`) or pastes a ticket link (`https://<domain>/a/tickets/4521`), **run `fd.sh ticket` on it directly.**

The output is the subject, status, priority, type, requester, company, tags, dates, link, the description (up to 500 characters) and the last 5 conversations, oldest first.
Each conversation line is `date<TAB>kind<TAB>author<TAB>text`, where kind is `PRIVATE NOTE`, `PUBLIC NOTE`, `PUBLIC REPLY` or `PUBLIC, from customer`.
Text longer than 300 characters is truncated with ` [...]`.
`FD_CONVERSATIONS=10` shows more.

Read the latest conversations before drafting a note: someone may already have asked the same question.

## Searching

Freshdesk's public API has **no free-text search over tickets**, so `fd.sh search` has two modes.

**Plain words** scan the most recently updated tickets (300 tickets from the last 90 days by default) and keep those whose **subject** contains every word, ignoring case.
The first line always states the coverage: `INFO: matched subjects of the N most recently updated tickets (last 90 days)`.
Older tickets, and words that appear only in the body, are not seen - say so instead of concluding "there is no ticket about it".
`FD_SEARCH_DAYS` and `FD_SEARCH_PAGES` (100 tickets each) widen the window.

- Use 1 to 3 distinctive words the customer would put in a subject, not the user's sentence: every word must match.
- Accents count: `boletim` will not match `boletím`.
  When unsure, use the shortest unaccented word.

**A filter query** - anything with `field:` - goes to Freshdesk's filter API as is:

| Query | Finds |
|---|---|
| `status:2` | Open tickets (3 Pending, 4 Resolved, 5 Closed) |
| `priority:4` | Urgent tickets (1 Low, 2 Medium, 3 High) |
| `tag:'boletim'` | Tickets with that tag |
| `agent_id:123` / `group_id:45` | Assigned to that agent or group |
| `created_at:>'2026-10-01'` | Created after that day |
| `status:2 AND (tag:'a' OR tag:'b')` | Combinations, with parentheses |

String values take single quotes.
The filter API skips archived tickets and may lag a few minutes behind recent changes.
When more tickets match than are shown, the first line says `INFO: showing N of M matches`.

Search output is TSV, one line per ticket, newest first: `updated<TAB>#id<TAB>status<TAB>subject<TAB>link`.

With 2 or more plausible tickets, show them and ask which one - never pick on the user's behalf.

## Presenting a ticket

Answer the question first, in one or two lines, with the link.
Then the details that matter for it.
Never paste the raw output.

```
#4521 - "Boletim nao gera PDF", Open, High, from Maria Silva (Prefeitura de Exemplo).
https://acme.freshdesk.com/a/tickets/4521

Last update Oct 6: support forwarded it to development in a private note.
```

---

# Sending a note to support

## Required flow

1. **Find the ticket** and read it (`fd.sh ticket`), as above.
2. **Draft the note.**
3. **Show the draft and wait for approval.**
4. **Send and report.**

**Never skip step 3.**
A note goes out in the user's name, cannot be edited through this skill, and notifies people.

## Drafting

The user describes the subject; they do not dictate the text.
Write in the user's language, in their voice: an internal message between colleagues, direct, no greeting formula, no signature.

- **Say what support needs to do**, in the first line: check something with the client, confirm a detail, tell them a fix is out.
- **Give the context** in a sentence or two: what was found, what changed.
- **Link the work.** GitHub references are always repository-qualified: `acme/i-educar#123`, or the full URL.
  A bare `#123` means nothing inside Freshdesk.
- Keep it short.
  Support reads notes in a ticket view, not a document.

The note is plain text: line breaks are kept, URLs become links, and markup characters are shown literally.

If the user dictates exact wording in quotes, send exactly that.

## Confirming and sending

Show the ticket (number and subject), the full note, and anyone it will notify, and ask whether to send.
If they ask for changes, redo it and show again.

One-line text: `fd.sh note <ticket> "text"`.
Long or multi-line text: write it to a temporary file and use `fd.sh note-file <ticket> <file>`.
That avoids shell escaping problems.

`--notify agent@example.com` (repeatable) emails specific agents about the note.
Use it only when the user names someone; by default the ticket's watchers already see new notes.

Output is `OK: private note <id> added to ticket #<id> - <link>`.
Report what actually happened, with the link.

If the output says `ERROR: network failure ... The note may or may not have been created`, **do not simply send again** - that can post the same note twice.
Open the ticket with `fd.sh ticket` and check the latest conversations first.

---

# Common errors

- `ERROR: no credentials` → run `fd.sh setup`.
- `ERROR: invalid API key (401)` → the key is wrong or was regenerated.
  Get the current one in Freshdesk (profile picture > Profile settings > View API key) and run `fd.sh setup` again.
- `ERROR: forbidden (403)` → this agent's role or group cannot see that ticket.
  It exists; it is out of reach for this account.
- `ERROR: not found (404)` → wrong ticket number, **or** a ticket this agent cannot see.
  Never tell the user it does not exist.
- `ERROR: rate limited (429)` → the account's per-minute API quota is spent, often by other integrations.
  Wait a minute and retry once.
- `ERROR: refused by this skill` → something asked for a write other than a private note.
  That is the rule working, not a bug.
- `NONE` on a plain-word search → the ticket may be older than the scanned window, or the words are only in its body.
  Widen `FD_SEARCH_DAYS` / `FD_SEARCH_PAGES`, or ask for the ticket number.

Never print the API key, not even in debug output.
