# The crux guide, from start to finish

This guide explains the whole system, from the simplest to the deepest.
You do not need to read it all: each level stands on its own.

It serves a person and an agent equally. If you are an agent and are going to
**work on this repo** —add a skill, touch a command—, read `AGENTS.md` first:
it holds the five rules that hold the kernel up and that tests keep watch over.

- **Level 1** — what it is and what problem it solves
- **Level 2** — installing it and the day to day
- **Level 3** — creating the documentation of a new project
- **Level 4** — adopting a project that already exists
- **Level 5** — how it works inside
- **Level 6** — the development cycle
- **Level 7** — extending it
- **Level 8** — maintaining it

---

## Level 1 — What it is and what problem it solves

### The problem

One person, several projects, several repos per project, several machines and
many sessions with different agents. Without explicit discipline, knowledge
evaporates: it stays in someone's head, in a closed conversation, in a local
memory that does not survive a laptop change, or in a commit nobody rereads.

And there is a second, subtler problem: **each project tends to invent its own
way of organizing itself**. By the second project you no longer know where
anything is, and neither does the agent.

### The solution in one sentence

A repo called `crux` that contains **the standard, the procedures and the
tools**, and from which each project's documentation repos are built and
maintained.

### The three layers

```
        crux  (kernel: rules, templates, skills, tooling)
          ↑            ↑
    acme-docs    client-docs        ← projects, consumers
          ↑            ↑
     code repos    client repo        ← receive generated pointers
```

The arrows point **up and only up**. The kernel does not know which projects
exist: a test fails if it ever mentions one.

| Layer | What it contains | Who edits it |
| ----- | ---------------- | ------------ |
| **Kernel** | Standard, cross-cutting skills, templates, commands | Once, for everyone |
| **Project** | The project's documentation and its own skills | Per project |
| **Repo** | Context pointers | Generated, not edited |

The rule behind the split: **if something changes when you change project, it
does not belong to the kernel**.

---

## Level 2 — Installing it and the day to day

### Installation, once per machine

```bash
git clone git@github.com:jocarrd/crux.git ~/Proyectos/crux
~/Proyectos/crux/install.sh --remote 'git@github.com:<your-user>/{repo}.git'
```

`--remote` is optional and sets this machine's usual remote, so you do not have
to repeat it in every new project. This does four things:

1. Records where the kernel lives and **what the projects root is** in
   `~/.crux/config`. By default the root is the directory where you cloned the
   kernel: if you put it in `/opt/dev/crux`, your projects go in `/opt/dev`.
   The installer says so out loud, and it is changed with `--projects-dir`.
2. Puts the `crux` command in `~/.local/bin`.
3. Links the skills for Claude Code and generates the prompts for Codex.
4. Writes the global Codex context to `~/.codex/AGENTS.md`.

It is idempotent: it can be run a thousand times. And it accepts `--dry-run` to
see what it would do without touching anything.

### The commands

| Command | What it does |
| ------- | ------------ |
| `crux init <project>` | Creates the documentation repo of a new project |
| `crux clone <project>` | Brings a whole project onto a new machine |
| `crux adopt` | Registers a documentation repo that already exists |
| `crux add-repo <repo>` | Adds a repo to the project |
| `crux link` | Generates and verifies the pointers of the code repos |
| `crux workspace` | Isolated spaces for working in parallel |
| `crux hooks` | Hooks the standard into the cycle, the session close and the commit |
| `crux usage` | Measures which skills are actually used |
| `crux doctor` | Verifies that the project meets the standard |
| `crux doctor --machine` | Verifies that the machine has what the skills need |
| `crux upgrade` | Aligns the project with the current kernel version |

They all work from any subdirectory of the project: they walk up the tree
looking for `crux.json`, just as git does with `.git`.

### The day to day, in five moments

**Before starting**, if you are going to launch several tasks in parallel on
the same repo: `/workspace`.

**Before committing**: `/ship`.

**If the change is visible, before pushing it**: `/before-after`. The before
and after go to whoever decides, and nothing goes out until their yes.

**With the proposal open**: `/review-pr`, from a context other than the one
that wrote the change.

**Before closing**: `/end-session`.

---

## Level 3 — Creating the documentation of a new project

### The command

```bash
crux init cocina-sencilla \
  --description "Home recipes, well explained." \
  --repos "web,api" \
  --profile multi-repo
```

Or, in conversation with the agent, `/crux-init`, which asks for whatever is
missing.

### What exactly happens, step by step

**1. It creates the project folder and the remote repo.**

```
~/Proyectos/cocina-sencilla/
└── cocina-sencilla-docs/     ← created on GitHub and cloned
```

The repo is always called `<project>-docs`. It is not a whim: half the
convention depends on that name being predictable.

**2. It materializes the structure from the templates.**

```
cocina-sencilla-docs/
├── README.md              what the project is and which repos make it up
├── AGENTS.md              the canonical index for any agent
├── CLAUDE.md              → symlink to AGENTS.md
├── crux.json              the contract with the kernel
├── .gitignore
├── decisions/
│   ├── README.md          how an ADR is written
│   └── index.md           the register of decisions that cross repos
├── repos/
│   ├── README.md          the repo → folder table
│   ├── web/README.md
│   └── api/README.md
└── .claude/skills/project/   empty, for the project's own skills
```

It comes from `templates/`, with the `{{PLACEHOLDERS}}` substituted. **It is
deterministic**: two runs produce the same tree, and a test checks it. This
used to be prose inside a skill that an agent reproduced by hand, and every
bootstrap came out a little different.

**3. It writes the contract.**

```json
{
  "crux": "0.1.0",
  "project": "cocina-sencilla",
  "profile": "multi-repo",
  "repos": ["web", "api"],
  "sections": []
}
```

**4. It makes the initial commit and pushes it.**

**5. It generates the pointers** of the code repos that are already on disk.

**6. It tells you what to do next.**

### What it does NOT create, and why

It does not create `architecture/`, `conventions/`, `operations/` or
`topics/`. Those folders **appear when the project needs them**. A scaffold
full of empty folders teaches people to ignore them; the minimum floor forces
every folder that exists to mean something.

### Where each document goes

Three questions, in this order:

1. Does it apply to **any** multi-repo project? → `architecture/`,
   `conventions/`, `operations/`
2. Only to this project, but it crosses several of its repos? → `topics/<topic>/`
3. Only to one repo? → `repos/<repo>/`

That way a loose folder never appears at the root that looks standard and is
not.

### Adding a repo afterwards

```bash
crux add-repo worker --description "Processes the image queue."
```

In one step: it creates `repos/worker/README.md`, declares it in `crux.json`,
adds its row to the index table and generates its pointers. This used to
involve hand-editing a list inside a script.

---

## Level 3b — Changing computers

Three commands:

```bash
git clone git@github.com:jocarrd/crux.git ~/Proyectos/crux
~/Proyectos/crux/install.sh --remote 'git@github.com:jocarrd/{repo}.git'
crux clone acme
```

`crux clone` brings the docs repo, **reads its contract** and clones the repos
it declares. Two things come from there and not from an assumption: the list of
repos —which in a hand-written guide goes stale as soon as you add one— and
**where each one is cloned from**.

After that, `crux doctor --machine` tells you what is missing on the machine:
tools, authentications, broken links. What comes out as a warning limits which
skills you can use; what comes out as an error breaks something.

Each project's credentials and secrets remain manual work, and live in its own
onboarding documentation.

## Level 4 — Adopting a project that already exists

If the project already has documentation, `crux init` is not for you: it is
`crux adopt`, which **rewrites nothing**.

```bash
cd ~/Proyectos/mi-proyecto/mi-proyecto-docs
crux adopt --profile multi-repo
```

What it does:

1. Deduces the project name from the folder name.
2. Detects the repos that already have a documentation folder.
3. Detects the active optional sections.
4. Writes the missing `crux.json`.
5. Warns about sibling folders on disk that are not yet declared.
6. Runs `crux doctor` to tell you what is left to align.

It is the entry door for projects that predate the kernel.

---

## Level 5 — How it works inside

### The contract: `crux.json`

It is the central piece. Before, the bootstrap script had this written inside:

```bash
REPOS=(Acme acme-engine acme-cms acme-radar demo-co ...)
```

A framework script knowing a project's repos by name. That is why it was not
reusable: for another project you had to edit it.

Now each project **declares itself** and the kernel only reads. It is the
`package.json` pattern: generic code, data in the manifest. And the `crux`
field plays the role of a lockfile — it answers "which version of the standard
was this materialized with?", a question that previously had no answer.

### The remote: the kernel knows nothing about providers

The contract declares **how the URLs** of the project's repos are composed:

```json
"remote": {
  "url": "git@github.com:jocarrd/{repo}.git",
  "repos": { "codigo-del-cliente": "https://otro-host.com/su-org/codigo.git" },
  "visibility": "private"
}
```

The template with `{repo}` is the primary format because it is the only one
that covers remotes that do not follow the `owner/repo` shape. The per-repo
override is not a rare case: **a project can have its documentation on your
remote and its code on someone else's**, which is exactly what happens with the
client profile.

`crux adopt` deduces it from the `origin` of whatever is already cloned, so it
is not written by hand. And `crux doctor` warns when what is declared stops
matching reality: that drift does not bother you on your machine and makes the
clone fail on the next one.

**Visibility matters for a concrete reason**: it can only be applied where
there is an API to create the repo. With the other providers a person creates
it, and a public docs repo with internal documentation inside is not a
configuration slip, it is an incident. That is why it is declared, `init` says
so out loud when it cannot apply it, and `doctor` checks the real one where it
can.

### The language

It is also a declared property, not a habit. The rule: descriptions and
documentation in the project's language, names and identifiers in English,
technical terms left untranslated.

It matters because **a skill's description decides whether it activates**, and
it must carry the words in which the problem shows up. If the work is requested
in one language and the description is in another, the skill exists but
activates worse exactly when it is needed.

### How the kernel finds itself

In cascade, three ways:

1. The `CRUX_HOME` variable, if set.
2. `~/.crux/config`, which the installer wrote.
3. Its own real path, resolved from the running script.

That is why it works the same invoked as `crux`, as `bash bin/doctor.sh`, or
from a test with `$HOME` redirected. Zero hand-written absolute paths.

### Profiles: policy as data, not as prose

This is the most important conceptual leap in the design.

The rules of a client project —do not touch their repo, demand evidence, do not
diagnose without validation— used to live as **paragraphs in a README**. An
agent reads them if it reads them, and no program can check them.

Now they are a file:

```json
{ "name": "client-repo", "pointers": { "write": false }, "rules": [...] }
```

And that `write: false` is consumed by two different programs:

- **`crux link`** reads it and **does not write** the pointers: the client's
  repo is left literally with zero files created.
- **`crux doctor`** reads it and **verifies that nobody wrote**: if an
  `AGENTS.md` appears in the foreign repo, it is an error with exit code 1.

Prevention and detection from the same piece of data. That is turning a norm
into a guarantee.

Current profiles: `multi-repo` (own code) and `client-repo` (someone else's
code).

### The adapters: one source, two agents

Hexagonal architecture, literally. The core is neutral markdown; the adapters
translate to each agent:

```
skills/<name>/SKILL.md            ← the ONLY source
        │
        ├─ adapters/claude/  → symlink in ~/.claude/skills/<name>
        └─ adapters/codex/   → stub in ~/.codex/prompts/<name>.md
```

The key: **the Codex stub does not copy the content, it points to the file**.
If it copied, you would have two versions diverging — the very `cp` problem all
this exists to eliminate. You edit the `SKILL.md` once and both agents see the
change instantly.

A hard rule follows: **no kernel skill may name the tools of a specific
agent**. It describes *the action*, not *who runs it*. And a test enforces it.

### The hooks in both agents

Codex reads hooks from `~/.codex/hooks.json` with the same format as Claude
Code, so `crux hooks install` registers the same shell scripts there: the
reminder and the sync when a session opens, the task and the cycle on write,
the guards before each command and the documentation gate at close. Three
differences:

- Codex has no file tools of its own (it edits with `apply_patch`), so the
  guards look only at `Bash`.
- Hooks that give context as text go through
  `adapters/codex/hooks/contexto.sh`, which wraps it in `additionalContext`:
  Codex only guarantees it in JSON.
- The memory guard is not installed, because it reviews Claude's memories.

Codex asks for approval of each hook the first time it sees it; until then it
does not run. If Codex is not on the machine, nothing is written.

### What exists only in Claude: the plugin with mods

Since 2.1.287, Claude Code supports *mods*: TypeScript modules that ship inside
a plugin, receive the session's events and can draw in the interface.
`adapters/claude/plugin` brings one, and it is a layer on top of the common
part, not a substitute:

- **The task reminder as a panel** above the prompt, with a number to resume
  each one. The data comes from `lib/task-sync.mjs`, just like the text of the
  `session-sync` hook. The mod sets `CRUX_REMINDER_UI=panel` before the hook
  runs, and the hook then leaves its text for the model alone.
- **The workspace's task in the prompt footer**, among the mode labels, updated
  at the end of each turn.

`crux hooks install` loads it with `CLAUDE_CODE_PLUGIN_DIRS` in Claude's
`settings.json`, which no other agent reads: in Codex, the web or mobile
everything keeps arriving as text. The mod's tests are run by
`claude plugin test`, and the kernel suite launches them when `claude` is
present.

### What happens when you run `crux doctor`

```
bin/crux (dispatcher)
  └─ resolves CRUX_HOME from its real path
  └─ exec bin/doctor.sh
       └─ loads lib/common.sh
       └─ find_docs_repo()        walks up the tree looking for crux.json
       └─ reads the contract
       └─ loads profiles/<profile>.json
       └─ seven check blocks
       └─ exit 0 | 1
```

The seven blocks: contract, mandatory structure, declared repos versus
reality, profile rules, declared sections, markdown links and skill format.

**Errors** break the standard. **Warnings** point to a misalignment that
deserves a decision, not necessarily an action.

---

## Level 6 — The development cycle

Three skills hold up the day to day.

### `/workspace` — before starting

A git worktree isolates the files. **The runtime it does not.** That is the
part that gets forgotten and the one that does damage: two parallel tasks on
the same repo still fight over the port, the database and the `.env`. The
conflict you thought you had eliminated reappears as corrupted data — worse
than a merge conflict, because it is silent.

```bash
crux workspace new fix-login
crux workspace list
crux workspace rm fix-login
```

Each space receives a **slot**: a derived port range, database and environment
file. It is configured in the project's `crux.json`:

```json
"workspace": {
  "portBase": 3000,
  "portsPerSlot": 10,
  "envFile": ".env.local",
  "env": {
    "PORT": "{{PORT0}}",
    "ENGINE_PORT": "{{PORT1}}",
    "DATABASE_URL": "postgres://localhost/app_ws{{SLOT}}",
    "REDIS_URL": "redis://localhost:6379/{{SLOT}}"
  }
}
```

A shared registry guarantees that two spaces do not take the same slot, and
released slots are reused.

**Design detail**: the worktree is created as a **sibling** of the repo
(`<repo>-ws-<name>`), not in a separate directory. This is deliberate: the
context pointers are relative paths (`../<project>-docs/`), and from outside
the project they would stop resolving. The agent working there would be left
without context.

What to isolate, in order of damage: ports (fails on startup), database
(corrupts silently), environment file (invalidates the above), stateful
volumes, shared external resources (here you usually cannot: do not launch in
parallel tasks that touch them).

### `/ship` — before committing

A chain of gates where any one aborts:

```
1. Sanity       tests green BEFORE looking at anything
                (if they were already red, it is not your diff: say so and stop)
2. Diff         read it whole: does it do exactly what you intended?
3. Correctness  bugs, edge cases, unhandled errors
4. Quality      is there a simpler way? — after 3, never before
5. Regression   tests again, because fixes break things
6. Reality      bring up the environment, only if the diff touches observable surface
7. Doc drift    does this invalidate any documentation?
8. Commit       conventional commit that explains the why
```

Gate 6 is the expensive one. A script classifies the diff and decides:

```bash
bash ~/.claude/skills/ship/scripts/diff-scope.sh
```

| What it touches | What to validate |
| --------------- | ---------------- |
| Interface | See it, in the viewports that matter |
| API | Call the endpoints, not just their tests |
| Data | That the migration applies **and reverts** |
| Dependencies | That it starts from scratch, not from your cache |

Two design decisions that decide whether this gets used or abandoned: **gate 6
is conditional** and **there is a quick mode and a full mode**. If it takes twelve minutes
always, you stop invoking it within two weeks and the gate has failed.

Putting 3 before 4 is not casual either: **simplifying incorrect code is
throwing the work away**.

### The rest of the cycle

`/write-tests` and `/root-cause` cover what previously had no procedure:
choosing what deserves a test and debugging without proposing the fix before
understanding the failure. `/e2e` puts the criterion ahead of the tool —a flow
deserves one if its breakage is reported to you by a user and not by a test—.
`/code-health` measures the whole, not the diff, which is what erodes slowly
when a lot of code is generated. And `/explain-plan` presents a proposal so it
can be stopped in time.

### After proposing: CI, risk and production

Opening the proposal does not finish the work. Three gaps remain where, without
an explicit step, nobody is looking.

**CI.** `crux checks --wait` waits for the checks and, if something fails,
brings only the end of the log of the job that failed, with call stacks
trimmed. It is fixed on the branch and pushed again, three attempts at most.

**Risk.** `crux review` classifies the proposal as low, medium or high risk and
says which specialist reviewers it deserves: security, data, performance or
interface. Only those are launched, in parallel and each in its own context.
It costs between 20,000 and 50,000 tokens per specialist, and that is why a
small change or one without code launches none. The same classification says
who merges: with no code and in an own project it can go on its own; the rest
is decided by a person.

**Production.** `/deploy-watch` waits for the new version to arrive and checks
the routes the project declares in `deploy`. If something fails, revert first.
`/prod-signals` reads the logs the project declares in `observability` and
summarizes them by grouping repeated errors, which is where `/root-cause`
starts when the failure only happens on the server.

### `/end-session` — before closing

Four questions about the session —decisions, gotchas, conventions,
preferences—, each with its destination. Then: agent memory hygiene, `crux
doctor`, review of the skills boundary, per-item confirmation from the user,
commits by category and a final report.

A rule that runs through it all: **memories of type `project` and `reference`
go to git; only `user` and `feedback` stay local**. The former belongs to the
project and has to survive a change of machine; the latter is about the person.

That part no longer depends on the ritual being invoked. `crux memory` lists
what is still only local, and a hook reminds you at session close. It was
measured: the ritual was invoked in 2 of 46 sessions, and meanwhile there was
project analysis that only existed on one laptop. What does not fire by itself
does not fire.

---

## Level 7 — Extending it

### The boundary between kernel and project

The old rule was "would it serve another project?", which is answered with
imagination. The new one can be applied:

> **Cover all the proper names in the skill. If the procedure still makes sense
> and has value, there is a pattern inside.**

The procedure is promoted; in the project a short **adapter** stays, with
paths, credentials and proper names.

A real example: `mobile-native-test` described how to test an app on a
physical Android. With the proper names covered, the whole procedure remained
—adb, udev permissions, `screencap`, Fast Refresh, the gotcha that on some
manufacturer layers taps do not reach the app—. That went up as `device-loop`.
Below it stayed `demo-co-device`: package, deep-link and reference device.

Two guards:

- **The two-occurrences rule.** It is promoted when two projects genuinely need
  it. Admissible exception: high demonstrated value and near-zero coupling.
- **The reverse path exists.** If a kernel skill accumulates per-project
  conditionals, it was not a pattern: it is demoted.

### `/skill-audit`

It automates watching that boundary:

```bash
node ~/.claude/skills/skill-audit/scripts/audit.mjs
```

It walks all the adopted projects and reports three things:

- **Low density of proper names.** The terms are derived from each project's
  `crux.json` —its name and its repos'—, so there is no list to maintain.
- **Pairs of different projects that describe the same thing.** The most
  obvious promotion and the most invisible: nobody sees both skills at once.
- **Those that are already adapters**, excluded from the candidates.

- **Adapters that compete with the procedure they adapt.** The sequel to a
  promotion. The three previous signals look forward —what deserves to go up—;
  this one looks at what the promotion leaves behind.

They are signals, not verdicts. The script points, the test decides, the
two-occurrences rule brakes.

Two triggers: **hot**, when creating a skill —that is when it is really
known— and **cold**, hooked to the session close.

### Verifying that a description activates

```bash
node ~/.claude/skills/skill-audit/scripts/probe.mjs "the phrase you would use to ask for it"
node ~/.claude/skills/skill-audit/scripts/probe.mjs --casos
```

Everything else in the system is verified. Activation was the only thing taken
on trust, and it is what decides whether the rest ever gets used.

`probe` says which skill would win a phrase and **by how much**. A margin below
0.5 means two descriptions cannot be told apart: which one wins depends on the
luck of a word. `--casos` runs a file of real phrases with the skill that
should activate, and serves what is really needed — comparing two wordings and
seeing whether a change has switched off something that used to activate.

What it found the first time it was run: the canonical promotion example of
this very guide, `device-loop` and `demo-co-device`, gave an **exact tie**. And
`flow`, which is the default entry point, listed in its description the steps
of the others —"pass the quality gate, propose the change and close the
session"— and so competed with its own pieces.

It does not predict what the agent will do: it scores vocabulary overlap. A tie
is a reliable signal; a winner is not.

### How a skill is promoted, in five steps

1. Separate the procedure from the data: what remains when the proper names are
   covered is what goes up.
2. Write the kernel skill without mentioning projects or the tools of a
   specific agent.
3. Reduce the project's one to an adapter that refers the method to the kernel.
4. **Verify that the extraction lost nothing**: run it against the real case of
   the originating project and check that it gives the same result. A generic
   skill that no longer solves the concrete case is worse than the specific
   one.
5. Reinstall the kernel.

### Versioning the standard

`VERSION` follows semver:

- **patch** — wording, script fixes with no change of contract
- **minor** — new templates, skills or checks; projects remain valid
- **major** — the mandatory structure or the `crux.json` format changes

When the standard evolves it is changed **here first**, and projects align with
`crux upgrade`. No project invents its own variant.

`crux upgrade` materializes the missing pieces and updates the declared
version. It **does not overwrite existing content** except with `--force`: the
documentation belongs to the project, the templates only fill gaps.

---

## Level 8 — Maintaining it

### The kernel's own suite

```bash
./test/run.sh            # all the cases
./test/run.sh doctor     # those matching the pattern
```

Each case runs in an isolated sandbox with the agent directories redirected:
the suite **does not touch** `~/.claude`, `~/.codex` or `~/Proyectos`.

Three kinds of case, and the third is the interesting one:

1. **Functional** — init creates the structure, link is idempotent, upgrade
   updates, workspace hands out slots.
2. **Detection** — that `doctor` **fails** when it should: missing contract,
   broken links, skill without frontmatter, a write into a client's repo.
3. **Structural** — that no kernel skill names a project or ties itself to an
   agent.

The third kind do not test behavior: **they protect the architectural property
that justifies this repo's existence**. If six months from now someone adds a
skill with the paths of a specific project, the test goes red. It is what stops
crux from coupling itself again to what it documents, which is exactly how the
problem was born the first time.

That test already found real dirt three times while the kernel was being built.

### Making the standard enforce itself

```bash
crux hooks install    # from the project's docs repo
crux hooks status
```

It installs five things: a documentation-drift warning at session close, a
warning about project memories that are still only local, a `pre-commit` that
**blocks the commit if `doctor` does not pass**, a `commit-msg` that rejects
messages in Spanish, a reminder of the cycle when starting work on the main
branch, and a guard that stops commands that destroy work (`reset --hard`,
`push --force`, `pkill`…) and the reading of private keys, and another that
stops a hand-run `gh pr create`: the proposal is opened by `finish`, which is
what demands the receipt. With the agent's permissions skipped, that guard is
the only brake left. A standard you have to remember to check gets checked
sometimes.

To test a hook before a release, install it from the kernel workspace where you
are changing it: the settings point at that workspace. When you close it with
`crux workspace rm`, the hooks return on their own to the main checkout and the
ones that only existed in the workspace are removed.

The language one is the clearest example of why a hook is needed and not a line
in a document: the rule had been written since the first commit and **all 27
messages in the kernel's history were in Spanish**. The `commit-msg` goes into
the code repos as well as the docs repo, because that is where most commits
happen — except with the `client-repo` profile, where nothing of the client's
is touched, not even its hooks.

The cycle one exists because of an uncomfortable measurement: the skill that
describes it was written, installed and had its description, and `crux usage`
showed it with **zero invocations in 31 sessions**. A description competes for
attention with forty others; a hook arrives on its own. It fires on **state**
—where you are and on which branch—, never on what the prompt says: guessing
intent from words ends up warning when it should not and staying silent when it
should. And it speaks once per session, because noise is learned to be ignored
before it is learned to be obeyed.

It warns in **any repo that lives under your projects root**, registered or not
(ADR-014). Before, it also required the project layout with its docs repo next
to it, and the loose repos at the root were left out exactly when nobody was
watching them. What lives there without being yours is excluded with
`CRUX_UNMANAGED`.

A hook that points at a nonexistent file does not fail: it does nothing. And
that is worse, because the system looks watched and is not. That is why
`doctor --machine` treats it as an error.

### Knowing whether this is useful

```bash
crux usage --days=90
```

It measures which skills are actually used against the installed catalog, and
separates those never used. It is not a deletion list: an incident skill that
is unused is good news. What to look at is the one that has existed for months,
covers something frequent and still nobody invokes — almost always its
description does not activate when it should.

It counts **two signals, and does not add them**:

| Column | What it is |
| ------ | ---------- |
| `call` | The skill invoked by name |
| `script` | Trace of its scripts in commands: the procedure followed by hand |

The second exists because the first lied. Whoever followed the procedure
without calling the skill showed up as zero: the quality gate was listed with 2
invocations while it was being passed in four proposals in a row, and **four
kernel skills came out as dead while in use**. And they are not added because
they are not the same unit — `script` is an upper bound, since it includes what
the tests execute.

What remains unmeasured: **whether the procedure was followed in full**.
Running the gate's script does not say that its eight gates were passed. No
local metric sees that, and it is worth remembering before drawing conclusions.

It distinguishes **having no data** from **having no use**, which is the easy
way to lie with this metric.

### What to do when something fails

| Symptom | Probable cause | Fix |
| ------- | -------------- | --- |
| `crux.json is missing` | The project is not adopted | `crux adopt` |
| `materialized with crux X, the kernel is Y` | Outdated standard | `crux upgrade` |
| `<repo>/ has no AGENTS.md` | New repo without pointers | `crux link` |
| `repos/<x>/ is not declared` | Orphan folder | `crux add-repo`, or delete it |
| `broken markdown links` | Documentation moved | Fix, or switch to backticks |
| `profile client-repo: ... should not exist` | Something was written in foreign code | Delete the file |
| A skill does not appear in the agent | Outdated installation | `~/Proyectos/crux/install.sh` |
| `crux clone` does not know where to fetch something from | No `remote` in the contract | Declare it, or `crux adopt` to deduce it |
| A hook does nothing, or "failed with non-blocking status" on every turn | It points at a file that no longer exists | `crux hooks status` to see it, `crux hooks install` from the main repo |
| A tool is missing for a skill | — | `crux doctor --machine` |

### The link rule, which surprises everyone

Inside the documentation **only files of the documentation repo itself are
linked**. References to the code of a sibling repo go in backticks, as text,
unlinked.

Why: links break when files move and, without a build to validate them, they
end up lying. A path in backticks the agent resolves just the same and never
breaks. `crux doctor` verifies the ones that remain.

---

## One-page summary

- **Install**: clone `crux` and run `install.sh`. Once per machine.
- **New computer**: `install.sh --remote '...'` and `crux clone <project>`.
- **New project**: `crux init <name>`. Deterministic, comes from templates.
- **Existing project**: `crux adopt`. Rewrites nothing.
- **New repo**: `crux add-repo <name>`. Declares, documents and links.
- **Parallel work**: `crux workspace new <task>`. Isolates files and runtime.
- **Before committing**: `/ship`. Eight gates, the expensive one is conditional.
- **If it is visible, before pushing**: `/before-after` and `crux visual approve`.
  What a person approved goes to the proposal.
- **With the proposal open**: `crux checks --wait` and `/review-pr`. Reviewing
  is not confirming, and the diff decides the specialists.
- **After merging**: `/deploy-watch`. Merged is not published.
- **Before closing**: `/end-session`. What must survive goes to git.
- **When you doubt whether something complies**: `crux doctor`. The standard is
  verified, not trusted.
- **Make it enforce itself**: `crux hooks install` in each docs repo.
- **Know whether it is useful**: `crux usage`.
- **When the standard improves**: change it here, and `crux upgrade` in each
  project.
