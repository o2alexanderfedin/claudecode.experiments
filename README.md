# claudecode.experiments

A workbench for **non-interactive (headless) execution of Claude Code** — driving
the `claude` CLI from scripts, pipelines and CI instead of from a terminal
session.

Every experiment here is a small, self-contained shell script you can read in
under a minute and run in one command.

---

## Why headless

Interactive Claude Code is a conversation. Headless Claude Code is a **process**:
it takes input, does work, writes output and exits with a status code. That
difference is what lets it be composed — into a `Makefile`, a pre-push hook, a
GitHub Actions job, or a `git diff | claude -p` one-liner.

The whole mode hangs off one flag:

```bash
claude -p "your prompt"      # print the answer, then exit
```

Everything else in this repo is about making that single run **predictable**:
machine-readable, bounded in cost, unable to block on a prompt, and unable to
touch anything it was not given.

---

## Quick start

```bash
git clone https://github.com/o2alexanderfedin/claudecode.experiments.git
cd claudecode.experiments
./scripts/setup-hooks.sh          # install the git-flow branch guards
./scripts/lint.sh                 # bash -n + shellcheck over every script
./examples/01-basic-print.sh      # first headless run
```

**Requirements**

| Tool | Purpose | Install |
|---|---|---|
| [`claude`](https://claude.com/claude-code) | the CLI under test | `npm i -g @anthropic-ai/claude-code` |
| `jq` | parsing JSON / JSONL output | `brew install jq` |
| `git-flow` | branching model | `brew install git-flow-avh` (or `git-flow` for nvie — see the caveat below) |

Scripts write their artifacts to `out/`, which is git-ignored.

---

## Running a task headlessly, on the subscription

The `-p` examples above bill per API token. To run a task unattended **on the
Claude subscription** the session has to stay interactive — which raises the
question this repository was really built to answer:

> How do we make Claude Code execute a task and exit *when the work is done* —
> not before, not never?

The answer that works:

```bash
cat > task.md <<'EOF'
...the real spec, as long as you like...
EOF

./experiments/run-task.sh
```

Three moving parts:

| File | Role |
|---|---|
| [`experiments/run-task.sh`](experiments/run-task.sh) | sends exactly one line on stdin — `execute task from task.md file` — under a pty |
| [`experiments/hooks/stop-terminate.sh`](experiments/hooks/stop-terminate.sh) | `Stop` hook: signals the session the instant the turn ends |
| [`.claude/settings.json`](.claude/settings.json) | wires the hook up |

Measured end-to-end run:

```
❯ execute task from task.md file
  ⎿  pong
raw exit : 143          ← 128 + SIGTERM, sent by the Stop hook
elapsed  : 10s
status   : COMPLETED (terminated by Stop hook after the turn)
```

### Why this design and not something simpler

Each alternative was tried and measured, not assumed.

| Approach | Why it was rejected |
|---|---|
| `claude -p "task"` | Bills per API token instead of the subscription. Non-negotiable for this repo. |
| `printf 'task\n/exit\n' \| claude-eng` | **Piped stdin is read to EOF and submitted as ONE prompt** — a newline is not `Enter`. The trailing `/exit` arrives as prompt *text*. The task ran; the session then stayed open forever. Claude's own words in the transcript: *"/exit … не сработал … сессия останется открытой"*. |
| Append `/exit` later into an open stdin (`tail -f`, FIFO) | Follows from the same finding: submission is triggered by EOF, not by newline. Nothing written after the first prompt is ever submitted. |
| A timer that appends `/exit` "after a while" | A race by construction. Too early truncates the work, too late wastes wall-clock. The finish time is not knowable in advance. |
| `claude mcp serve` | Docs: it *"only exposes Claude Code's tools to your MCP client"*. A tool provider, not an agent runner — no task execution, no completion signal. |
| `echo "/exit" \| claude-eng > 1.txt` | Redirecting stdout makes it a non-TTY, which flips Claude Code into non-interactive mode. Output: `/exit isn't available in this environment.` — and that is the billed path again. |

What survives is the only party that actually knows when the work finished:
**Claude Code itself**. The `Stop` hook fires when the turn ends, so the exit is
an event, never an estimate.

### Terminating the *correct* process

The hook walks up from its own pid and takes the **nearest** `claude` ancestor.
Nearest matters: a runner may well be launched from another Claude Code session,
which sits further up the same chain and must not be touched.

Two safeties:

- The hook is a no-op unless `CLAUDE_BATCH_EXIT=1` is in the environment, and
  only `run-task.sh` exports it. Interactive sessions in this repository are
  unaffected — but note that the hook *is* configured repo-wide and does send
  `SIGKILL`, so it is worth knowing about.
- `SIGTERM` first, `SIGKILL` after a 5 s grace, because Claude Code has been
  observed to ignore `SIGTERM`.

### Harness notes

Driving a TUI from a script has three traps, each of which cost a debugging
round here:

1. **`timeout` needs `--foreground`.** Without it the command lands in its own
   process group, its first terminal read raises `SIGTTIN`, and it freezes at
   0% CPU having rendered nothing and read nothing. This looks exactly like
   "Claude ignores stdin" and is not.
2. **A pty from `script(1)` starts at `0 0`.** The TUI cannot lay out on a
   zero-width terminal and hangs. Run `stty rows 50 columns 200` inside it.
3. **`script(1)` reads termios from its own stdin** and aborts with
   `tcgetattr/ioctl: Operation not supported on socket` when that stdin is a
   socket, as it is under an agent's tool runner. Give it `</dev/null
   >/dev/null` and read the typescript log it writes instead.

The billing rule is enforced in code, not in comments: `run-task.sh` re-enters
itself under a pty and **refuses to launch claude at all** if stdout is still
not a TTY.

---

## The experiments

| # | Script | What it demonstrates |
|---|---|---|
| 01 | [`examples/01-basic-print.sh`](examples/01-basic-print.sh) | `-p` — prompt in, text out, exit. Tools disabled so it can never block. |
| 02 | [`examples/02-json-result.sh`](examples/02-json-result.sh) | `--output-format json` — one object with the answer, session id, timing, tokens and cost. |
| 03 | [`examples/03-stream-json.sh`](examples/03-stream-json.sh) | `--output-format stream-json` — JSONL event stream, rendered as a live timeline. |
| 04 | [`examples/04-structured-output.sh`](examples/04-structured-output.sh) | `--json-schema` — the model's answer validated against a contract you declare. |
| 05 | [`examples/05-piped-input.sh`](examples/05-piped-input.sh) | stdin as the prompt — Claude Code as a unix filter in a pipeline. |
| 06 | [`examples/06-budgeted-agent.sh`](examples/06-budgeted-agent.sh) | budget, tool allowlist and non-blocking permissions — the shape of a safe unattended run. |

Shared helpers live in [`examples/_lib.sh`](examples/_lib.sh). All six were run
end-to-end against Claude Code **2.1.251** on macOS; `./scripts/lint.sh` keeps
them syntax- and shellcheck-clean.

---

## Field notes

Things that decide whether an unattended run succeeds or hangs.

### Output formats

| `--output-format` | Shape | Use it for |
|---|---|---|
| `text` (default) | the final assistant message | humans, `echo`, quick pipes |
| `json` | the run as JSON — the terminal `result` event carries `result`, `session_id`, `duration_ms`, `num_turns`, `total_cost_usd`, `is_error`, `usage` | scripts that branch on the outcome |
| `stream-json` | newline-delimited events: `system` → `assistant` / `user` → `result` | progress UIs, audit logs, long runs |

`stream-json` requires `--verbose`. Add `--include-partial-messages` for
token-level deltas.

> **Version note.** On CLI **2.1.251** `--output-format json` emits an *array*
> of every message in the run, with the `result` event last — not the bare
> result object older docs describe. Do not assume either shape; select the
> event you want. `examples/_lib.sh` exports a `JQ_RESULT` filter that
> normalizes both:
>
> ```bash
> jq -r "${JQ_RESULT}"' | .result' out/run.json
> ```

### Never block

A headless run that waits for a permission prompt is a hung job. Three ways to
guarantee it cannot happen, in increasing order of trust:

```bash
--tools ""                            # no tools exist; nothing to approve
--permission-mode dontAsk             # tools exist, but denials are silent
--permission-mode bypassPermissions   # approve everything (sandboxes only)
```

Pair `--permission-mode` with `--tools` and `--allowed-tools` so the run is
scoped by construction rather than by the prompt asking nicely.

### Bound the blast radius

```bash
--max-budget-usd 0.50        # hard spend ceiling for the run
--tools "Bash,Read,Glob"     # the only tools that exist this session
--allowed-tools "Bash(ls:*)" # the only invocations that auto-approve
--disallowed-tools "Write"   # explicit denials
--add-dir ./sandbox          # extra directories the file tools may reach
--no-session-persistence     # keep the transcript off disk
```

`--restricted` goes further: it removes the command-running tools and WebFetch
outright, ignores user/project settings files, and confines the file tools to
the working directories.

### Keep instructions and data apart

When the payload comes from outside — a diff, an issue body, a scraped page —
put your instructions in `--append-system-prompt` and let the untrusted text
arrive on stdin. Concatenating the two into one prompt is what makes a run
steerable by its own input. Example 05 shows the split.

### Chaining runs

`--output-format json` returns a `session_id`. Feed it back to continue where
the previous process left off:

```bash
sid=$(claude -p "step one" --output-format json | jq -r .session_id)
claude -p --resume "$sid" "step two, using what you just found"
```

Use `--session-id <uuid>` instead when the caller wants to choose the id up
front — handy for correlating a run with a CI job id.

### Reproducibility

`--bare` strips the environment down to what you pass explicitly: no hooks, no
plugins, no auto-discovered `CLAUDE.md`, no keychain reads. `--safe-mode`
disables customizations while keeping normal auth. Between them you can tell
whether a failure belongs to the model or to your local configuration.

### Long jobs

```bash
claude --bg "long running task"   # detach, print a session id
claude agents                     # list background sessions
claude logs <id>                  # tail its output
claude stop <id>                  # stop it, keeping the transcript
```

---

## Repository layout

```
.
├── .claude/            # Stop hook wiring for the headless runner
├── .githooks/          # tracked git hooks (installed by scripts/setup-hooks.sh)
├── examples/           # the -p experiments — one script per idea
├── experiments/        # the subscription-billed headless runner and its hook
├── scripts/            # repository tooling (setup-hooks.sh, lint.sh)
├── out/                # run artifacts and session transcripts (git-ignored)
└── README.md
```

---

## Development workflow

This repository uses **git-flow** with `main` as the production branch and
`develop` as the integration branch.

```bash
git flow feature start <name>     # branch off develop
# ... commit ...
GIT_MERGE_AUTOEDIT=no git flow feature finish <name>   # merge back into develop

git flow release start 0.2.0      # branch off develop
GIT_MERGE_AUTOEDIT=no git flow release finish -m Release-0.2.0 0.2.0
```

Two gotchas when driving git-flow from a script rather than a terminal:

- **`GIT_MERGE_AUTOEDIT=no`** stops each merge from opening an editor. Without
  it a headless `finish` hangs.
- **A space-free `-m`.** nvie git-flow (`0.4.1`, the Homebrew `git-flow`
  formula) parses flags with BSD `getopt`, which rejects spaces inside an
  option value — `-m "Release 0.2.0"` dies with *"the available getopt does not
  support spaces in options"*. Pass `-m Release-0.2.0`, then rewrite the
  annotation before pushing if you want prose:

  ```bash
  git tag -f -a v0.2.0 -m "Release 0.2.0 — what changed" "$(git rev-list -n1 v0.2.0)"
  ```

  `git-flow-avh` does not have this limitation.

**`main` and `develop` are protected.** A tracked `pre-commit` hook rejects
direct commits to either branch and warns on branch names outside
`feature/*`, `release/*`, `hotfix/*` and `bugfix/*`.

`.git/hooks/` is not versioned, so the hook lives in `.githooks/` and a fresh
clone installs it with:

```bash
./scripts/setup-hooks.sh
```

---

## License

MIT — see [LICENSE](LICENSE).
