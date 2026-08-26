#!/usr/bin/env python3
"""
Create and manage a batch of Jira issues from a table of rows.

One issue per row of a TSV, with the summary and description rendered from
templates. Everything specific to a piece of work — project, issue type, field
values, templates, which rows to skip — lives in a job directory, so the same
tool serves any repeated batch: password rotations, upgrades, audits, whatever
comes next quarter.

    ./jira_bulk.py -j jobs/my-job render          # write issue text to disk, no network
    ./jira_bulk.py -j jobs/my-job probe           # check auth, fields, link types
    ./jira_bulk.py -j jobs/my-job create --dry-run
    ./jira_bulk.py -j jobs/my-job create          # create them, link to the parent
    ./jira_bulk.py -j jobs/my-job update          # re-push summary/description
    ./jira_bulk.py -j jobs/my-job assign          # set the assignee
    ./jira_bulk.py -j jobs/my-job status          # where they are in the workflow
    ./jira_bulk.py -j jobs/my-job review          # transition and @-mention someone
    ./jira_bulk.py -j jobs/my-job participants    # edit Request participants
    ./jira_bulk.py -j jobs/my-job cancel          # transition the ones dropped from scope
    ./jira_bulk.py -j jobs/my-job archive         # archive them instead
    ./jira_bulk.py -j jobs/my-job prune           # delete them, if you have the rights
    ./jira_bulk.py -j jobs/my-job perms           # what this account may do
    ./jira_bulk.py -j jobs/my-job jql             # JQL for the keep/drop sets

See README.md for the job directory layout.

Self-hosted Jira takes a personal access token rather than an API token. Mint
one under Profile -> Personal Access Tokens and export it:

    export JIRA_TOKEN=...

Creation is resumable: every issue is written to created.tsv before the next one
starts, and rows already listed there are skipped, so re-running after a failure
never makes a second copy.
"""

import argparse
import csv
import datetime
import json
import os
import pathlib
import string
import sys
import urllib.error
import urllib.parse
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
J = None  # the loaded Job; set by main()


# --------------------------------------------------------------------- job --

class Job:
    """A job directory: what to create, from what, with which field values."""

    def __init__(self, path):
        self.dir = pathlib.Path(path).expanduser().resolve()
        cfg_file = self.dir / "job.json"
        if not cfg_file.exists():
            sys.exit(f"no job.json in {self.dir}\n"
                     f"See {HERE / 'README.md'} for the layout.")
        try:
            cfg = json.loads(cfg_file.read_text())
        except json.JSONDecodeError as e:
            sys.exit(f"{cfg_file} is not valid JSON: {e}")
        self.cfg = cfg

        self.jira = os.environ.get(
            "JIRA_URL", cfg.get("jira_url", "")).rstrip("/")
        if not self.jira:
            sys.exit("set jira_url in job.json, or JIRA_URL in the environment")

        self.project = cfg.get("project") or sys.exit("job.json needs a project")
        self.issuetype = cfg.get("issuetype", "Task")
        self.parent = cfg.get("parent", "")
        self.linktype = cfg.get("linktype", "Relates")
        self.epic_name = cfg.get("epic_name", "")
        self.epic_key = cfg.get("epic_key", "")
        self.assignee = cfg.get("assignee", "")
        self.priority = cfg.get("priority", "")
        self.components = cfg.get("components", [])
        self.fields = cfg.get("fields", {})
        self.date_fields = cfg.get("date_fields", {})
        self.computed = cfg.get("computed", {})
        self.vars = cfg.get("vars", {})
        self.excludes = cfg.get("exclude", [])

        self.id_column = cfg.get("id_column", "id")
        self.name_column = cfg.get("name_column", self.id_column)

        self.rows_file = self.dir / cfg.get("rows", "rows.tsv")
        self.summary_tmpl = self.dir / cfg.get("summary_template", "summary.tmpl")
        self.description_tmpl = self.dir / cfg.get("description_template",
                                                   "description.tmpl")
        self.created = self.dir / cfg.get("created", "created.tsv")
        self.links = self.dir / cfg.get("links", "created_links.md")
        self.keep_file = self.dir / cfg.get("keep", "keep.txt")
        self.ticketdir = self.dir / "tickets"
        self.title = cfg.get("title", self.dir.name)

    # -- rows ---------------------------------------------------------------

    def rows(self):
        if not self.rows_file.exists():
            sys.exit(f"missing {self.rows_file} — nothing to build issues from")
        out = []
        with self.rows_file.open() as fh:
            for r in csv.DictReader(fh, delimiter="\t"):
                if any((v or "").strip() for v in r.values()):
                    out.append(r)
        if not out:
            sys.exit(f"{self.rows_file} has no data rows")
        for r in out:
            if self.id_column not in r:
                sys.exit(f"{self.rows_file} has no {self.id_column!r} column "
                         f"(id_column in job.json). Columns: "
                         f"{', '.join(sorted(r))}")
        return out

    def in_scope(self, row):
        """(bool, reason) — rows an exclude rule matches get no issue."""
        for rule in self.excludes:
            col = rule.get("column")
            val = (row.get(col) or "").strip().lower()
            bad = [str(v).strip().lower() for v in rule.get("in", [])]
            if val in bad:
                return False, rule.get("reason", f"{col}={val!r} is excluded")
        return True, ""

    # -- rendering ----------------------------------------------------------

    def context(self, row):
        """Template variables: the row, plus job vars, dates and computed values."""
        ctx = dict(self.vars)
        ctx.update(row)
        ctx["win_start"] = jira_date(min(self.date_fields.values(), default=0), "date")
        ctx["win_end"] = jira_date(max(self.date_fields.values(), default=0), "date")
        ctx["today"] = jira_date(0, "date")
        for name, tmpl in self.computed.items():
            ctx[name] = string.Template(tmpl).safe_substitute(ctx)
        return ctx

    def _render(self, path, row):
        if not path.exists():
            sys.exit(f"missing template {path}")
        tmpl = path.read_text()
        ctx = self.context(row)
        # safe_substitute so stray $ in pasted console output survives; unknown
        # ${...} placeholders are caught by check_templates() instead.
        return string.Template(tmpl).safe_substitute(ctx)

    def summary(self, row):
        return self._render(self.summary_tmpl, row).strip()

    def description(self, row):
        return self._render(self.description_tmpl, row)

    def check_templates(self, row):
        """Names used as ${...} in the templates that the context can't fill."""
        known = set(self.context(row))
        missing = set()
        for path in (self.summary_tmpl, self.description_tmpl):
            if not path.exists():
                continue
            for m in string.Template.pattern.finditer(path.read_text()):
                name = m.group("braced") or m.group("named")
                if name and name not in known:
                    missing.add(name)
        return sorted(missing)

    # -- state --------------------------------------------------------------

    def created_rows(self):
        if not self.created.exists():
            return []
        with self.created.open() as fh:
            return [r for r in csv.DictReader(fh, delimiter="\t") if r.get("key")]

    def record(self, row, key, linked):
        new = not self.created.exists()
        with self.created.open("a") as fh:
            w = csv.writer(fh, delimiter="\t", lineterminator="\n")
            if new:
                w.writerow(["id", "name", "key", "linked", "url"])
            w.writerow([row[self.id_column], row.get(self.name_column, ""),
                        key, linked, f"{self.jira}/browse/{key}"])

    def rewrite_created(self, rows):
        with self.created.open("w") as fh:
            w = csv.writer(fh, delimiter="\t", lineterminator="\n")
            w.writerow(["id", "name", "key", "linked", "url"])
            for r in rows:
                w.writerow([r["id"], r.get("name", ""), r["key"],
                            r.get("linked", ""),
                            r.get("url", f"{self.jira}/browse/{r['key']}")])
        self.write_links()

    def write_links(self):
        done = self.created_rows()
        with self.links.open("w") as fh:
            fh.write(f"# {self.title}\n\n")
            if self.parent:
                fh.write(f"Parent: [{self.parent}]"
                         f"({self.jira}/browse/{self.parent})\n\n")
            fh.write("| Ticket | Id | Name |\n|---|---|---|\n")
            for r in done:
                fh.write(f"| [{r['key']}]({self.jira}/browse/{r['key']}) "
                         f"| {r['id']} | {r.get('name','')} |\n")

    def keep_ids(self):
        if not self.keep_file.exists():
            sys.exit(f"missing {self.keep_file} — list the ids to keep, "
                     f"one per line")
        ids = []
        for line in self.keep_file.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                ids.append(line)
        return ids

    def split_by_keep(self):
        rows = self.created_rows()
        if not rows:
            sys.exit(f"nothing in {self.created}")
        by_id = {r["id"]: r for r in rows}
        unknown = [i for i in self.keep_ids() if i not in by_id]
        if unknown:
            sys.exit(f"these ids have no issue in {self.created.name}: "
                     f"{', '.join(unknown)}\nRefusing to run — a typo here hits "
                     f"the issue you meant to keep.")
        keep = set(self.keep_ids())
        return ([r for r in rows if r["id"] in keep],
                [r for r in rows if r["id"] not in keep])


def jira_date(days, schema_type):
    """Offset in days from now, in whichever of Jira's two date shapes is wanted."""
    when = datetime.datetime.now().astimezone() + datetime.timedelta(days=days)
    if schema_type == "datetime":
        return when.strftime("%Y-%m-%dT%H:%M:%S.000%z")
    return when.strftime("%Y-%m-%d")


# -------------------------------------------------------------------- REST --

class ApiError(Exception):
    def __init__(self, status, detail):
        super().__init__(f"HTTP {status}: {detail}")
        self.status, self.detail = status, detail


def token():
    t = os.environ.get("JIRA_TOKEN", "").strip()
    if not t:
        sys.exit("set JIRA_TOKEN (Jira profile -> Personal Access Tokens)")
    return t


def api(path, method="GET", body=None, fatal=True):
    url = f"{J.jira}/rest/api/2/{path.lstrip('/')}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode()
            if not raw.strip():
                return {}
            try:
                return json.loads(raw)
            except json.JSONDecodeError:
                # Bulk archive answers with a result stream, not a JSON document.
                return {"raw": raw[:400]}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:600]
        if fatal:
            raise SystemExit(f"{method} {url}\nHTTP {e.code}: {detail}")
        raise ApiError(e.code, detail)
    except urllib.error.URLError as e:
        raise SystemExit(f"{method} {url}\ncannot reach Jira: {e.reason}\n"
                         "On the corporate network / VPN?")


def _norm(values):
    """The paginated createmeta returns a list; the legacy one a dict."""
    return {
        v["fieldId"]: {
            "name": v.get("name"),
            "required": v.get("required"),
            "schema": v.get("schema"),
            "allowedValues": v.get("allowedValues"),
            "hasDefaultValue": v.get("hasDefaultValue"),
        }
        for v in values if v.get("fieldId")
    }


def createmeta():
    """
    Fields on the create screen.

    Jira 9 dropped the combined `issue/createmeta?projectKeys=...` endpoint — it
    routes to `issue/{key}` and answers "Issue Does Not Exist". Try the
    per-project endpoints first, keep the old one for older instances.
    """
    try:
        types = api(f"issue/createmeta/{J.project}/issuetypes", fatal=False)
    except ApiError:
        types = None

    if types and types.get("values") is not None:
        want = J.issuetype.strip().lower()
        match = [t for t in types["values"] if (t.get("name") or "").lower() == want]
        if not match:
            have = ", ".join(sorted(t.get("name", "?") for t in types["values"]))
            sys.exit(f"issue type {J.issuetype!r} not available in {J.project}. "
                     f"Has: {have}")
        tid = match[0]["id"]
        fields, start = {}, 0
        while True:
            page = api(f"issue/createmeta/{J.project}/issuetypes/{tid}"
                       f"?startAt={start}&maxResults=50")
            vals = page.get("values") or []
            fields.update(_norm(vals))
            if page.get("isLast", True) or not vals:
                break
            start += len(vals)
        return fields

    q = urllib.parse.urlencode({"projectKeys": J.project,
                                "issuetypeNames": J.issuetype,
                                "expand": "projects.issuetypes.fields"})
    try:
        meta = api(f"issue/createmeta?{q}", fatal=False)
    except ApiError as e:
        sys.exit(f"cannot read the create screen for {J.project}/{J.issuetype}: "
                 f"{e}\nCheck you can create one by hand first.")
    projects = meta.get("projects") or []
    if not projects:
        sys.exit(f"no create permission for {J.project}, or the key is wrong")
    types = projects[0].get("issuetypes") or []
    if not types:
        sys.exit(f"issue type {J.issuetype!r} not available in {J.project}")
    return types[0].get("fields") or {}


def find_epic():
    if J.epic_key:
        return J.epic_key
    if not J.epic_name:
        return ""
    jql = f'issuetype = Epic AND text ~ "{J.epic_name}" ORDER BY created DESC'
    q = urllib.parse.urlencode({"jql": jql, "maxResults": 5, "fields": "summary"})
    try:
        res = api(f"search?{q}", fatal=False)
    except ApiError:
        return ""
    issues = res.get("issues") or []
    return issues[0]["key"] if issues else ""


def find_user(query):
    q = urllib.parse.urlencode({"username": query, "maxResults": 10})
    try:
        return api(f"user/search?{q}", fatal=False)
    except ApiError:
        return []


def resolve_user(spec):
    """'me' is the token's own account; anything else must match exactly one."""
    if not spec:
        return None
    if spec.strip().lower() in ("me", "self"):
        return api("myself")
    users = find_user(spec)
    if not users:
        sys.exit(f"no Jira user matches {spec!r} — pass the exact username")
    if len(users) > 1:
        print(f"{spec!r} matches more than one user:")
        for u in users:
            print(f"  {u.get('name'):20} {u.get('displayName')} "
                  f"<{u.get('emailAddress')}>")
        sys.exit("re-run with the exact username")
    return users[0]


# ------------------------------------------------------------------ fields --

def resolve_optional(fields):
    """Map the job's human field names onto whatever ids this instance uses."""
    by_name = {v.get("name"): (k, v) for k, v in fields.items()}
    resolved, missing = {}, []

    for name, value in J.fields.items():
        hit = by_name.get(name)
        if not hit:
            missing.append(name)
            continue
        fid, spec = hit
        schema_type = (spec.get("schema") or {}).get("type")
        if schema_type == "number":
            resolved[fid] = float(value)
        elif spec.get("allowedValues") is not None or schema_type == "option":
            resolved[fid] = {"value": value}
        else:
            resolved[fid] = value

    for name, offset in J.date_fields.items():
        hit = by_name.get(name)
        if not hit:
            missing.append(name)
            continue
        fid, spec = hit
        resolved[fid] = jira_date(offset, (spec.get("schema") or {}).get("type"))

    return resolved, missing


def epic_field_id(fields):
    for fid, spec in fields.items():
        if (spec.get("name") or "").strip().lower() == "epic link":
            return fid
    return ""


def field_by_name(name, sample_key):
    meta = api(f"issue/{sample_key}/editmeta").get("fields", {})
    want = name.strip().lower()
    for fid, spec in meta.items():
        if (spec.get("name") or "").strip().lower() == want:
            return fid, spec
    return None, None


def build_fields(row, optional, epic_fid="", epic_key="", assignee=""):
    f = {
        "project": {"key": J.project},
        "issuetype": {"name": J.issuetype},
        "summary": J.summary(row),
        "description": J.description(row),
    }
    if J.priority:
        f["priority"] = {"name": J.priority}
    if J.components:
        f["components"] = [{"name": c} for c in J.components]
    f.update(optional)
    if epic_fid and epic_key:
        f[epic_fid] = epic_key
    if assignee:
        f["assignee"] = {"name": assignee}
    return f


# ------------------------------------------------------------- transitions --

def transitions_for(key):
    return api(f"issue/{key}/transitions?expand=transitions.fields").get(
        "transitions", [])


def pick_transition(trs, target):
    """Match the destination status first — transition names are often verbs."""
    t = target.strip().lower()
    for tr in trs:
        if ((tr.get("to") or {}).get("name") or "").strip().lower() == t:
            return tr
    for tr in trs:
        if (tr.get("name") or "").strip().lower() == t:
            return tr
    return None


def coerce(spec, value):
    """Shape a string from --field into whatever the field's schema wants."""
    t = (spec.get("schema") or {}).get("type")
    if t == "number":
        return float(value)
    if t == "user":
        return {"name": value}
    if t == "array":
        items = [v.strip() for v in value.split(",")]
        inner = (spec.get("schema") or {}).get("items")
        if inner == "user":
            return [{"name": v} for v in items]
        if spec.get("allowedValues") is not None:
            return [{"value": v} for v in items]
        return items
    if spec.get("allowedValues") is not None or t == "option":
        return {"value": value}
    return value


def transition_fields(tr, overrides):
    """Values for a transition screen, plus the names of anything still missing."""
    by_name = {(f.get("name") or ""): (fid, f)
               for fid, f in (tr.get("fields") or {}).items()}
    out = {}
    for item in overrides or []:
        name, _, value = item.partition("=")
        hit = by_name.get(name.strip())
        if hit:
            out[hit[0]] = coerce(hit[1], value.strip())
    missing = [f.get("name") for fid, f in (tr.get("fields") or {}).items()
               if f.get("required") and fid not in out
               and not f.get("hasDefaultValue")]
    return out, missing


def walk(rows, path, field_overrides, body, dry_run, cmd):
    """Step each issue along `path`, one status at a time."""
    done = stuck = failed = 0
    for r in rows:
        key = r["key"]
        cur = api(f"issue/{key}?fields=status")["fields"]["status"]["name"]
        hops, blocked = [], False

        for target in path:
            if cur.strip().lower() == target.strip().lower():
                continue
            trs = transitions_for(key)
            tr = pick_transition(trs, target)
            if not tr:
                print(f"  {key:14} stuck in {cur!r}, no transition to {target!r}")
                if done == 0 and stuck == 0:
                    opts = ", ".join(sorted({(t.get("to") or {}).get("name", "?")
                                             for t in trs})) or "nothing"
                    print(f"\n  from {cur!r} you can reach: {opts}\n"
                          f"  Stopping before touching the rest. Run `status` to "
                          f"see the whole workflow, then use --via for any "
                          f"intermediate step, e.g.\n"
                          f"      {cmd} --via '<one of the above>' --to {target!r}\n")
                    return done, stuck, failed
                blocked = True
                break

            fields, missing = transition_fields(tr, field_overrides)
            if dry_run:
                note = f"   needs: {', '.join(missing)}" if missing else ""
                hops.append(f"{target} (via {tr.get('name')!r}){note}")
                cur = target
                continue

            if missing:
                print(f"  {key:14} transition to {target!r} requires "
                      f"{', '.join(missing)} — pass it with "
                      f"--field '{missing[0]}=<value>'")
                if done == 0 and stuck == 0:
                    return done, stuck, failed
                blocked = True
                break

            payload = {"transition": {"id": tr["id"]}}
            if fields:
                payload["fields"] = fields
            try:
                api(f"issue/{key}/transitions", "POST", payload, fatal=False)
            except ApiError as e:
                failed += 1
                print(f"  {key:14} FAILED at {target!r}: {e}")
                if failed >= 3:
                    print("\n  three consecutive failures — stopping.")
                    return done, stuck, failed
                blocked = True
                break
            hops.append(target)
            cur = target

        if blocked:
            stuck += 1
            continue

        if not dry_run and body:
            try:
                api(f"issue/{key}/comment", "POST", {"body": body}, fatal=False)
            except ApiError as e:
                print(f"  {key:14} moved, but comment failed: {e}")

        failed = 0
        done += 1
        verb = "would go" if dry_run else "->"
        print(f"  {key:14} {verb} {' -> '.join(hops) if hops else 'already there'}")

    print(f"\n{done} moved, {stuck} stuck, {failed} failed")
    return done, stuck, failed


# ---------------------------------------------------------------- commands --

def cmd_render(args):
    rows = J.rows()
    scope = [r for r in rows if J.in_scope(r)[0]]
    J.ticketdir.mkdir(exist_ok=True)
    for f in J.ticketdir.glob("*.txt"):
        f.unlink()
    for r in scope:
        ident = str(r[J.id_column]).replace("/", "_")
        out = J.ticketdir / f"{ident}.txt"
        head = J.summary(r)
        body = J.description(r).rstrip("\n")
        out.write_text(f"{head}\n{'=' * len(head)}\n\n{body}\n")
    print(f"{len(scope)} issue(s) written to {J.ticketdir}")

    for row in rows:
        if not J.in_scope(row)[0]:
            continue
        gaps = J.check_templates(row)
        if gaps:
            print(f"\n!! templates use placeholders with no value: "
                  f"{', '.join(gaps)}")
            print(f"   available: {', '.join(sorted(J.context(row)))}")
        break

    skipped = [(r, J.in_scope(r)[1]) for r in rows if not J.in_scope(r)[0]]
    if skipped:
        print(f"\nexcluded {len(skipped)}:")
        for r, why in skipped:
            print(f"  {r[J.id_column]:16} {why}")


def cmd_probe(args):
    me = api("myself")
    print(f"authenticated as {me.get('displayName')} <{me.get('emailAddress')}>\n")

    if J.parent:
        parent = api(f"issue/{J.parent}?fields=summary,project,issuetype")
        print(f"parent  {J.parent}  [{parent['fields']['project']['key']}]")
        print(f"        {parent['fields']['summary']}")
    print(f"issues go in {J.project} as {J.issuetype}"
          + (f", linked as {J.linktype!r}" if J.parent else "") + "\n")

    if J.parent:
        links = [t["name"] for t in api("issueLinkType").get("issueLinkTypes", [])]
        if J.linktype in links:
            print(f"link type {J.linktype!r}: available")
        else:
            print(f"!! link type {J.linktype!r} does not exist here. Options: "
                  f"{', '.join(sorted(links)[:12])} ...")

    fields = createmeta()
    print(f"create screen: {len(fields)} field(s) readable\n")

    required = sorted(v.get("name") for v in fields.values()
                      if v.get("required") and not v.get("hasDefaultValue"))
    print(f"required: {', '.join(required) or 'none'}")

    resolved, missing = resolve_optional(fields)
    print(f"set by this job: {len(resolved)}/{len(J.fields) + len(J.date_fields)}")
    if missing:
        print(f"  not on this screen, will be skipped: {', '.join(missing)}")

    by_name = {v.get("name"): (k, v) for k, v in fields.items()}
    for name in J.date_fields:
        hit = by_name.get(name)
        if hit and hit[0] in resolved:
            kind = (hit[1].get("schema") or {}).get("type", "?")
            print(f"  {name}: {resolved[hit[0]]}   [{kind}]")

    if J.epic_name or J.epic_key:
        efid, ekey = epic_field_id(fields), find_epic()
        if efid:
            print(f"Epic Link: {efid}" + (f" -> {ekey}" if ekey
                  else f"  !! nothing matches {J.epic_name!r}; set epic_key"))
        else:
            print("Epic Link: not on this screen, will be skipped")

    gaps = J.check_templates(J.rows()[0])
    if gaps:
        print(f"\n!! templates reference {', '.join(gaps)}, which nothing provides")

    handled = set(J.fields) | set(J.date_fields) | {
        "Summary", "Issue Type", "Project", "Description", "Priority",
        "Component/s", "Components", "Epic Link", "Assignee",
    }
    unknown = [r for r in required if r not in handled]
    if unknown:
        print(f"\n!! required but not set by this job: {', '.join(unknown)}")
        print('   add them to "fields" in job.json or creates will be rejected')
    else:
        print("\nEverything required is covered — safe to try `create --limit 1`.")


def cmd_create(args):
    rows = J.rows()
    scope = [r for r in rows if J.in_scope(r)[0]]
    done = {r["id"] for r in J.created_rows()}
    todo = [r for r in scope if str(r[J.id_column]) not in done]

    print(f"{len(scope)} in scope, {len(done)} already created, {len(todo)} to do")
    if args.limit:
        todo = todo[:args.limit]
        print(f"limited to {len(todo)} this run")
    if not todo:
        return

    if args.dry_run:
        print("\n--dry-run: nothing will be created\n")
        for r in todo:
            print(f"  {J.summary(r)}")
        print(f"\neach would be created in {J.project}"
              + (f" and linked to {J.parent} as {J.linktype!r}" if J.parent else ""))
        return

    fields_meta = createmeta()
    optional, missing = resolve_optional(fields_meta)
    if missing:
        print(f"note: skipping fields not on this screen: {', '.join(missing)}")
    efid, ekey = epic_field_id(fields_meta), find_epic()

    assignee = ""
    if J.assignee and any((v.get("name") or "") == "Assignee"
                          for v in fields_meta.values()):
        assignee = (resolve_user(J.assignee) or {}).get("name", "")
    elif J.assignee:
        print("note: Assignee is not on the create screen — run `assign` after")

    print(f"\ncreating in {J.project}\n")
    made, failed, run = [], [], 0
    for r in todo:
        try:
            issue = api("issue", "POST",
                        {"fields": build_fields(r, optional, efid, ekey, assignee)},
                        fatal=False)
        except ApiError as e:
            failed.append((r, str(e)))
            run += 1
            print(f"  FAILED  {r[J.id_column]:16}\n          {e}")
            if run >= 3:
                print("\nThree consecutive failures — stopping. They all fail the\n"
                      "same way, so fix the field named above and re-run; nothing\n"
                      "already created will be created again.")
                break
            continue

        run = 0
        key = issue["key"]
        linked = "n/a"
        if J.parent:
            linked = "yes"
            try:
                api("issueLink", "POST", {
                    "type": {"name": J.linktype},
                    "inwardIssue": {"key": key},
                    "outwardIssue": {"key": J.parent},
                }, fatal=False)
            except ApiError as e:
                linked = "no"
                print(f"  {key} created but NOT linked to {J.parent}: {e}")

        J.record(r, key, linked)
        made.append((key, r))
        print(f"  {key:14} {r[J.id_column]:16} {r.get(J.name_column,'')}")

    if made:
        print(f"\n{len(made)} created. URLs:")
        for key, r in made:
            print(f"  {J.jira}/browse/{key}   {r.get(J.name_column,'')}")
        J.write_links()
        print(f"\n  {J.created}\n  {J.links}")
    if failed:
        print(f"\n{len(failed)} failed; re-running retries them without duplicating.")


def cmd_update(args):
    by_id = {str(r[J.id_column]): r for r in J.rows()}
    done = J.created_rows()
    if not done:
        print(f"nothing in {J.created}")
        return
    print(f"{len(done)} existing issue(s)\n")
    for r in done:
        row = by_id.get(r["id"])
        if not row:
            print(f"  {r['key']}: {r['id']} not in {J.rows_file.name}, skipped")
            continue
        if args.dry_run:
            print(f"  would rewrite {r['key']}  {r['id']}")
            continue
        try:
            api(f"issue/{r['key']}", "PUT",
                {"fields": {"summary": J.summary(row),
                            "description": J.description(row)}}, fatal=False)
            print(f"  {r['key']:14} rewritten   {J.jira}/browse/{r['key']}")
        except ApiError as e:
            print(f"  {r['key']:14} FAILED: {e}")


def cmd_assign(args):
    rows = J.created_rows()
    if not rows:
        print(f"nothing in {J.created}")
        return
    if args.limit:
        rows = rows[:args.limit]
    u = resolve_user(args.to)
    print(f"assignee: {u['displayName']} <{u.get('emailAddress')}>  ({u['name']})")
    print(f"{len(rows)} issue(s)\n")

    ok = failed = 0
    for r in rows:
        if args.dry_run:
            print(f"  {r['key']:14} would be assigned")
            ok += 1
            continue
        try:
            api(f"issue/{r['key']}/assignee", "PUT", {"name": u["name"]},
                fatal=False)
            ok += 1
            print(f"  {r['key']:14} assigned")
        except ApiError as e:
            failed += 1
            print(f"  {r['key']:14} FAILED: {e}")
            if failed >= 3:
                print("\n  three consecutive failures — stopping.")
                return
    print(f"\n{ok} assigned, {failed} failed")


def cmd_status(args):
    rows = J.created_rows()
    if not rows:
        print(f"nothing in {J.created}")
        return
    by_status = {}
    for r in rows:
        st = api(f"issue/{r['key']}?fields=status")["fields"]["status"]["name"]
        by_status.setdefault(st, []).append(r["key"])

    print("across all issues:")
    for st, keys in sorted(by_status.items(), key=lambda kv: -len(kv[1])):
        print(f"  {len(keys):3}  {st}")
    print()

    # One sample per distinct status — sampling only the first issue hides the
    # workflow for every other status the batch is spread across.
    for st, keys in sorted(by_status.items(), key=lambda kv: -len(kv[1])):
        trs = transitions_for(keys[0])
        print(f"from {st!r}  ({len(keys)} issue(s), e.g. {keys[0]}):")
        if not trs:
            print("  nothing available to you from here")
        for tr in trs:
            to = (tr.get("to") or {}).get("name", "?")
            req = [f.get("name") for f in (tr.get("fields") or {}).values()
                   if f.get("required")]
            line = f"  --to {to!r}".ljust(44) + f"via {tr.get('name')!r}"
            if req:
                line += f"   REQUIRES: {', '.join(req)}"
            print(line)
        print()


def cmd_review(args):
    rows = J.created_rows()
    if not rows:
        print(f"nothing in {J.created}")
        return
    if args.limit:
        rows = rows[:args.limit]

    mention = ""
    if args.reviewer and not args.no_comment:
        u = resolve_user(args.reviewer)
        mention = f"[~{u['name']}]"
        print(f"reviewer: {u['displayName']} <{u.get('emailAddress')}>  ({mention})")

    body = f"{mention} {args.comment}" if mention else ""
    path = list(args.via or []) + [args.to]
    print(f"moving {len(rows)} issue(s) via {' -> '.join(path)}"
          + (" and commenting" if body else "") + "\n")
    walk(rows, path, args.field, body, args.dry_run, "review")


def same_user(entry, user):
    for k in ("name", "key", "emailAddress"):
        a, b = (entry.get(k) or "").lower(), (user.get(k) or "").lower()
        if a and b and a == b:
            return True
    return False


def cmd_participants(args):
    rows = J.created_rows()
    if not rows:
        print(f"nothing in {J.created}")
        return
    if args.limit:
        rows = rows[:args.limit]

    user = resolve_user(args.remove)
    fid, spec = field_by_name(args.field_name, rows[0]["key"])
    if not fid:
        sys.exit(f"{args.field_name!r} is not on the edit screen for "
                 f"{rows[0]['key']} — check the exact field name")

    atomic = "remove" in (spec.get("operations") or [])
    print(f"removing {user['displayName']} ({user['name']}) from "
          f"{args.field_name!r} [{fid}] on {len(rows)} issue(s)")
    print(f"using {'remove' if atomic else 'read-modify-set'}\n")

    hit = clean = failed = 0
    for r in rows:
        key = r["key"]
        cur = (api(f"issue/{key}?fields={fid}")["fields"].get(fid)) or []
        if not any(same_user(e, user) for e in cur):
            clean += 1
            continue
        if args.dry_run:
            hit += 1
            print(f"  {key:14} would be removed ({len(cur)} participant(s) now)")
            continue
        if atomic:
            payload = {"update": {fid: [{"remove": {"name": user["name"]}}]}}
        else:
            keep = [{"name": e["name"]} for e in cur if not same_user(e, user)]
            payload = {"fields": {fid: keep}}
        try:
            api(f"issue/{key}", "PUT", payload, fatal=False)
            hit += 1
            print(f"  {key:14} removed")
        except ApiError as e:
            failed += 1
            print(f"  {key:14} FAILED: {e}")
            if failed >= 3:
                print("\n  three consecutive failures — stopping.")
                return

    verb = "would be removed from" if args.dry_run else "removed from"
    print(f"\n{verb} {hit} issue(s); {clean} did not have them"
          + (f"; {failed} failed" if failed else ""))


def _show_split(action):
    keep, drop = J.split_by_keep()
    print(f"{len(keep) + len(drop)} issue(s): keeping {len(keep)}, "
          f"{action} {len(drop)}\n")
    for r in drop:
        print(f"  {r['key']:14} {r['id']:16} {r.get('name','')}")
    return keep, drop


def cmd_cancel(args):
    keep, drop = _show_split("cancelling")
    if not drop:
        return
    if not args.yes and not args.dry_run:
        print(f"\nNothing was changed. Re-run with --dry-run to rehearse, or "
              f"--yes to move all {len(drop)} to {args.to!r}.")
        return
    path = list(args.via or []) + [args.to]
    print(f"\nmoving via {' -> '.join(path)}\n")
    walk(drop, path, args.field, args.comment, args.dry_run, "cancel")


def cmd_archive(args):
    keep, drop = _show_split("archiving")
    if not drop:
        return
    if not args.yes:
        print(f"\nNothing was changed. Re-run with --yes to archive all "
              f"{len(drop)}.\nArchived issues are hidden from search but can be "
              f"restored by an admin.")
        return

    keys = [r["key"] for r in drop]
    done, failed = [], []
    # Suppressing watcher emails needs admin rights, so it is opt-in — asking for
    # it without them turns a working call into a rejected one.
    suffix = "?notifyUsers=false" if args.no_notify else ""

    # Bulk archive is POST /issue/archive with a list of keys; the single-issue
    # form is PUT /issue/{key}/archive. Older builds may have neither.
    if not args.one_by_one:
        try:
            res = api(f"issue/archive{suffix}", "POST", keys, fatal=False)
            print(f"\nbulk archive accepted for {len(keys)} issue(s)")
            if isinstance(res, dict):
                if res.get("numberOfIssuesUpdated") is not None:
                    print(f"  updated: {res['numberOfIssuesUpdated']}")
                if res.get("errors"):
                    print(f"  errors: {json.dumps(res['errors'])[:400]}")
            J.rewrite_created(keep)
            print(f"\n{J.created.name} now lists the {len(keep)} you kept")
            return
        except ApiError as e:
            print(f"\nbulk archive did not work ({e.status}), trying one at a "
                  f"time\n")

    for key in keys:
        try:
            api(f"issue/{key}/archive{suffix}", "PUT", fatal=False)
            done.append(key)
            print(f"  {key:14} archived")
        except ApiError as e:
            failed.append(key)
            print(f"  {key:14} FAILED: {e}")
            if len(failed) >= 3 and not done:
                print("\n  three consecutive failures — stopping.\n"
                      "  Issue archiving is a Data Center feature and normally "
                      "needs Jira admin rights.\n  If this is a 403, use "
                      "`cancel` instead.")
                return

    survivors = keep + [r for r in drop if r["key"] not in set(done)]
    J.rewrite_created(survivors)
    print(f"\n{len(done)} archived, {len(failed)} failed. "
          f"{len(survivors)} left in {J.created.name}")


def cmd_prune(args):
    keep, drop = _show_split("deleting")
    if not drop:
        return
    if args.confirm != "DELETE":
        print("\nNothing was deleted. Jira issue deletion cannot be undone.")
        print("If the list above is right, re-run with:  prune --confirm DELETE")
        return

    print()
    gone, failed = [], 0
    for r in drop:
        try:
            api(f"issue/{r['key']}?deleteSubtasks=true", "DELETE", fatal=False)
            gone.append(r["key"])
            print(f"  {r['key']:14} deleted")
        except ApiError as e:
            failed += 1
            print(f"  {r['key']:14} FAILED: {e}")
            if failed >= 3:
                print("\n  three consecutive failures — stopping.")
                break

    survivors = keep + [r for r in drop if r["key"] not in set(gone)]
    J.rewrite_created(survivors)
    print(f"\n{len(gone)} deleted, {failed} failed. "
          f"{len(survivors)} left in {J.created.name}")


def cmd_perms(args):
    me = api("myself")
    print(f"{me.get('displayName')} <{me.get('emailAddress')}> on {J.project}\n")
    want = ["DELETE_ISSUES", "EDIT_ISSUES", "TRANSITION_ISSUES", "ASSIGN_ISSUE",
            "RESOLVE_ISSUES", "CLOSE_ISSUES", "PROJECT_ADMIN",
            "ADMINISTER_PROJECTS"]
    q = urllib.parse.urlencode({"projectKey": J.project})
    perms = (api(f"mypermissions?{q}", fatal=False) or {}).get("permissions", {})
    seen = set()
    for k in want:
        p = perms.get(k)
        if not p or p.get("name") in seen:
            continue
        seen.add(p.get("name"))
        print(f"  {'yes' if p.get('havePermission') else 'NO '}  {p.get('name')}")

    print("\nNote: this is the project-level answer. A workflow property or "
          "issue security\nscheme can still refuse the operation — the API "
          "response is the authority.")

    if perms.get("DELETE_ISSUES", {}).get("havePermission"):
        print("\nDelete looks permitted. Try:  prune --confirm DELETE")
        return
    try:
        roles = api(f"project/{J.project}/role", fatal=False) or {}
    except ApiError as e:
        print(f"\ncannot read project roles: {e}")
        return
    print("\nProject roles that could grant it:\n")
    for name, url in sorted(roles.items()):
        if not any(w in name.lower() for w in ("admin", "lead", "manager")):
            continue
        try:
            detail = api(url.split("/rest/api/2/", 1)[-1], fatal=False) or {}
        except ApiError:
            continue
        for a in (detail.get("actors") or []):
            print(f"  {name}: {a.get('displayName')}")


def cmd_jql(args):
    keep, drop = J.split_by_keep()
    for label, rows in (("KEEP", keep), ("DROP", drop)):
        keys = ", ".join(r["key"] for r in rows)
        print(f"{label} ({len(rows)} issues):\n\n  key in ({keys})\n")


# -------------------------------------------------------------------- main --

def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-j", "--job", default=os.environ.get("JIRA_JOB", "."),
                    help="job directory containing job.json (default: %(default)s)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("render", help="write issue text to disk, no network")
    sub.add_parser("probe", help="check auth, link types and field ids")

    c = sub.add_parser("create", help="create the issues and link them")
    c.add_argument("--dry-run", action="store_true")
    c.add_argument("--limit", type=int, help="create at most N this run")

    u = sub.add_parser("update", help="rewrite summary/description on existing")
    u.add_argument("--dry-run", action="store_true")

    a = sub.add_parser("assign", help="set the assignee")
    a.add_argument("--to", default="me", help="'me', username, or display name")
    a.add_argument("--dry-run", action="store_true")
    a.add_argument("--limit", type=int)

    sub.add_parser("status", help="current status and available transitions")

    rv = sub.add_parser("review", help="transition and @-mention someone")
    rv.add_argument("--to", default="Awaiting Review Decision")
    rv.add_argument("--via", action="append", metavar="STATUS")
    rv.add_argument("--field", action="append", metavar="NAME=VALUE")
    rv.add_argument("--reviewer", default="")
    rv.add_argument("--comment", default="please review this change.")
    rv.add_argument("--no-comment", action="store_true")
    rv.add_argument("--dry-run", action="store_true")
    rv.add_argument("--limit", type=int)

    p = sub.add_parser("participants", help="remove someone from a user field")
    p.add_argument("--remove", required=True)
    p.add_argument("--field-name", default="Request participants")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--limit", type=int)

    cn = sub.add_parser("cancel", help="transition out-of-scope issues")
    cn.add_argument("--to", default="Cancelled")
    cn.add_argument("--via", action="append", metavar="STATUS")
    cn.add_argument("--field", action="append", metavar="NAME=VALUE")
    cn.add_argument("--comment", default="Out of scope for this round.")
    cn.add_argument("--dry-run", action="store_true")
    cn.add_argument("--yes", action="store_true")

    ar = sub.add_parser("archive", help="archive out-of-scope issues")
    ar.add_argument("--one-by-one", action="store_true")
    ar.add_argument("--no-notify", action="store_true",
                    help="suppress watcher emails (needs admin rights)")
    ar.add_argument("--yes", action="store_true")

    pr = sub.add_parser("prune", help="delete out-of-scope issues")
    pr.add_argument("--confirm", default="",
                    help="must be the literal word DELETE")

    sub.add_parser("perms", help="what this account may do in the project")
    sub.add_parser("jql", help="JQL for the keep/drop sets")

    args = ap.parse_args()

    global J
    J = Job(args.job)

    {"render": cmd_render, "probe": cmd_probe, "create": cmd_create,
     "update": cmd_update, "assign": cmd_assign, "status": cmd_status,
     "review": cmd_review, "participants": cmd_participants,
     "cancel": cmd_cancel, "archive": cmd_archive, "prune": cmd_prune,
     "perms": cmd_perms, "jql": cmd_jql}[args.cmd](args)


if __name__ == "__main__":
    main()
