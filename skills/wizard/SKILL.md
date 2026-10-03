---
name: wizard
description: Generate an interactive bash wizard that walks a person, step by step, through a manual procedure the agent cannot do: provisioning infrastructure, pulling credentials from someone else's dashboard, putting secrets into CI, or running a one-off migration. It opens each URL, says what to copy, collects the values and writes them where they belong. Use when a third-party service has to be configured, when a deployment depends on secrets someone has to go and fetch, when an irreversible infrastructure change is coming, or when the user says "no me acuerdo de los pasos" or that they already explained this last time.
---

# wizard

Some steps the agent cannot take: logging into a dashboard that requires a
person's session, clicking "create" on something that costs money, reading a
token that is only shown once. Those steps always end the same way: a list of
instructions in the chat that is lost when the session closes, and two months
later they have to be explained again.

A **wizard** turns that list into an executable script. It opens each URL, says
exactly where to click and what to copy, collects the value, writes it where it
goes (`.env`, GitHub secret), asks for confirmation before anything irreversible
and shows how many stages remain.

**Don't use it for what the agent can do.** If the step is solved with a command,
run it and move on.

## What is already solved

`template.sh` ships the whole library: staged progress, confirmation gates, URL
opening on Linux, macOS and WSL, hidden input for secrets, idempotent writing to
`.env`, `gh secret`/`gh variable` and a final summary of what is still pending.

**Your job is only to scope the procedure and write its stages.** Everything
above the `STAGES` marker is identical in every wizard, and that uniformity is
the point: it is not edited by hand.

A wizard is disposable by default: it is written in the scratchpad or in
`scripts/`, run, and deleted. It is committed only if the procedure will be
repeated and deserves to live in the repo.

## Procedure

### 1. Scope

Find out all the manual steps and all the values that come out along the way.
**Read the repo before asking**, never start cold:

- For configuration: `.env`, `.env.example`, `README`, `docker-compose*`, the
  framework config and `.github/workflows/*`. Every `secrets.*` and every
  `vars.*` in the workflow is a value the wizard has to produce.
- For a migration or an infrastructure change: the current state, the final
  state and the irreversible actions between the two.

Show the user the ordered list of stages and which value each one produces, and
have them confirm. They can add, remove or reorder.

**Done when** every stage has a name and an order, and for every value you know
where the person gets it, where it is written (`.env`, secret, both or neither)
and whether it is secret or public.

### 2. Trace the path of each stage

For each stage, write the exact route: which URL is opened, what is done there,
where the value appears and which variable it fills. For example: "Dashboard →
Developers → API keys → Reveal test key → copy".

**If you don't know the current interface or the exact command, say so and ask,
or look it up in the documentation.** Inventing a menu that doesn't exist leaves
the person stuck in front of a screen that doesn't look like what the script
says, and then the wizard is worth less than nothing.

**Done when** every stage is a set of instructions that someone who has never
seen the project could follow.

### 3. Write it

Copy `template.sh` to its destination. Replace the example stage with one
`stage` per step, in dependency order, and adjust `TOTAL_STAGES`.

Use the helpers: `stage`, `say`/`step`, `open_url`, `ask`/`ask_secret`,
`write_env`, `set_secret`/`set_var`, `pause`/`confirm`.

Keep the bar the template sets:

- Open the URL **before** asking for the value found on it.
- `ask_secret` for anything secret.
- `write_env` for anything that has to persist.
- `set_secret` only for what CI really needs.
- `confirm` before any irreversible action.
- One stage, one task. Each `stage` clears the screen, so if you put three things
  in one, the first is gone before the person reads it.

### 4. Check and hand over

```bash
bash -n <script>          # syntax
shellcheck <script>       # if installed
chmod +x <script>
```

**Don't run it yourself from start to finish**: it opens browsers and waits for
a person. Review it by reading: every value from step 1 is collected and ends up
where you said, and every `set_secret` name matches a `secrets.*` in the
workflow **exactly**.

Tell the user how to launch it. If the procedure will be repeated, commit it and
link it from the README, so the next person runs the script instead of asking an
agent.

---

*Adapted from the `wizard` skill of
[mattpocock/skills](https://github.com/mattpocock/skills), MIT license.
`template.sh` keeps the structure of the original library.*
