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
├── .githooks/          # tracked git hooks (installed by scripts/setup-hooks.sh)
├── examples/           # the experiments — one script per idea
├── scripts/            # repository tooling (setup-hooks.sh, lint.sh)
├── out/                # run artifacts (git-ignored)
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
