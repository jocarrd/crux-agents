# The standard

This document defines how documentation and agent work are organized in any
project. It lives in `crux` — the kernel — and is the **only** canonical
source. Projects do not invent variants: they consume this one.

To bootstrap a new project: `/crux-init <project>`.

---

## TLDR — what an agent needs to know

1. **Three layers**: kernel (`crux`), project (`<project>-docs`), repo (generated pointers).
2. **Layout**: sibling repos inside one folder per project, and one of them is `<project>-docs/`. The root that contains the projects is set by each machine, not by the standard.
3. **Repo-specific docs** live in `<project>-docs/repos/<repo>/`. Never in `<repo>/docs/`.
4. **Cross-cutting docs** live in `<project>-docs/{architecture,conventions,operations}/` (universal) or `<project>-docs/topics/<topic>/` (project domain).
5. **`crux.json`** in every docs repo declares version, profile and repos. Nothing is hardcoded in scripts.
6. **Pointers in each code repo**: `AGENTS.md` (canonical) and `CLAUDE.md` (symlink or `@-import`). Short, generated, never edited by hand.
7. **Sync discipline**: when code that affects a doc changes, the doc is updated in the same turn.
8. **Auto-memory**: `project` and `reference` go to git (`<project>-docs/`). Only `user` and `feedback` stay local.
9. **Cross-repo ADRs** → `decisions/index.md`. **Single-repo** → `repos/<repo>/decisions.md`. Seven statuses and no more.
10. **Runbooks**: what is in `operations/` is executed, not read. Symptom, confirm, act, verify, escalate — and it is written in the heat of the moment.
11. **Markdown links** only to files inside the docs repo itself. References to code in sibling repos go in backticks, unlinked.
12. **Skills**: cross-cutting ones live in the kernel; project ones in `<project>-docs/.claude/skills/project/`. The boundary is decided by the test in the "Skill promotion" section.
13. **Session close**: `/end-session` promotes what should survive, checks for drift and commits.

---

## Why it exists

A developer working on multiple projects, several repos per project, several
machines and many sessions with different agents. Without explicit discipline
information gets lost: it stays in someone's head, in a closed conversation, in
a local memory that does not survive a change of machine, or in a commit body
nobody reads again.

The standard has one goal: **that project knowledge lives in git, organized,
accessible to humans and to any agent, and survives every change of machine,
session or tool.**

---

## The three layers

| Layer | What it contains | Where it lives | Who edits it |
| ----- | ---------------- | -------------- | ------------ |
| **Kernel** | The standard, the cross-cutting skills, the templates, the tooling | `crux` | Once, for all projects |
| **Project** | The project's documentation and its own skills | `<project>-docs/` | Per project |
| **Repo** | Context pointers | Each code repo | Generated; not edited |

The rule behind the split: **if something changes when you switch projects, it
does not belong to the kernel.**

---

## The contract: `crux.json`

Every docs repo declares its relationship with the kernel in a `crux.json` at
the root:

```json
{
  "crux": "0.1.0",
  "project": "example-project",
  "profile": "multi-repo",
  "language": "es",
  "branch": "main",
  "repos": ["web", "api", "cms"],
  "sections": ["architecture", "conventions", "operations", "topics"]
}
```

| Field | Meaning |
| ----- | ------- |
| `crux` | Kernel version this project was materialized with |
| `language` | Language of the documentation and of the skill descriptions |
| `commit` | `{"language": "es"}`: language of commits and change proposals. English if not declared |
| `branch` | The project's main branch. `main` by default; it is declared because the hook that protects it and the workspaces read it from here |
| `remote` | Where the project's repos are cloned from |
| `project` | Project name, same as the parent folder |
| `profile` | Applied profile (see next section) |
| `repos` | The project's code repos, siblings of the docs repo |
| `archived` | Repos out of production but kept: `{"<repo>": {"since": "YYYY-MM-DD", "reason": "…"}}`. They leave `repos`, so nothing treats them as active; `crux archive` and `crux unarchive` move them. The contract is what counts, whatever the git provider allows |
| `sections` | Active optional folders |
| `quality` | How tests are run here (optional, see below) |
| `conventions` | Mechanically checkable style rules (optional, see below) |
| `mcp` | MCP servers the project declares (optional, see below) |

No kernel script hardcodes project names or repo lists: everything comes from
here. If the file is missing, the project has not been adopted and `crux doctor`
reports it as the first error.

### The remote

The kernel knows nothing about providers. Each project declares how its repos'
URLs are composed:

```json
"remote": {
  "url": "git@github.com:your-user/{repo}.git",
  "repos": {
    "codigo-del-cliente": "https://otro-host.com/su-org/codigo-del-cliente.git"
  }
}
```

`url` is a **template** with `{repo}`. It is the primary format because it is
the only one that covers remotes that do not follow the `owner/repo` shape. For
the common case there is an equivalent shortcut: `host`, `owner` and
`protocol`.

`repos` allows a **per-repo override**, and it is not a rare case: a project
can have its documentation on your remote and its code on someone else's. It is
exactly what happens with the `client-repo` profile.

`visibility` declares whether the docs repo must be private or public. It
matters because **the kernel can only enforce visibility where there is an API
to create it**: on other providers a person creates the repo, and a public docs
repo with internal documentation inside is an incident, not a configuration
slip. That is why it is declared and `crux doctor` checks it where it can.

`crux adopt` infers it from the `origin` of whatever is already cloned, so it
does not have to be written by hand. `crux doctor` warns if what is declared
stops matching reality, which is the drift that makes cloning fail on the next
machine.

### The tests

```json
"quality": {
  "tests": "pnpm test",
  "testsFiltered": "pnpm test {filtro}"
}
```

It is optional and the quality gate consumes it. `testsFiltered` receives in
`{filtro}` the files or modules the diff touches, and it exists so that **the
first gate runs only what is affected**: there the only question is whether the
red was already there, and the full suite is the regression gate. Without this
field the gate still works, but it says where to filter instead of giving the
command.

The same block declares **what the gate runs**, with a per-repo override:

```json
"quality": {
  "gate": ["pnpm run typecheck", "pnpm test"],
  "repos": {
    "web": { "gate": ["pnpm run typecheck:web", "pnpm run build:web", "pnpm run qa:web"] }
  }
}
```

`crux ship gate` reads it, runs each command and records its result in the
receipt. Without it the gate was four invocations to remember one by one, and
the measurements say that what gets skipped is exactly what has to be
remembered: of 54 skills, 39 were unused in 90 days, and the cycle was invoked
zero times in 31 sessions until a hook brought it in by itself.

**The kernel does not know how a project is checked, and must not.** The
contract declares it, which is what makes this a line of configuration and not
a handful of scripts tied to one specific repo.

### Rigor

```json
"rigor": "light"
```

How much ceremony the project deserves: `light`, `normal` or `strict`.
Optional; without the field it is `normal`, and a repo **without `crux.json`**
is treated as `light`, because a project that has not been registered has not
yet been taken seriously.

| Rigor | Specialists | Merge without asking |
| ----- | ----------- | -------------------- |
| `light` | only on high risk | everything that is not high risk |
| `normal` | on medium or high risk | text changes only |
| `strict` | on medium or high risk, no size shortcut | never |

Within each level the diff rules: a dependency, the session or a migration are
high risk in a `light` project too. In a client repo (`client-repo`) merging is
always decided by a person, whatever the rigor. `crux doctor` rejects any other
value.

### Deployment

```json
"deploy": {
  "url": "https://<domain>",
  "paths": ["/", "/<important-path>"]
}
```

Optional. `/deploy-watch` consumes it to check, after merging, that the new
version has arrived and that those paths respond. With several deployable repos
there is one per repo in `deploy.repos.<repo>`. `paths` are the few routes that
are noticed if they fail, not the sitemap.

### Production signals

```json
"observability": {
  "sources": [
    { "name": "app", "command": "ssh <host> docker logs --since {since} <container>" }
  ]
}
```

Optional. `/prod-signals` consumes it: each source is a **read-only command**
that runs without confirmation, with `{since}` replaced by the requested
window. Nothing that writes, restarts or deletes, and no credentials: those
live in the machine's configuration, not in a file that is in git.

### Checkable conventions

```json
"conventions": {
  "checks": [
    { "name": "types inside a constants file",
      "files": "*.consts.ts",
      "forbid": "^\\+\\s*(export )?(interface|type) [A-Z]" }
  ]
}
```

It is optional and the conventions gate consumes it. Each entry says that in
the files matching `files`, no added line may match `forbid`.

It is declared here and not in the kernel because **each project writes
differently**, and a kernel that imposed one project's style would make noise
in all the others. Signals that hold in any language —a repeated literal, a
catalog that already exists— go in the gate and are not declared.

A declared rule is not applied if the repo has not a single file matching its
`files`: the convention is written but that repo does not use it yet, and there
is nothing to demand. And a `crux.json` that cannot be read **stops the gate**,
it does not leave it at zero rules.

### MCP servers

```json
"mcp": {
  "referencias": {
    "transport": "http",
    "url": "https://ejemplo.dev/api/mcp",
    "repos": "docs"
  },
  "engine": {
    "transport": "stdio",
    "command": "node",
    "args": ["../engine/mcp/server.mjs"],
    "env": { "ENGINE_TOKEN": "${ENGINE_TOKEN}" },
    "repos": "all"
  }
}
```

It is optional. It declares the MCP servers this project wants available, and
`crux mcp install` writes them as `.mcp.json` in the relevant repos.

It is declared in the contract **because an MCP is a capability of the project,
not of the machine**: the one needed in one project gets in the way in another.
And it goes in git for the same reason as the context pointers — you clone the
project on another machine and the configuration comes with it, which is
exactly what is lost when it is added by hand in the agent's local
configuration.

| Field | When | What it is |
| ----- | ---- | ---------- |
| `transport` | always | `stdio` starts a process on this machine; `http` and `sse` talk to a URL |
| `url` | http, sse | The endpoint |
| `command`, `args` | stdio | Which process to start. With a relative path, so it works on any machine |
| `env` | stdio | Process variables |
| `headers` | http, sse | Headers, usually for authentication |
| `timeout` | optional | Milliseconds |
| `repos` | optional | Code repos that also receive the file: `all` or a list. Defaults to `docs`, which is only the docs repo |

The docs repo always receives the file, and `repos` says which code repos it is
also copied to. That is what lets `doctor` know where a `.mcp.json` *should*
exist and warn when it is missing —the case of a freshly cloned machine—
instead of passing what it has not looked at.

It is decided per server: a code repo's file holds only the servers that name
it. A declared server found in a repo it is not declared for is reported by
`doctor`, and `crux mcp install` takes it back; a server nobody declares was
put there by hand and is left alone.

**Credentials are referenced, not written**: `${VARIABLE}`. The `.mcp.json` is
committed, and `doctor` gives an error —not a warning— if it finds a literal in
an authorization header or a known credential fingerprint. `url`, `command`,
`args`, `headers` and `env` are checked: a password inside the URL itself is as
final as a token in a header. For the same reason, `check-secrets` looks at the
`.mcp.json` files as well as the documentation.

A server's name allows letters, digits, dot, hyphen and underscore, and nothing
else. It is not style: the name comes from a contract cloned from a remote, and
ends up concatenated into paths and expressions.

The profile outranks `repos`: where pointers are not written this
configuration is not written either, so in a client repo it stays in the docs
repo even if `all` is declared.

What the kernel does **not** do is decide for you. It ships no declared server,
because none is right for every project; and it does not manage switching on
and off, because the agent already does: a `.mcp.json` asks for approval the
first time and is disabled per project without touching the contract.

Before declaring one, look at **how much it returns**, not how many tools it
has. A server that is present and unused costs little; a single response from
it can take up more context than the whole working session.

---

## Profiles

A profile is a set of rules that change depending on **whose code it is**, not
on what the project does.

### `multi-repo` — own project with several repos

The default case. Several sibling code repos, all of them yours. Pointers are
generated in all of them and the full cycle applies.

### `client-repo` — the code belongs to the client

The docs repo is yours, but the code repo belongs to a client.

- **Nothing versioned is written outside the docs repo.** No pointers, no
  `AGENTS.md`, no standard folders in the client's repo. The only thing
  written is `CLAUDE.local.md`: a local pointer with `@../<docs>/CLAUDE.md`
  that `crux link` adds to git's `info/exclude`, so it does not show up in
  `git status` and cannot be committed. `crux workspace new` regenerates it in
  every worktree, because an unversioned file does not travel with
  `git worktree add`, and `crux doctor` gives an error if it is missing or not
  excluded. Without it, the agent loads nothing of ours when working on the
  code and discovering the docs repo depends on it remembering. If the
  client's repo **already had** its own versioned `AGENTS.md`, that is not an
  intrusion: it is respected and followed. `doctor` tells the client's file
  apart from our pointer, which carries the managed block.
- **Measurements are recorded, not diagnoses.** Nothing is declared a bug and
  no conclusion is drawn about what is wrong without the client's validation.
- **Every observation carries reproducible evidence**: file and line, command
  or query that demonstrates it. Without evidence it is not written.
- **Tell what was measured from what was inherited.** Earlier documentation
  describes the intent at the moment it was written, not the current state:
  verify before citing it.
- **Proposals do not show our scaffolding.** Neither the tooling, nor the
  branch names, nor the internal processes. See §8.

### Where a profile comes from

From three places, overlaid field by field, from general to specific:

| Layer | Where | What for |
| --- | --- | --- |
| Kernel | `profiles/<name>.json` | The ones crux ships |
| Machine | `~/.crux/profiles/<name>.json` | Your own, which survive the upgrade |
| Project | `<docs>/profile.json` | What changes only here |

A project can change one field without copying the rest, and a custom profile
does not require touching the kernel repo, which is replaced on every version.

### What a profile decides

| Field | Default | What it changes |
| --- | --- | --- |
| `pointers.write` | `true` | Whether pointers are written in the code repos |
| `pointers.local` | `false` | With `pointers.write` set to `false`, whether the local pointer `CLAUDE.local.md`, excluded from git, is written |
| `propose.forbid` | the tool's signature | What cannot appear in the body of a proposal, with its reason |
| `branch.pattern` | `ws/{{name}}` | What the branch a workspace opens is called |
| `commit.language` | `en` | The language the commit hook demands |
| `rules` | — | The working rules, in prose |

The first four are checked by the commands. The `rules` are not: `crux link`
writes them into the docs repo's `AGENTS.md`, in a managed block, and `doctor`
checks that they **are written**, not that they are followed. The difference
matters, and saying otherwise is the kind of green this standard pursues.

---

## Mandatory structure

A docs repo meets the standard if it has this:

```
<project>-docs/
├── README.md                 what the project is and which repos compose it
├── AGENTS.md                 canonical entry point for any agent
├── CLAUDE.md                 symlink → AGENTS.md
├── crux.json                 the contract with the kernel
├── decisions/
│   ├── README.md             how an ADR is written
│   └── index.md              cross-repo ADRs
└── repos/
    ├── README.md             mapping repo → folder
    └── <repo-name>/
        └── README.md         repo index
```

That is the floor. If you have this, the project is minimally documented.

And it lives **in git**, with a remote: that is the condition that makes
knowledge survive a change of machine, which is what all this exists for.
`doctor` checks it, and without a repo it cannot verify either that the
declared remote matches the real one.

## Optional structure

They appear **when the project needs them**, not before:

| Folder | When it appears |
| ------ | --------------- |
| `architecture/` | There is more than one repo and a cross-repo overview or diagrams are needed |
| `conventions/` | Cross-cutting code rules appear (style, testing, git) |
| `operations/` | There is infrastructure: servers, cloud, monitoring, deployments |
| `topics/` | Container for categories specific to the project's domain |
| `.claude/skills/project/` | Project-specific skills |
| `repos/<repo>/git-hooks/` | A repo needs git hooks of its own, beyond crux's: each file, named as git names the hook, runs after crux's on every machine. `crux hooks add <hook> --repo <repo>` creates it |

### `topics/` — what is specific to the domain

Cross-repo categories that are **not** universal but do cross several repos of
**this** project. The name is decided by each project:

```
example-project-docs/topics/editorial/ blog voice, SEO, visual identity
recipes-site-docs/topics/recipes/      formats, photography, culinary voice
saas-foo-docs/topics/pricing/          policy, discounts, plans
```

**Where a new doc goes, in three questions:**

1. Does it apply to any multi-repo project? → `architecture/`, `conventions/`, `operations/`
2. Only to this project, but it crosses several of its repos? → `topics/<topic>/`
3. Only to one repo? → `repos/<repo>/`

This way a loose folder never appears at the root that looks standard and is
not.

### When the project grows: from one repo to several

A project usually starts with a single repo, and then almost all its
documentation belongs to that repo: it goes in `repos/<repo>/`, and its
decisions in `repos/<repo>/decisions.md`. The cross-cutting folders stay empty
or nearly so, because there is nothing yet that crosses repos. That is
correct: they are not prepared "just in case".

When the second repo comes in, the cross-cutting stuff stops being hypothetical
and what already holds for several moves:

- A system overview, a shared convention or a common deployment moves up from
  `repos/<repo>/` to the cross-cutting folder it belongs in.
- A decision that now affects more than one repo moves from
  `repos/<repo>/decisions.md` to `decisions/index.md`, marking the old one as
  moved. Those that are still about one repo stay where they are.

Moving four documents the day the second repo arrives is cheaper than keeping
empty folders that suggest a split that does not exist yet.

### When a theme deserves its own docs repo

A docs repo exists for a **project**: code repos to coordinate, or a client.
A theme that is neither —a job search, a plan, notes about a market— does not
get one:

- If it is about the person, it goes to `about/` in their profile.
- If it is about a project, it goes to `topics/<theme>/` of that project's docs
  repo.
- When the theme gains code of its own or a client, it becomes a project, and
  only then gets its `-docs`.

One docs repo per theme multiplies the repos to sync and the contexts to load,
and almost all of them end up with three files.

---

## Hard conventions

They are not negotiable: they are what lets the system scale to several
projects without breaking.

### 1. Filesystem layout

- The project folder is named after the project, in kebab-case.
- The repos are direct siblings inside it.
- The docs repo is called `<project>-docs` and is one of those siblings.

What is mandatory is **the relationship between the folders**, not where they
are: it is what makes the relative reference always work. Each repo points to
`../<project>-docs/` and the agent resolves it without configuration.

**The root that contains the projects is set by each machine**, and by default
it is the directory where the kernel is cloned: if `crux` lives in
`/opt/dev/crux`, projects go in `/opt/dev`. It can be changed at install time
(`install.sh --projects-dir`), and it is written to `~/.crux/config` so that
the hooks and the commands that walk all projects read it too.

The kernel is the exception to the layout: `crux` is not a project and has no
siblings, it lives directly in the root.

### 2. Context pointers

Each code repo has two equivalent pointers, **generated by `crux link`**, never
written by hand:

- `AGENTS.md` — canonical, read by any agent.
- `CLAUDE.md` — for Claude Code, with the `@-import` to the docs repo.

```markdown
# <Repo> — <one line on what it does>

Full docs in `../<project>-docs/repos/<repo>/`.

Shortcuts:
- design-system.md  · tokens, patterns
- api.md            · endpoints, contracts

Cross-cutting rules and knowledge: @../<project>-docs/CLAUDE.md
```

No local documentation lives in the code repo.

### 3. Paths inside the docs

Paths are **textual references in backticks**, not navigable links. Mandatory
header in every doc:

```
> Paths relative to the root of `<repo-name>/`.
```

| Link type | Allowed |
| --------- | ------- |
| External URLs | yes |
| Files inside this docs repo | yes |
| Files in sibling repos | no |
| Code (`.ts`, `.tsx`, …) | no |

Links break when files move and, without a build to validate them, end up
lying. A path in backticks the agent resolves just the same and never breaks.
`crux doctor` (`crux __check doc-paths`) verifies the ones that remain.

### 4. ADRs

- **Cross-repo** → `decisions/index.md`. **Single-repo** → `repos/<repo>/decisions.md`.
- While there are fewer than 30 cross-repo ones, all in a single file. Past
  that, the registry opens with a table of contents —number, title, status—
  before splitting it into files: splitting forces rewriting every reference
  that cites it from other docs, and the table solves the real problem, which
  is finding a decision without reading them all.
- A single template for both levels, defined in `decisions/README.md`.
- Numbering is local to each ledger. To cite across ledgers, the path prefix:
  `decisions/ADR-013` or `repos/api/ADR-007`.
- **Seven statuses and no more**: `Open`, `Proposed`, `Accepted`, `Inherited`,
  `Superseded by <ref>`, `Amended by <ref>`, `Deprecated`. The field carries the
  status and its references, nothing else; the reason for the change lives in
  the ADR that causes it. The list came from what two projects were already
  writing by hand.
- A decision accepted knowing it has to be retired carries `Sunset` with the
  retirement condition. It is a field, not a status: it is accepted **and** it
  expires, and as a status one of the two would have to be given up.
- When superseding or amending, the old one is marked. It is not deleted.

### 5. Runbooks

What lives in `operations/` is not explanatory prose: it is what someone
executes with the system down. It has its own mandatory shape.

A **runbook** solves a specific, known problem. A **playbook** says how to
respond in general —what to look at first, when an incident is declared, who is
notified— and in a small project it is usually an index by symptom pointing to
the runbooks.

The five parts of a runbook, in this order:

| Part | What it contains |
| ---- | ---------------- |
| **Symptom** | What it looks like from outside, in the words of whoever suffers it |
| **Confirm** | How to tell it apart from what looks like it |
| **Act** | The commands, in order |
| **Verify** | How you know it is fixed |
| **Escalate** | When to stop trying and what to do then |

**Each step is a command, not a story.** The symptom is written the way the
reporter would say it, because it is what gets typed when searching for it; the
why goes in `architecture/` and the runbook links if needed. A runbook without
`Verify` lets you declare solved what is not, and without `Escalate` it turns
every incident into a race with no finish line.

**It carries the date it was last checked.** A runbook ages without warning:
ports change, server paths change, a third party's limits change. The mark does
not say it is still true, it says when it was known to be, and that is enough
to decide whether to trust it or verify first. `crux doctor` warns about those
older than six months.

**It is written in the heat of the moment**, right after resolving, which is the
only time the detail is known. Written cold it comes out as an explanation, not
a procedure. That is what `/runbook` is for.

A procedure that repeats across several projects is not a runbook: it is a
skill. The boundary is the same as always — if it still makes sense once the
proper nouns are covered, there is a pattern.

### 6. Agent auto-memory

Four types: `user`, `feedback`, `project`, `reference`.

- `user` and `feedback` are about the person, not the project: they go to the
  **person's profile** (see below), not to a docs repo.
- `project` and `reference` are **promoted to git** in the same turn:
  - Operations and gotchas → `operations/`
  - Pointers to external resources → `operations/` or the relevant README
  - Project state → `repos/<repo>/notes.md`

This **is verified**: `crux memory` lists the ones that are still only local,
and the hook installed by `crux hooks install` reminds you at session close.
The rule had been written down since day one and depended on someone invoking
the closing ritual, which was invoked in 2 of 46 sessions; meanwhile there was
project analysis that existed on only one machine. A rule that is not checked
is a recommendation.

What the kernel does not do is decide for you: it says what is missing and
which docs repo it goes to. Where it fits inside is a decision, and decisions
are not made by a hook.

**The agent's local memory is a draft.** It does not travel between machines
and each agent keeps it its own way, so nothing that is worth keeping stays
there: what is about a project goes to its docs repo, and what is about the
person goes to their profile.

#### The person's profile

A private repo next to the projects, `<projects root>/agent-profile` (another
name with `CRUX_PROFILE_REPO` in `~/.crux/config`), in neutral markdown:

| Path | What goes there |
| ---- | --------------- |
| `PROFILE.md` | The index, loaded in every session. Short: the detail is linked |
| `preferences/` | How the person wants the agents to work (`feedback`) |
| `about/` | Who they are, their plans, their accounts (`user`) |
| `machines/<hostname>.md` | What only holds on one computer; loaded only there |

Keys and passwords go nowhere in git; a project's knowledge, to its docs repo.

`crux profile init` creates it (private on the remote), `crux profile link`
loads it into each agent and `crux bootstrap` and `crux sync` bring it like any
other repo. `crux memory` lists the `user` and `feedback` memories still outside
it, the session-close hook warns about them and `crux sync --leave` counts them
as trapped. On a machine shared with another person, their folders are left
out with `CRUX_MEMORY_IGNORE` in `~/.crux/config` (comma-separated paths): their
memories are neither a leak nor go to this profile.

The profile's frontmatter can carry a `reminder:`, a line the agents receive on
every message (`profile-reminder` hook). The kernel brings no text of its own:
it is the person's setting, in their words. The case that justified it is the
language: a rule loaded at session start lost against everything the agent
reads in English while it works.

#### Searching

`crux memory search <text>` looks in the profile and every docs repo. Today it
is a plain search over the markdown, which is enough at this size. If an index
ever pays off (SQLite, vectors), it is built from the same files behind the
same command: the markdown in git stays the source of truth.

### 7. Code ↔ doc sync

When code that affects a doc is modified, **the doc is updated in the same
turn**. Not afterwards, not in another commit. If the change affects no doc
(internal rename, test, invisible refactor), nothing is touched.

Physical proximity between code and doc is no longer provided by the
filesystem: this discipline provides it.

#### What gets lost is not usually a file

The rule above only covers what leaves a trace in the diff, and that is not the
case that does damage. The case that does damage is a session that **measures
something, discovers a risk or resolves an open question**, commits the clean
code, and closes without any of it reaching the docs repo. No file gives the
loss away, so no diff-based check sees it.

Before closing a session you must **explicitly answer** what stays:

| What happened in the session | Where it lives |
| ---------------------------- | -------------- |
| Decision with discarded alternatives | `decisions/` (ADR) |
| Something measured that would be costly to repeat | `repos/<repo>/` or `operations/` |
| Infrastructure or deployment gotcha | `operations/` |
| New risk | `operations/open-risks.md` |
| Open question that has been resolved | where the question was |
| State of a repo that has changed | `repos/<repo>/notes.md` |

**"There is nothing to promote" is a valid answer**, but it has to be an
answer. The difference between deciding it is not needed and not remembering is
exactly what this section exists to eliminate.

#### How it is sustained

Not with goodwill. With three pieces, in order of hardness:

1. **The closing gate** (`adapters/<agent>/hooks/doc-sync.sh`) — when the
   session ends, if the project has moved, it **blocks the close once** and
   asks for the answer. It blocks at most once per session: a hook that always
   blocks ends up uninstalled, and then it watches nothing.
2. **`crux doctor`** — measures the drift between the last commit of each code
   repo and the last documentation commit. It is the auditable part: it lets
   you see after the fact whether the gate was being skipped.
3. **`/promote-to-docs` and `/end-session`** — the procedure to carry it out.

Doctor's measurement does not say **what** is missing from the documentation;
that cannot be known from git. It says that the code has been moving without
the documentation moving, which is the only objective signal available. The
judgment is still made by whoever closes: the gate only guarantees they are
asked.

### 8. Commits and change proposals

- Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`…)
- Subject in lowercase and imperative
- Body of at most 100 characters per line
- No `Co-Authored-By`
- No emojis, unless the file's voice justifies it

**Nothing that gets published carries the signature of the tool that wrote
it.** Neither the `Co-Authored-By` in the commit, nor a "generated with" line at
the bottom of a change proposal's description, nor the emoji that usually
accompanies it. The author is whoever signs the commit; which tool they used is
not repository information.

It applies to the proposal body just as to the commit: the change is described,
what was checked and what remains, and that is where it ends.

#### What a proposal's description carries

**What changes, what is added and why.** Then, what was checked and what is
pending. That is where it ends.

It is not a log. It does not tell the path its writer took, nor the detours,
nor which tool ran each step. The reviewer needs to judge the change, not
reconstruct the session.

**And the bar changes depending on whose repo it is:**

| | Own repo | Client repo |
| --- | --- | --- |
| The repo's own commands and scripts | Named | Named — they are theirs |
| Our tooling: `crux`, its commands, its skills, its marks | Named | **Does not appear** |
| Our branch names, workspaces or internal processes | Named | **Do not appear** |

In a client's repo, the reader does not know how we work internally and has no
reason to. Naming our scaffolding there adds no rigor: it adds noise and shows
machinery that is not the project's. A script that is in the client's
`package.json` is theirs and is cited naturally; ours stays out.

The distinction is not one of tone, it is one of ownership: the repo declares
its profile in `crux.json`, and `client-repo` is the one that activates it.

#### What is seen is approved by a person

A change that touches the interface is shown before proposing it: the before
and after on desktop, tablet and mobile (`/before-after`), and nothing is
pushed until the yes. `crux visual approve` records that approval against
HEAD's sha, and `workspace finish` adds it to the proposal —with images on a
separate branch that is never merged, or only as a note if the profile declares
`visual.publish: none`, which is what `client-repo` does—. If the approval is
for another commit, `finish` says so and does not publish it.

#### The gate is earned, not declared

`crux ship run -- <command>` runs the check and records its exit code;
`crux ship seal` closes the receipt against HEAD's sha and records the crux
version that sealed it. `workspace finish` reads it and **refuses to propose**
if there is no receipt, if it records not a single command, if any is red, if
the sha is not HEAD's or if it was sealed with a different crux version than
the one running. Before pushing it fetches the remote's main branch: if the
branch collides with it, it stops and says which files collide, because the
proposal would be born unable to integrate.

The version matters because the gate lives on the machine, not in the repo:
what it checks depends on the installed kernel. Without it, a sealed receipt
does not say under which rules it was earned. `seal` also warns if the project
pins in `crux.json` a version different from the one running; it is aligned
with `crux upgrade`.

It used to be a loose sha written by the agent itself after claiming it had
verified. That does not prove it verified: it proves it wrote a sha.

**The shortcut exists and is legitimate when a person asks for it**: `finish
--skip-gate`, and it says so out loud. What cannot happen is an agent taking it
on its own. That is the line throughout the standard —`--no-verify`,
`--force`, `--admin`, `--skip-gate`—: they are for obeying whoever decides, not
for the agent to save itself a step.

---

## Language

The standard does not impose a global language: it imposes **consistency within
a project**, declared in `crux.json` with `"language"`.

| What | Language |
| ---- | -------- |
| Skill descriptions | The project's |
| Skill body and documentation | The project's |
| Names of skills, commands, files and branches | English |
| Commits and descriptions of proposals | English, unless `crux.json` declares `commit.language` |
| Technical terms | Untranslated: `worktree`, `commit`, `hook`, `deploy` |

The commit part **is verified**: `crux hooks install` puts in a `commit-msg`
that rejects messages in Spanish, in client repos too, where it leaves the
commit format alone. This rule had been written down since day one
and the kernel's history was entirely in Spanish — a rule nobody checks is a
recommendation.

It is a net for carelessness, not a language detector: it requires two Spanish
function words, so a title with almost no prose slips past it and a place name
such as "Los Angeles" does not trigger it. `--no-verify` skips it when it is
genuinely needed.

**Descriptions are what decides whether a skill activates**, and they must
contain the words in which the problem shows up. If the work is requested in
one language and the description is in another, the skill exists but activates
worse exactly when it is needed. `crux doctor` warns about the mix.

Names are in English because they are identifiers, not prose: `write-tests`,
`ship`, `workspace`. And technical terms are not translated because translating
them creates ambiguity, not clarity.

**A project whose code or whose counterparts are in another language declares
it and is written entirely in that language.** It is a property of the project,
not a decision to be taken again in every file.

---

## Multi-agent

Knowledge is written **once, in neutral markdown**. What changes between agents
is only how it is loaded, and `install.sh` takes care of that.

| Piece | Claude Code | Codex |
| ----- | ----------- | ----- |
| Skill | symlink at `~/.claude/skills/<name>` | stub at `~/.codex/prompts/<name>.md` |
| Global context | `~/.claude/CLAUDE.md` | `~/.codex/AGENTS.md` |
| Person's profile | `@-import` of `PROFILE.md` in `~/.claude/CLAUDE.md` | copy of the index in `~/.codex/AGENTS.md`, regenerated by `crux sync` |
| Project context | `CLAUDE.md` (symlink) | `AGENTS.md` (canonical) |
| Repo pointer | `CLAUDE.md` with `@-import` | `AGENTS.md` with the path |

**Hard rule:** no kernel skill mentions tools specific to a particular agent.
The action to perform is described, not who runs it. It is what lets the same
file serve both.

**Practical consequence:** Claude discovers skills through the frontmatter
`description`; Codex does not interpret it. That is why each `SKILL.md`
repeats its "when to use" in the body, and the docs repo's `AGENTS.md` lists
the skills with their trigger.

---

## Skills

### Kernel or project

- **Kernel** — describes a way of working that survives a change of project:
  managing documentation, decisions, sessions, deployments without CI, visual
  verification.
- **Project** — interacts with concrete infrastructure: its servers, its cloud
  accounts, its product's data, its editorial voice.

### Size

A skill is loaded whole into the context every time it is used. `SKILL.md`
carries what the agent has to do (steps, commands, rules, gotchas) and does not
exceed **1,000 words**; the why, the history and long examples go in
`references/why.md`, which is only opened if needed. Before creating a
skill, check that there is not another that wins the same phrase; if there is,
extend that one. How one is written and tested: `/skill-creator`.

A skill is tested with known-answer scenarios in `tests/scenarios.md` and
`crux skill test`, which compares against the previous version: shortening
without testing loses nuances that cannot be seen by reading.

The same description verifier checks it, in the kernel (the suite) and in each
project (`crux doctor`). The kernel skills that already exceeded the cap are in
`skills/.oversized` and can only shrink.

### Skill promotion

To decide whether a project skill deserves to move up to the kernel:

> **Cover all the skill's proper nouns. If the procedure still makes sense and
> has value, there is a pattern inside.**

The procedure is promoted; a short adapter stays in `project/` with paths,
credentials and names. With two guards:

- **Two-occurrence rule.** It is promoted when two projects genuinely need it,
  not when it "might be useful someday". Admissible exception: demonstrated
  high value and almost no coupling.
- **The reverse path exists.** If a kernel skill starts accumulating
  per-project conditionals, it was not a pattern: it is demoted to `project/`.
- **The adapter does not retell the method.** It contributes paths, names and
  data, and names its project in the **description**, which is the only thing
  compared on activation. If it repeats the procedure, the two bid for the same
  phrase and outside its project the one that does not apply wins. Resembling
  each other is unavoidable —they talk about the same work—; what is demanded
  is that they **divide it up**, and it is verified with two phrases: the one
  carrying no proper nouns is won by the kernel procedure, and the one carrying
  them, by the adapter. If the first is lost, there is too much method in the
  description; if the second is lost, proper nouns are missing.

`/skill-audit` applies this test periodically and when creating a new skill.

### Kernel catalog

| Skill | What for |
| ----- | -------- |
| `crux-init`, `crux-doctor`, `add-repo-to-docs` | Managing the standard |
| `promote-to-docs`, `adr`, `runbook`, `explain-plan`, `end-session` | Deciding, operating and making knowledge survive |
| `repo-map` | Getting oriented in an unfamiliar or dormant repo |
| `read-document` | Reading a document the agent cannot open |
| `grill` | Interrogating the decision-maker before building anything |
| `flow` | **The full cycle and its order** — the default entry point |
| `workspace`, `ship`, `review-pr` | The pieces of the cycle: isolate, verify and review |
| `merge-conflicts` | Getting through a merge or rebase left half done |
| `deploy-watch`, `prod-signals` | After merging: watch production and read what it says |
| `write-tests`, `e2e`, `root-cause`, `eval-fixtures` | Quality and debugging |
| `bug-hunt` | Looking for the failures nobody has reported |
| `code-health` | Structural health of the whole and its trend |
| `visual-test`, `visual-diff`, `render-loop`, `device-loop`, `before-after` | Verification with the eyes; the last one, the decision-maker's, before pushing |
| `ui-behaviour` | That controls do something and can be reached by keyboard |
| `ui-tells` | That an interface does not look model-generated |
| `prose-check` | That a text, Spanish or English, does not read as model-generated |
| `x-posts` | Writing and planning posts for X that reach people |
| `motion-video` | Motion graphics videos rendered from code, with sound and a critique loop |
| `css-to-components` | Moving styles into components without changing the design |
| `auth-bypass-local`, `oauth-reauthorize`, `deploy-fallback`, `share-local`, `drive-browser` | Operations |
| `carry-env` | Taking to another machine what the repos do not carry |
| `wizard` | Guiding a person through the steps the agent cannot take |
| `teach` | Teaching something across several sessions, on the project's code |
| `skill-creator`, `skill-audit` | The framework itself |

### The development cycle

Five skills sustain day-to-day work, and they are used in this order:

**The order is declared by `/flow`**, which is what an agent reads first.
In short:

1. **`/workspace`** — before starting, if there will be parallel work on the
   same repo. It isolates files **and runtime**: without the latter, two
   simultaneous tasks silently corrupt each other's data.
2. **`/ship`** — before committing. A chain of gates where any one aborts:
   sanity, diff, correctness, simplification, regression, real validation only
   if the change touches an observable surface, documentation drift, commit.
3. **`/review-pr`** — with the proposal already open, from a context
   independent of whoever wrote the change. `/ship` asks whether what you did
   is ready; this one, whether what is being proposed is correct and complete.
   Whoever has just defended each decision is in no position to refute them. It
   classifies the risk and launches only the specialists the diff calls for.
4. **`/deploy-watch`** — after merging what deploys itself. Nothing is
   considered published until the new version is seen responding in production.
5. **`/end-session`** — before closing. What should survive the session is
   written to git, conformance is verified and it is committed.

### The task

Each workspace has a task, and each task **one record** in
`~/.crux/tasks/<project>/<task>.md`. It is working state, not knowledge: it
lives next to the workspace registry and **outside the code repos**, so it is
equally valid in a client's and in a task that touches several.

**It travels between machines** on the `crux/tasks` branch of the project's
docs repo —or of the repo itself, if it is a standalone one with no docs repo—.
That branch is a replica written by crux (`rs/src/task/sync.rs`) and never by the agent;
`main` does not see it, and the docs repo's working tree is not touched. It is
published in the background after each write to the record, and `crux sync`
brings it in on arrival and retries what is pending on leaving. If a task
changed on two machines, the most recent one is kept and the other is saved
alongside as `.conflicto-`. A project disables it with `"tasks": { "sync": false }`
in its contract. In a public GitHub repo it is not published unless
`"sync": true`, and if visibility cannot be checked, it is not published
either. See ADR-016.

When opening, resuming or returning to a session after hours, a hook shows the
open tasks **as a reminder**: the person decides whether to resume any, and if
they ask for something else, something else is done. `crux workspace resume
<task>` opens it on another machine from its remote branch, joining the record
that has already arrived.

| Moment | Written by | State |
| ------ | ---------- | ----- |
| Opening the workspace | `crux workspace new` (or `--task <task>` to join from another repo) | `open` |
| Plan approved | `crux task plan <file>` | `planned` |
| Working | `crux task add`, `done <Tn> "evidence"`, `next`, `note` | `in-progress` |
| Gate closed | `crux ship seal`, which dumps the receipt as evidence | `verified` |
| Proposal opened | `crux workspace finish`, which takes the description from there | `proposed` |
| Merged | `crux workspace merge --yes` | `merged` |
| Its last workspace closed | `crux workspace rm`, which archives it in `done/` if already merged and no step is left | `closed` |

**Waiting for another person is not a state of the cycle.** A task can be
merged and still pending a reply, so the wait is kept apart:
`crux task wait --on "<who>" --ask "<what>" [--ref "<where>"]` records it and
removes the clean workspaces and the branches that have nothing of their own
(or whose proposal was already merged); what has unpublished work stays and
this is said. The reminder and `crux status` show them in their own block, with
whom and since when, and suggest following up after 7 days
(`CRUX_WAIT_NUDGE_DAYS`). While it waits it is not archived.
`crux workspace resume` picks it up —with a new branch from the main one if its
own was removed— and it stops waiting; `crux task unwait` removes the wait
without opening a workspace. See ADR-017.

**A task only archives itself when its last workspace closes**, so one opened
with `crux task new` and then worked in a workspace with another name stays open.
`crux task list` and the reminder mark as `idle` the open tasks with no workspace
on this machine and untouched for 3 days (`CRUX_IDLE_TASK_DAYS`), and
`crux workspace new` lists them when it registers a new task, so the work joins
the right one with `--task`. `/end-session` reviews the tasks of the session.
Nothing archives them on its own: whether the work is done is the person's call.

Archived tasks do not appear in the lists (`crux task list --done` shows them)
and they expire: `crux workspace gc --yes` deletes those older than 180 days
(`CRUX_TASKS_RETENTION_DAYS`). What had to last has already gone out to the
proposal and the docs repo. An unfinished task is not archived when its
workspace closes; if it no longer continues, `crux task archive`. Nor is a
merged one that still has steps to do: one task can take several proposals, and
neither closing the workspace nor the sync's merged check archives it while a
step is open.

A task can be started without a workspace (`crux task new <project>/<task>
[--goal "<text>"]`), for work that is still being thought out. If the task was
archived, both that command and `crux workspace new --task` reopen it instead of
starting an empty record: back in progress, with its history, a note of the
reopening and a new creation date, so the other machine does not take it for
the archived one and delete it.

The record is written in the language of the repo's proposals —that of its
commits—, because the proposal's description is taken from it.

Writing it is up to whoever works, and nothing forces it. What the kernel does
do is warn at the only moment when it still can: `crux workspace finish` says
out loud if the task is being closed without a single step noted, before
pushing the branch. That is where the session that knew why what was measured
was measured and why what was discarded was discarded ends, and without steps
the task is left with the one-line goal. It warns and carries on, because there
are one-commit tasks that do not warrant more and that is decided by whoever
did it.

When resuming a workspace, the task hook brings its state and its next step.
What deserves to outlast the task —a decision with alternatives, a
measurement— is promoted to the docs repo on closing, like anything else from
the session. See ADR-012.

---

## Commands

| Command | Skill | What it does |
| ------- | ----- | ------------ |
| `crux init <project>` | `/crux-init` | Creates the docs repo from the templates |
| `crux clone <project>` | — | Brings a whole project onto a new machine |
| `crux setup` | — | Gets a machine ready step by step: account, remote, profile and projects |
| `crux bootstrap` | — | Gets a new machine ready: verifies, discovers the projects and brings them in |
| `crux install` | — | Lays out the kernel the binary carries and hooks it into the agents |
| `crux adopt` | — | Registers a docs repo that already exists |
| `crux add-repo <repo>` | `/add-repo-to-docs` | Registers a new repo in the project |
| `crux archive <repo> --reason "…"` | — | Marks a repo as archived: contract, docs notice, read-only on GitHub, local clone refuses to push |
| `crux unarchive <repo>` | — | Brings an archived repo back |
| `crux review` | `/review-pr` | Gathers the material for reviewing a proposal, with its risk |
| `crux checks [n]` | `/flow` | Waits for a proposal's CI and fetches the log of what fails |
| `crux merge <n>` | — | Merges a proposal, saying beforehand which one and from which repo |
| `crux link` | — | Generates and verifies the code repos' pointers |
| `crux workspace` | `/workspace` | Isolated workspaces for working in parallel |
| `crux task` | `/workspace` | The task record: steps with evidence, next step and state |
| `crux workspace adopt <path>` | `/workspace` | Registers a hand-made worktree, with its task |
| `crux ship` | `/ship` | The quality gate, with a receipt of what was run |
| `crux visual` | `/before-after` | The visual review a person approved, with receipt and a section in the proposal |
| `crux doctor` | `/crux-doctor` | Verifies conformance with the standard |
| `crux upgrade` | — | Re-materializes the kernel at the current version |
| `crux release <ver>` | — | Publishes a kernel version |
| `crux doctor --machine` | — | Verifies the machine's environment |
| `crux hooks install` | — | Hooks the standard into the cycle, session close and commit |
| `crux mcp` | — | The MCP servers the project declares, placed where the agent reads them |
| `crux stg` | — | Publishes a built folder to a key-protected staging |
| `crux usage` | — | Measures which skills are actually used |
| `crux prose check <file>` | `/prose-check` | Counts the markers of a model-generated text, in English or Spanish |
| `crux skill test <skill>` | — | Tests a skill with its scenarios; `--against <ref>` flags regressions |
| `crux memory [--check]` | `search <text>` | Agent memories that should be in git; searches the profile and the docs repos |
| `crux profile` | `init`, `link`, `clone` | The person's profile: a repo of its own that every agent loads |
| `crux status` | `--check` | Projects, workspaces and unpublished work |
| `crux sync` | `--leave`, `--hook` | On arrival, advances what is behind and brings in what is new without deciding anything; on leaving, fails if something stays only on the machine |

---

## Anti-patterns

- **Inventing thematic folders at the root.** If it belongs to a repo, it goes
  in `repos/<repo>/`. If it is universally cross-cutting, in the three
  canonical folders. If it is domain-specific, under `topics/`.
- **Keeping project information in local auto-memory.** It is lost when
  changing machines.
- **Relying on commit bodies as a substitute for documentation.** Commits
  explain changes; documentation explains stable state.
- **Multiple long `CLAUDE.md` files.** Only the docs repo's has content; those
  of the code repos are generated pointers.
- **Copying the kernel by hand into a project.** That is what `crux upgrade`
  is for. Manual copying is the origin of drift.
- **Assuming discipline holds without an agent.** That is why `crux doctor`
  exists: the standard is verified, not trusted.

---

## Versioning

`VERSION` follows semver:

- **patch** — wording corrections, script fixes with no change of contract
- **minor** — new templates, skills or checks; projects remain valid
- **major** — the mandatory structure or the `crux.json` format changes

When the standard evolves it is changed **here first**, and projects align with
`crux upgrade` when the time comes. A project is not allowed to invent its own
variant.
