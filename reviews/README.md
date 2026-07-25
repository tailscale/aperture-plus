# Cross-LLM code reviews

Archive of cross-LLM code reviews run via the process documented in
[`../README.codereview.md`](../README.codereview.md) — spawning a sub-pi with a
*different* model family as a one-shot, non-interactive reviewer pointed at the
change. Kept for posterity: they're the concrete outputs that informed the
fixes, and useful to re-read when those areas change again.

Each subdirectory is dated and named for what was reviewed.

## 2026-07-24 — tsnet lifecycle at the app layer + Login button

A two-part review driven by a user report that the Login/Logout buttons felt
inactive / took "sometimes minutes" on a real device, while the XCUITest
`testInteractiveLoginLogoutRelogin` passed on the simulator.

- **`deepseek-tsnet-lifecycle.md`** — `deepseek/deepseek-v4-flash` reviewing
  the full tsnet lifecycle at the app layer (`TSNetManager`, `TSNetModel`,
  `StatusViewModel`, `AuthManager`, `Workspace*`, `TailscaleNode`). 12 ranked
  findings (FATAL/HIGH/MEDIUM/LOW/NIT); the headline ones (drop the
  actor-blocking `up()`; the silent bus-restart death; `.inactive` tearing down
  the node; `try?`-swallowed logout) drove the app-layer lifecycle fixes.
- **`kimi-tsnet-lifecycle.md`** — `moonshotai/kimi-k3` on the same prompt.
  Recovered from the session's `thinking` block (kimi-k3 + `--print` emitted no
  `text` answer — a quirk; the review was in its thinking). Goes deeper on
  `up()` blocking the *entire* `TailscaleNode` actor (freezing all localAPI for
  the whole pre-`Running` window, not just `close()`) and the
  `combineLatest`/`removeDuplicates` ordering race.
- **`deepseek-login-button.md`** — a follow-up focused review
  (`deepseek/deepseek-v4-flash`) after the lifecycle fixes: why the Login
  button was inactive on a real device but the XCUITest passed on sim. Its top
  suspect — `.buttonStyle(.plain)` + a shaped `.background` with no
  `.contentShape` making the hit area the *label's* frame (only the "Login"
  text was tappable, not the visible blue button) — was the actual root cause;
  fixed by switching `StatusButton` to `.borderedProminent`.

The fixes these reviews informed are in the commit that bumped the submodule
pointer and the "Fix interactive login/logout" commit immediately following
the archive. See `timing/README.md` for the measured latencies that
exonerated the library and pointed at the app layer.
