# Code review with sub-pi instances

This project is heavily AI-generated, so an independent AI review of
non-trivial changes is worth doing before they land. The cheapest way to get
a genuinely independent review is to spawn a second pi instance with a
*different* model in non-interactive mode (`pi --print`) and point it at the
change. This note records what worked well on the first real use, so the
recipe and the review checklist are repeatable.

## Why a sub-instance with a different model

The agent that wrote the change (whatever model) has a baked-in tendency to
defend its own design. A *different* model, given only the diff and the
design intent (not the conversation that produced it), starts from scratch
and finds different blind spots. In the first real use, the reviewer (opus)
agreed with the core concurrency argument but caught a silent data-loss race
the writer had rationalized away, a nondeterministic-history bug, and a
cross-tenant lock-hold — none of which the writer had flagged and none of
which the test suite exercised. Models from a different family genuinely see
different things; "same model, fresh session" is much weaker.

## The recipe

Spawn a review as a one-shot, non-interactive sub-pi pointed at the commit.
In this workspace the authed provider is `aperture` (the default), which
fronts many model families. The command shape that worked on the second real
use (reviewing the `ChunkIndex` change) was:

```sh
pi --print \
  --provider aperture \
  --model <review-model> \
  --no-context-files \
  --name "<short-review-name>" \
  @<review-prompt-file> \
  "Review commit <id> ... <one-line instruction>"
```

Do **not** add `--thinking high`: for the models available here it was
silently turned off (the session log showed `thinkingLevel: "off"`), it just
adds latency, and it improved the review in at most a minor way. The review
quality comes from the prompt specifics and the reviewer using the tools,
not from a thinking budget.

### Which `<review-model>` to use

Pick a strong model from a **different family** than the one that authored
the code — the whole point of a sub-pi review is a model that starts with no
attachment to the author's reasoning (see the "different model" section
above). All of these are verified to work with `--provider aperture` (each
was smoke-tested with a trivial "say OK" prompt) and come from five distinct
families, so there's always a valid cross-family pick:

| model                | family           |
| -------------------- | ---------------- |
| `claude-opus-4-8`    | Anthropic        |
| `gpt-5.5`            | OpenAI           |
| `glm-5.2`            | Z.ai / GLM       |
| `deepseek-v4-flash`  | DeepSeek         |
| `kimi-k3`            | Moonshot (kimi)  |

The default authoring model in this workspace is `glm-5.2` (see
`~/.pi/agent/settings.json`), so when you're reviewing a change *you* wrote
here, pick anything from the pool except `glm-5.2` — e.g. `gpt-5.5` or
`claude-opus-4-8`. If you authored the change with a different model (say a
Claude), drop the matching row. `deepseek-v4-flash` and `kimi-k3` are
cross-family to all three of the others, so they're safe picks when you're
not sure what authored the code. `gpt-5.5` (not `-pro`) is preferred over
`gpt-5.4-pro` — it's cheaper and works just as well for review. Run
`pi --list-models` to see the current catalog.

- `--print` / `-p`: non-interactive; process the prompt and exit. Pipe to a
  log file so you can grep/reread it. Caveat: `--print` emits only the
  *final* answer, not the intermediate tool calls, so a long review can hit
  your shell's timeout with an empty log even though the reviewer is still
  working. Use a generous timeout (the second real use did ~19 min of file
  reading and `go test` before writing its review). If it gets killed
  mid-review, the session is still saved under `~/.pi/agent/sessions/`
  (newest `*.jsonl` there); resume it with `--session <id>` and a "write the
  review now" follow-up — it picks up where it left off and finishes in well
  under a minute.
- `--provider aperture`: the authed provider in this workspace and the one
  every pool model above was smoke-tested against. **Pass it explicitly.** A
  bare `--model <gpt-5.5|gpt-5.4-pro|...>` mis-resolves to an
  `azure-openai-responses` provider that isn't logged in here and fails with
  `No API key found for azure-openai-responses`; forcing `--provider aperture`
  routes the model name to the authed gateway. (The `--model <review-model>`
  bullet point and pool table above cover which model to choose.)
- `--no-context-files`: do **not** auto-load `CLAUDE.md`/`AGENTS.md`. You want
  the reviewer judging the code on its merits, not parroting project
  conventions; and you're feeding it a self-contained prompt. (Leave context
  files *on* only if the review specifically needs project-specific rules.)
- `--name`: tags the saved session so it's findable later.
- `@<file>`: attach a written review prompt (see below). Putting the prompt
  in a file keeps it out of shell quoting hell and makes it reusable.
- Give the commit id explicitly in the trailing message and have the prompt
  tell the reviewer how to get the diff (`jj diff -r <id>` / `git show <id>`).
  Don't paste the diff into the prompt — let the reviewer pull it themselves
  so they can also read surrounding code, grep callers, etc. The reviewer
  has the same tools the author does.

Log everything: `... 2>&1 | tee /tmp/<review>.log`.

## Writing the review prompt

A good review prompt is short on ceremony and long on specifics. What worked:

1. **State the goal adversarially up front:** "focused, adversarial code
   review ... find CORRECTNESS and CONCURRENCY bugs, especially fatal flaws
   the test suite would NOT catch. Be specific and skeptical; rank findings
   by severity." Sets the right tone.
2. **Tell them exactly where to look:** list the key files and functions,
   and what role each plays. Saves the reviewer from re-deriving the
   architecture and focuses them on the risky code.
3. **Give the design intent, then ask them to judge the implementation
   against it:** point at the design doc and say "read the design, then judge
   whether the implementation matches and is correct." This catches both
   design flaws and implementation drift.
4. **Enumerate the specific risks you want checked, as questions.** This is
   the most important part. Phrasing each risk as a concrete question
   ("can `cloneFrameFS` observe a tmp path the worker has already renamed
   away?", "is the FIFO guarantee actually strong enough that the parent job
   is finalized before the child reads it?") gets the reviewer to trace the
   exact code paths instead of offering generic advice. Group them by theme
   (concurrency, correctness vs old behavior, crash safety, protocol/compat).
5. **Explicitly ask about tests:** "is there any way the tests missed a
   fatal flaw?" and "what did you check that is NOT a bug?" The second is
   valuable — it forces the reviewer to justify their reasoning and gives
   you confidence in the negatives.
6. **Demand a fixed output format:** severity (FATAL/HIGH/MEDIUM/LOW/NIT),
   location (file:line or function), what's wrong + how to trigger it as a
   concrete sequence of operations, and a concise suggested fix. Start with
   a 3-5 line summary of whether the design is sound. Ask them not to pad
   with style nits.
7. **Tell them to use the tools:** "Use the tools (read files, grep,
   `jj diff -r <id>`) liberally." A review that only reads the pasted diff
   misses callers; a review that greps the repo finds them.

Keep the prompt to a page or so. Long prompts dilute focus; the specifics are
what make it bite.

## Acting on the review

- Read the whole thing, then re-rank by your own judgment — reviewers
  sometimes over-call severity (e.g. flagging a real race as "FATAL data
  loss" when it's "silent taint drop, bad but not data-corrupting"). The
  *locations* and *triggers* are usually right even when the label is hot.
- Fix FATAL/HIGH/MEDIUM findings that hold up. NITs are optional. Don't
  blindly apply every suggestion — the reviewer lacks context you have.
- For each finding you reject, write down why (in your head or the PR
  description) so you can defend it in review.
- Re-run `make test` / `make e2e` after fixes, same as any change.

## What this is not

- Not a replacement for human review for security- or data-integrity-critical
  changes. AI reviewers miss whole categories (subtle trust boundaries,
  spec-vs-intent gaps, things outside the diff). Use it as a first pass to
  catch the obvious-before-human-review, and to surface the concurrency and
  "did you think about X" questions a careful human would ask.
- Not free. A strong model on a ~1600-line diff spent ~19 minutes reading
  files and running the tests before writing its review, plus non-trivial
  tokens. Worth it for non-trivial changes; overkill for a one-line fix.
  (We deliberately dropped `--thinking high`: it was silently ignored for the
  model we used and just adds latency without reliably helping.)
- Not a substitute for the test suite. The whole point is that the tests
  can't catch the class of bugs you're asking about (races, crash states,
  cross-tenant interactions). Run both.

## Checklist (steal this)

When reviewing a concurrency-heavy or stateful change:

- [ ] **Races**: for every shared file/map/field mutated by the new code,
      list every writer and check they're serialized. Pay attention to
      non-atomic writes (truncate-then-write vs temp+rename) and to RMW
      sequences that read a value, mutate, and write back.
- [ ] **Ordering guarantees**: if the design relies on "A happens before B"
      (e.g. FIFO queue ⇒ parent finalized before child reads it), trace the
      *actual* code path and confirm the guarantee holds under errors and
      cross-frame references, not just the happy path.
- [ ] **Lock scope**: every `Lock()` is followed by the minimum work needed
      before `Unlock()`. Flag lock-held-across-subprocess/IO that could
      stall unrelated tenants.
- [ ] **Failure/crash state**: what's on disk if the process is killed at
      each interesting point? Distinguish *corrupt* (a frame/snap that
      can't be read or rebuilt) from *wasteful* (orphaned temp files /
      lost in-memory state). Does restart recovery exist, or do orphans
      accumulate?
- [ ] **Semantic equivalence to old code**: if you split or refactored an
      existing function, diff its observable behavior (stamp/sidecar/
      history/taint write order and values) against the old version.
- [ ] **Protocol/compat**: default-output changes break scripts and rolling
      upgrades. Grep all callers of a changed function signature, including
      out-of-tree assumptions.
- [ ] **Tests**: would the test suite actually catch each finding? If not,
      is there a test worth adding, or is it fundamentally a
      concurrency/timing bug that has to be prevented by design?
