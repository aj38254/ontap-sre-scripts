# jira-bulk

Create and manage a batch of Jira issues from a table of rows — one issue per row, summary and
description rendered from templates.

Built for the quarterly ONTAP admin password rotation, then pulled apart so the Jira half is
reusable. Nothing in `jira_bulk.py` knows about ONTAP; everything specific to a piece of work lives
in a **job directory** under `jobs/`.

---

## Using this from a new Cursor chat

You don't have to write `job.json` or the templates by hand. Open a chat in this repo and give the
five things below — Cursor builds the job directory, renders the tickets so you can read them, and
walks you through creating them.

**What to provide:**

1. **An example ticket.** Paste an existing Jira ticket of the kind you want — description and the
   fields panel (Type, Priority, Component/s, Story Points, and any custom fields). This is the most
   useful single thing: field values and wording get copied from it exactly.
2. **Where they go.** Project key and issue type, e.g. *COPS / Change*. Plus the parent story or
   epic to link each one to, if there is one.
3. **The list.** One line per ticket, with whatever varies between them — hostnames, IPs, regions,
   owners. A pasted query result or spreadsheet column is fine; it doesn't need to be formatted.
4. **What varies in the text.** Which parts of the description change per ticket, and which are
   boilerplate to reproduce as-is.
5. **Anything to skip.** Rows that must *not* get a ticket, and why.

**A prompt that works:**

> Use `jira-bulk` to raise a batch of tickets. Create a new job under `jira-bulk/jobs/`.
>
> Example of the ticket I want: *(paste a whole Jira ticket — description and fields panel)*
>
> Create them in `<PROJECT>` as `<Issue Type>`, linked to `<PARENT-123>`.
>
> One per row of this list: *(paste the rows)*
>
> Per-ticket values are `<the columns that vary>`; everything else in the description is
> boilerplate, reproduce it verbatim.
>
> Skip any row where `<condition>`, because `<reason>`.

**Two things worth saying explicitly**, because they've caused rework before:

- *"Reproduce the description exactly, don't rewrite it."* Otherwise the wording gets tidied up and
  no longer matches what your team expects to review.
- *"Tell me before creating anything."* `render` and `probe` cost nothing and catch a wrong field
  or a bad template; 49 rejected creates are slower to recover from.

Then, in the terminal:

```bash
cd jira-bulk
export JIRA_TOKEN=...                    # Jira profile -> Personal Access Tokens
export JIRA_JOB=jobs/my-batch

./jira_bulk.py render      # read a few tickets under jobs/my-batch/tickets/
./jira_bulk.py probe       # ALWAYS before create
./jira_bulk.py create --limit 1          # check that one in Jira
./jira_bulk.py create                    # the rest
```

---

## Layout

```
jira-bulk/
  jira_bulk.py                   the tool — generic, no per-batch knowledge
  README.md
  jobs/
    _template/                   copy this to start a new batch (in git)
    <your-batch>/                one directory per batch (NOT in git)
      job.json                   project, issue type, field values, exclusions
      rows.tsv                   one row per issue
      summary.tmpl               one line
      description.tmpl           Jira wiki markup
      keep.txt                   ids to keep when cancelling/archiving/deleting
      created.tsv                written as issues are created (state)
      created_links.md           markdown table of URLs, generated
      tickets/                   `render` output, for reading before creating
```

**Job directories are not committed.** Each one is a batch of working state — a list of hosts, a
record of which tickets exist — that's specific to one round of one task and of no use to anyone
reading the repo later. `.gitignore` has `jira-bulk/jobs/*` with `_template` as the exception, so
the tool and the starting point are tracked and the batches aren't.

The trade-off: a job directory is the only copy of its `created.tsv`, which maps your rows to real
Jira keys. If a batch is still live, don't delete the directory — `assign`, `review`, `update` and
the disposal commands all read it.

## Templates

Placeholders are `${name}`, not `{name}`, because Jira wiki markup is full of literal braces
(`{code}`, `{panel:...}`, `{noformat}`). A `$` on its own — as in a pasted shell prompt like
`user@host:~$ ssh ...` — is left alone.

Available names are every column of `rows.tsv`, plus everything in `vars`, plus everything in
`computed`, plus `today`, `win_start` and `win_end` (derived from `date_fields`). `render` and
`probe` list any `${...}` the context can't fill, so a typo shows up as a warning rather than as a
silently blank spot in 49 tickets:

```
!! templates use placeholders with no value: nosuchthing, ownr
   available: id, name, owner, today, win_end, win_start
```

## job.json

| key | meaning |
|---|---|
| `project`, `issuetype` | where issues are created |
| `parent`, `linktype` | issue every one is linked to; omit `parent` to skip linking |
| `epic_name` / `epic_key` | Epic Link. The name is resolved to a key by search |
| `assignee` | `"me"`, a username, or `""` to leave unassigned |
| `rows`, `id_column`, `name_column` | the data and which column identifies a row |
| `priority`, `components`, `fields` | field values, matched to the create screen by name |
| `date_fields` | name → offset in days from the run date |
| `computed` | derived values, themselves templates over the row |
| `vars` | constants available to templates |
| `exclude` | rules that skip rows entirely |

Fields are matched by **name** at runtime, never by hardcoded id, so a job moves between Jira
instances. Anything the project doesn't offer is dropped with a warning instead of failing the
create.

`exclude` skips rows that must not get an issue at all:

```json
"exclude": [
  {"column": "cvs_username", "in": ["admin", ""], "reason": "control plane logs in as admin"}
]
```

Run `probe` before `create`, every time. Custom field ids and link type names are instance-specific;
`probe` reads them off the project's create screen and says what's required but unset — rather than
one wrong guess having every create rejected.

## Managing the batch afterwards

```bash
./jira_bulk.py assign                     # assignee -> you
./jira_bulk.py status                     # what the workflow actually offers
./jira_bulk.py review --reviewer nsood    # transition + @-mention
./jira_bulk.py update                     # re-push edited templates
./jira_bulk.py participants --remove nsood
```

`status` samples one issue per distinct status, so a batch spread across several shows the workflow
from each, and flags transitions that pop a screen:

```
from 'New'  (48 issue(s), e.g. COPS-102973):
  --to 'In Review'        via 'Submit for review'   REQUIRES: Reviewer
```

Multi-hop workflows and transition screens:

```bash
./jira_bulk.py review --via 'In Review' --field 'Reviewer=nsood'
```

## Dropping issues from a batch

Put the ids to keep in `keep.txt`; the three disposal commands act on everything else.

```bash
./jira_bulk.py cancel --yes          # transition to a terminal status
./jira_bulk.py archive --yes         # hidden from search, restorable
./jira_bulk.py prune --confirm DELETE
```

Prefer `cancel`. It keeps the audit trail, and it works with ordinary permissions — `prune` needs
*Delete Issues* and `archive` normally needs Jira admin, both of which SREs often don't have.
`perms` reports what the account may do, though note it answers at project level and can disagree
with reality: it reported *Delete Issues: yes* on COPS while every delete returned 403, because a
workflow property or issue security scheme can still refuse. The API response is the authority.

All three print both lists first and do nothing without the confirmation flag, and all three refuse
outright if an id in `keep.txt` has no issue — a typo there would otherwise hit the issue you were
protecting.

## Safety behaviour

- **Resumable.** Every key is written to `created.tsv` before the next issue starts, and rows
  already listed are skipped. A failure part-way through never duplicates on retry.
- **Fails fast.** Batch commands stop after three consecutive failures, since a rejected field
  rejects every issue identically.
- **Dry runs.** `create`, `update`, `assign`, `review`, `participants` and `cancel` all take
  `--dry-run`; `--limit N` restricts most of them to the first N.

## Jira quirks it already handles

- The combined `issue/createmeta?projectKeys=...` endpoint is gone in Jira 9 and misleadingly
  answers *"Issue Does Not Exist"*. The per-project endpoints are used instead.
- Epic Link takes an issue key, not the epic's name, so the name is resolved by search.
- Bulk archive is `POST /issue/archive` with a list of keys, while single archive is
  `PUT /issue/{key}/archive`.
- `notifyUsers=false` on archive itself requires admin rights, so it's opt-in (`--no-notify`)
  rather than the default.
