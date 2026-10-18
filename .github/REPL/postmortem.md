# rea Postmortem: a reverse-engineering tool that turned into a lifecycle-ownership engine

Written as a reading of rea, not a record of our own work. Source: upstream
`morluto/rea` at `23f984b1a` (package `rea-agents` 6.7.0), 3328 non-merge commits from
2026-04-14 to 2026-10-18. Commit history, `docs/architecture.mermaid`, `AGENTS.md`,
`docs/tool-design.md`, `docs/testing.md`, `docs/roadmap.md` and `.agents/skills/**` were read
with rg over `git log --format='%h %ad %s'` (index: `/tmp/rea-log.txt`). Every sha below
resolves in this checkout. Phase A measurements (c05, node 24.14) are in `/tmp/rea01/`.

## 0. Summary

rea ("Reverse Engineer Anything") is a local-only TypeScript tool. It gives an agent one
contract, the **Evidence record**, over about 30 reverse-engineering engines: Hopper, Ghidra,
IDA, JEB, Kuna, objdump, Rizin, GDB, pwntools, WABT, EVMole, JADX, Apktool, Binwalk/Unblob,
Frida, ADB, Playwright/CDP, V8 Inspector, its own JavaScript AST and artifact-graph readers, and
others. It started as a 149-line Python wrapper around Hopper's own MCP server (`729d3e927`).
Three months later it is a 337k-line TypeScript codebase (101k in `src/domain` alone, 302k in
`tests/`), and the same `AnalysisProviderRegistry` and `BinarySession` serve both the CLI and the
MCP server.

The architecture is a strict inward-dependency onion. That part was designed on one day
(2026-07-12, `9960695bc`..`c047fcbd5`) and has held. Most of the effort since went elsewhere.
**About a quarter of all commit subjects (843 of 3328) are about cleanup, ownership,
cancellation or lifecycle, and 298 of those landed in October alone.** The engines are easy to
wrap. The hard part, and most of the defects, is proving which process, file, temp directory
or socket rea _owns_, and saying so honestly when it cannot. The dominant lesson for anyone who
wraps external tools for an agent (us, with prg/purl): **ownership and "unknown" are first-class
result values, not error paths.** rea learned this by fixing it about 600 times, one
`fix(x): retain ... ownership` at a time.

## 1. Architecture as it now stands

### 1.1 The layer map (draw this first)

```
  entry        scripts/rea.mjs  ──┬──> src/cli.ts + src/cli/      one-shot CLI   (rea <cmd> --json)
                                  └──> src/main.ts + src/main/    MCP stdio server (rea mcp)
                                              │
  composition  src/composition/   fresh typed provider + session factories, nothing started,
                                  optional adapters load independently (one failure ≠ all)
                                              │
  adapters     src/server/  MCP request translation, tool registration, toolResult
               bridge/      hopper_bridge.py (inside Hopper), ReaGhidraBridge.java (headless)
                                              │
  application  src/application/   shared CLI/MCP workflows
               ├ AnalysisProviderRegistry   sorted deep candidates, deterministic, NO fallback
               ├ SessionProviderRouter + BinarySession   one immutable deep binding per target
               ├ investigation/  InvestigationRecords, EvidenceLedger, Unknown ownership
               └ BinarySessionRecords + AnalysisSnapshotCache
                                              │
  providers    src/{hopper,ghidra,ida,jeb,kuna,objdump,rizin,gdb,native/pwntools,wasm,evm,
                    android,apktool,adb,firmware,dotnet,browser,inspector,frida,sqlite,
                    pcap,go,rust,flutter,electron,artifacts,javascript,reference,...}
               src/providers/   shared deferred client + inspection owners, cleanup retry
                                              │
  process      src/process/   owned process groups, private runtime roots, deadlines,
                              bounded output, TERM→KILL supervision, run-token identity
               src/windows/ + native/windows/   Job Objects, NTFS DACLs (Node-API)
                                              │
  contracts    src/contracts/  caller-visible zod schemas, errorSchemas.ts (error catalog)
                                              │
  domain       src/domain/     pure, side-effect free: evidence.ts, Result, tagged errors,
                               binaryTarget, artifact graph, JS application graph, comparisons
```

The rule in `AGENTS.md`: _dependencies flow inward_. Domain knows nothing. Contracts know the
domain. Providers know process, contracts and domain. Application knows providers only through
ports. CLI and MCP are thin adapters over the same application. `npm run
verify:module-boundaries` enforces this inside lint, so it is a check and not a convention.
Engine protocols (Hopper's Unix socket, Ghidra's headless script, IDA's upstream MCP, JEB's
streamable HTTP) never cross into application code.

### 1.2 The one data type: Evidence

Every successful observation is one strict record (`src/domain/evidence.ts`):
`evidence_id` (a digest), `subject`, `provider` {id, name, version}, `analysis_profile`,
`operation`, `parameters`, `raw_result`, `normalized_result`, `confidence` ∈ {observed,
derived, inferred}, `authority` ∈ {shipped-artifact, controlled-replay, historical-reference,
external-service, analyst-inference}, `environment`, `locations`, `limitations`,
`relationship_coverage`, `evidence_links`. Phase A measured exactly this key set on three
unrelated tools (artifact graph, GNU objdump, JS application analysis). The shape is uniform in
practice, not just on paper.

The four-way split the project talks about (observation / derivation / inference / unknown)
lives in two places. `confidence` carries the first three. Unknowns are a separate owned record
(`investigation/`, "Unknown ownership"), because an unknown has a lifecycle of its own: it is
created, cited and resolved. It is not a missing field.

### 1.3 Selection and sessions

A _deep_ provider (Hopper, Ghidra, IDA, JEB, Kuna) is bound once per target and never swapped
silently. _Auxiliary_ families (artifacts, native readers, objdump, dotnet, ...) route
independently and disjointly. Selection is deterministic and errors on ambiguity. There is no
"try Ghidra, fall back to objdump" (`941d7101d`, `f9f2fbe2f`).

### 1.4 What runs without any engine (Phase A, c05 Linux, node 24.14)

`capabilities --json` (as tabulated in `/tmp/rea01/cap.tsv`): `rea-artifact-graph`
(inspect/extract artifact, IB/keyed archives, dylib resolution) and `rea-dotnet-static` (managed
artifact, members, native boundaries) are available. `native-macos` is `unsupported_host`.
`sqlite` is `unsupported_version` (it needs `DatabaseSync.limits`, node ≥ 24.15). `gnu.objdump`
works with system objdump, and the JS application analyzer needs nothing (semver: 50 files
parsed, 12 MB of JSON). So the engine-free surface on Linux is: artifact graph, managed .NET
metadata, objdump profiles and JavaScript applications. That is enough for a first prg spike.

## 2. ⭐ The dominant lesson: ownership is a result, not a cleanup step

The history has three eras:

| era           | dates        | commits | what was built                                                             |
| ------------- | ------------ | ------- | -------------------------------------------------------------------------- |
| 1 platform    | 07-12..07-25 | 514     | layers, providers, Evidence, sessions, replay engines, workflows           |
| 2 subtraction | 08-01..09-30 | 118     | remove ceilings, remove replay, return complete results inline             |
| 3 hardening   | 10-01..10-18 | 2695    | 1873 `fix` commits, about 300 lifecycle fixes, 145 perf, 30+ new providers |

Era 1 drew the right onion. Era 3 is where the real system lives, and its bug population is
very uniform. Of the 1994 `fix` commits, 594 are titled `fix(scope): retain|preserve|keep ...`.
They are corrections where an earlier version _dropped_ something on a failure path: an owner,
a cleanup capability, a cancellation reason, a partial fact or an unknown. Examples:
`11bcf4425` (apktool retains command cleanup ownership through recovery), `22a0746f9` (WASM
retains cleanup ownership through WABT recovery), `592793717` (Kuna preserves cancellation and
cleanup ownership), `dcfc5d403` (setup retains regular-file cleanup ownership), `a82e37c80`
(browser module resolver), `1f7e279aa` (ADB rollback ownership and cancelled acquisition facts).
The same bug was fixed in about 30 provider directories, because each provider was first written
with "cleanup is a finally block".

The fix that worked was not a better finally. It was giving the shared machinery a **model** of
ownership: `70e1a0f53` extracted provider-neutral ownership, private runtime roots, absolute
deadlines, bounded output and verified TERM→KILL supervision into `src/process/`. `513fa294a`
added run-lineage tokens so a PID alone never proves identity. `2160d4fae` consolidated boundary
ownership and cleanup failure paths. `AGENTS.md` now states the invariant: _a PID and executable
path alone do not establish ownership after exit or reuse; retain ownership of resources whose
cleanup failed; malformed owned data may still be safely removable_. `docs/tool-design.md#own-the-lifecycle`
grew into roughly 90 lines of rules: shared startup has one producer, the final departing caller
waits for cleanup, cancellation must be re-checked after the last awaited finalization, and the
caller's abort reason is preserved as the typed error's cause.

**Transferable rule:** when a tool wraps child processes or temp state for an agent, model
`{owned, released, release_failed(retained), unknown}` from day one and return it in the result.
Every provider that skipped this paid for it later in its own `retain ... ownership` fix.

## 3. Findings

### 3.1 ⭐ Design the onion on day one, and the rest becomes additive

The TypeScript rewrite landed in about ten commits on a single day, layer by layer: domain
(`9960695bc`), contracts (`8d21406e3`), Hopper transport (`1dd057a7c`), application
(`63b33abcf`), MCP server (`09bec111d`), config and composition root (`c047fcbd5`). Since then,
roughly 30 providers have been added without touching that skeleton. `src/composition/` moved
_out_ of application workflows (`33d4761cc`) and later became lazy (`21dbcf7a1`, defer binary
provider composition), but it kept the same position in the onion. **Action:** for prg's
producers, fix the layer boundaries before adding the second producer.

### 3.2 ⭐ Python MCP → Node was a rewrite, not a port

`729d3e927` was a Python proxy in front of HopperMCPServer: 39 tools, no injection, a Hopper-only
worldview. `fbce15f99` deleted it outright and `b0301b81d` started the Node project. Nothing from
the Python version survives except `bridge/hopper_bridge.py`, which runs _inside_ Hopper's Python
and is therefore an engine-side adapter rather than rea code. The rewrite's payoff was a single
runtime for CLI and MCP (`97541d8da`, "share runtime between CLI and MCP") and a typed, zod-based
contract layer. **Lesson:** a proxy in front of one engine and an engine-neutral platform are
different products, and the second could not grow out of the first.

### 3.3 One Evidence envelope, enforced by breaking changes

Evidence appeared on rewrite day (`4f18e26ee`, "evolve REA analysis platform", added
`src/domain/evidence.ts`). It became mandatory for managed reconstruction in `d36af5d0f` and for
contract references in `ee1cd4040`. It was then made canonical and strict in `63bf91405`
(`refactor!: enforce canonical evidence and provider boundaries`): obsolete envelopes, session
aliases, incomplete snapshots and producer-field repairs were _no longer accepted_.
Coverage commitments followed in `db8128dc0` (`refactor(evidence)!: require current coverage
commitments`). The envelope is the stable integration point, so **it is what prg should ingest**
(§9).

### 3.4 "Missing coverage is unknown, not absence"

This is the most repeated semantic rule in the docs and the history. Examples: `84cf7791a`
(caller-only unknown coverage must not block `not_found`), `b19f9e4d2` (keep spread argv counts
unknown), `9534e42ec` (ADB: mark unknown permission coverage partial), `e55ef7213`
(`fix(runtime)!: preserve unknown debugger attachment state`) and `10e9448d8` (anchor
deterministic replay to unknown creation). `relationship_coverage` exists so that a caller-list
result can say "complete _for what the provider observed_" without claiming runtime
completeness. **For prg:** a corpus row built from rea needs a coverage column. Without one, prg
will read an empty callers list as "no callers".

### 3.5 No fallback in provider selection

`941d7101d` introduced the explicit registry with "exact provider/profile provenance without
request racing or transparent fallback". The architecture diagram states it in one line:
"deterministic selection, no fallback". The motivation is provenance. If Ghidra silently became
objdump, the Evidence `provider` field would be correct, but the _agent's_ expectation of
decompiler-grade facts would not be. Where fallback does exist, it is narrow and documented
(Ghidra file-offset fallback applies only to decompilation, and `9df559b7e` gates document
selection fallback). **Lesson for us:** purl/prg already route by recipe, so keep it that way and
never auto-substitute a weaker source.

### 3.6 Subtraction month: remove ceilings, return complete results inline

On 2026-09-29, in about 80 commits, rea deleted most of its "agent budget" machinery:
`5f73cb061` (remove arbitrary workflow ceilings), `9aec6908b` (JavaScript analysis ceilings),
`abf7c1142` and `f2dc749c8` (process scenario and request ceilings), `dca293a44` (session ledger
quotas), `20152a987` (fixed result quotas), `a2a3243ea` and `0d96275b6` (return complete
results inline), and `81996df7a` (remove cross-version investigation workflow). The rule that
replaced them is in `docs/tool-design.md`: _an assumed agent budget is insufficient
justification for a limit_. Limits must come from format, protocol, authority or measured
resources. **False assumption of limitation:** the team believed agents needed rea to truncate
results. Truncation produced wrong answers that looked complete, and it cost more calls.

### 3.7 ...and then the token problem came back as _views_, not caps

Two weeks after the caps were removed, large results became the cost problem
(`b_js_semver.json` is 12 MB for a 50-file package). The answer was opt-in **retained views** in
place of truncation: `db675f1d5` (select summary, facet, item and paged views of retained
analysis results), `c19e15a2b` (JavaScript summary view), `5156ba44c` (native layout summary),
`17f704050` (discover retained records without full payloads), `58fb37207` (retained inventory
and WASM views) and `748440160` (managed member pages). `8e004522f` then fixed the priority order
in `AGENTS.md`: **agent tokens and context > analysis time > CPU and memory**. Complete Evidence
always stays accessible. **Lesson:** cap by _selection over a complete retained result_, never by
dropping data at the producer. This is the shape prg already has (complete DB, selective ask).

### 3.8 Replay engines: built, then removed as unproven orchestration

July built a lot of active machinery: deterministic capture v3/v4 (`5a361a672`, `ee4d28459`),
reactive scenarios (`69761e95b`, `d34463c27`), finite-state replay machines (`dc0c2e5ac`,
`34c583a17`), isolated JavaScript replay (`d86231ad3`) and cross-version workspaces
(`41366edd5`). `e07b81649` (`refactor!: simplify runtime tools and remove replay engines`)
retired all of it: "let agents compose experiments with commands and local fixture servers". The
roadmap now says _custom orchestration needs a demonstrated requirement_. **This is the largest
"built that need not have" in the repo** (§6), and the reason rea's MCP is primitives plus a few
workflows rather than a planner.

### 3.9 State machines made unrepresentable beat runtime checks

The August refactors encoded analysis, comparison and lifecycle states as exact discriminated
unions: `b8a9da0c0` (`make analysis states unrepresentable`) and `d65730c4c` (`encode comparison
and lifecycle states exactly`). Together with the tagged error algebra and `Result` from day one
(`9960695bc`, `3be439cbf` caller-safe typed error projections), this is why a provider failure
reaches the caller as a structured `{code, category, message, remediation, retryable, details}`
object, as Phase A's sqlite refusal showed. It is not a stack trace. **For us:** prg's shell tools
should emit one-line typed refusals (code + remediation) and not rely on exit codes alone.

### 3.10 The MCP schema is a contract, validated after SDK conversion

Several bugs came from the gap between zod and what clients receive. Examples: `fd08025dc` and
`f728295bd` removed byte gates and compaction that broke schemas, `7425f70fd` advertised JSON
values without recursive schemas, `fe64fd65d` rejected unknown inputs, and `10aa74dfe` preserved
tuple constraints. Then `5ccb9241b` (advertise each schema once per target) and `e1afbc191`
(reuse input schemas) cut the token cost of the catalog. `AGENTS.md` keeps the rule: _validate
advertised JSON Schemas after SDK conversion against their declared dialect and actual clients_.
**Lesson:** the schema an agent sees is a product surface, and it costs tokens on every session.

### 3.11 Target content is untrusted data

`85e124253` framed all target-derived output (strings, decompiled code, page text, logs) as
data and never as instructions, with a `returnsTargetContent` flag per tool. A binary can carry a
prompt injection. **For prg:** any rea-derived corpus row is target content and needs the same
framing before an LLM reads it in `prg ask`.

### 3.12 Composition: optional adapters must not take down peers

`be3cfbffd` isolated optional observation adapter failures. `3ed59b281` shared Android and
firmware provider factories. `b808e2d6b` declared deep capabilities from source. `ce73c3fed`
composed investigation-record ownership. CONTRIBUTING now says: _production factories construct
fresh providers without starting engines or acquiring targets; optional adapter failures must
preserve successful peers_. Phase A confirms the effect: `capabilities` returned a mixed
true/false table on a box with no engines at all, without failing outright.

### 3.13 Tests: boundary-first, and pruning is a feature

`d4dc940bd` (keep coverage at behavioral boundaries), `e91c8c39c` (colocate pure-domain tests,
reduce test debt), `56e2bf769` (remove vacuous and duplicate assertions), `0e0b386dc` (classify
application scenarios by their actual boundaries) and `283c82f68`, the repo's **only revert**,
which removed re-added duplicate acceptance tests because they pushed jscpd over its 2.5 %
duplication gate. The testing doc orders evidence as real CLI/MCP workflows, then production
boundary integration, then producer goldens, and says _simulated providers do not establish
real-provider behavior_. The duplication gate is a real check, not advice. **Lesson:** a
duplication budget in CI keeps a 300k-line test tree prunable.

### 3.14 Real-toolchain lanes separate claims from simulations

Provider claims require a "real verification lane" (`docs/testing.md#real-toolchain-verification-lanes`).
Examples: `af3831bb5` (real-Hopper verification script, rewrite day), `0b3551076` (Windows Ghidra
P0 acceptance and real-engine lanes), `5cbf06c7a` (admit Ghidra 12.1 and the install's JDK
range) and `70cd4cbfb` (`fix(hopper)!: verify current Linux releases with the publisher key`).
PR bodies must report "only checks that actually ran". This is R-MEASURE, written by someone
else.

### 3.15 Setup is consent-gated and additive

`3793889ce` (make installation explicit and safe), `992ec505b` (require explicit setup
selections), `6256b6866` (`feat(setup)!: expand agent integrations and verify updates`) and 83
`fix(setup)` commits. Setup writes MCP registrations for about 15 agent clients (Codex, Claude,
Copilot CLI, Cursor, ...), shows a dry-run plan, and installs nothing unrelated. Ghidra, IDA and
Java are bring-your-own. **For us:** we will not run `rea setup`. We call the CLI directly (§9),
which avoids this whole surface.

### 3.16 Agent-written at scale, and it shows in the fix ratio

Since 10-01: 2695 non-merge commits, about 690 with a `Claude Opus` co-author trailer, 60
factory-droid, 30 Cursor Agent. The peak was 324 commits on 10-13 (PR numbers pass #4700). Fix
commits outnumber feat 1994:253. Many fixes are _one invariant applied to one more directory_
(§2). The skills (`.agents/skills/rea-tool-design`, `rea-ci-tests-audit` `21aa877e5`,
`rea-analysis-optimization` `9744d0721`) are the maintainers' answer: they encode the review
rules so agents apply the invariant everywhere at once. **Lesson:** when agents write the code,
the leverage is in the written invariant and its check, not in reviewing each instance.

### 3.17 Process identity needs more than a PID

`513fa294a` (provider and verifier run lineage), `22fdcb8ab` and `b22d81707` (batched ownership
tokens during rooted cleanup), `80896a1d6` (settle launcher exit without dropping descendant
lineage) and `4303dcdcf` (name the retained pwntools process group). On Windows the same model
needs a native Node-API module for Job Objects and protected DACLs (`native/windows/`,
`ea1c164e5`, `9b08c2b1c`). **Transferable:** our fleet `room` and tmux supervision have the same
PID-reuse hazard. rea's run-token approach is a fix we could copy.

### 3.18 Performance claims require equivalent completed tasks

`.agents/skills/rea-analysis-optimization/references/kuna-case-study.md` records a binary-search
lookup that took 28 warm exact reads from 495 ms to 91 ms. The same study records that an
attempted removal of a duplicate-detection set was dropped because no stable memory benefit was
measured. The rule from `8e004522f`: report tokens, elapsed, CPU and peak process-family memory,
cold vs warm, and state what was not measured. _Fewer bytes alone do not establish fewer tokens._

## 4. The false assumption that cost the most

**"A wrapper's job is to call the engine. Cleanup is plumbing."** Era 1 shipped about 25
capability families in two weeks on that assumption. Era 3 spent about 300 commits in 18 days
retrofitting ownership, cancellation and unknown-preservation into each family, one at a time.
`70e1a0f53` had extracted the right primitives on 07-15, but providers added later (WASM, EVM,
pwntools, Frida, JEB, Kuna, Apktool, ADB, SQLite, Flutter, Go, Rust) were written against the
_signature_ of those primitives without their _invariants_. Each then needed its own `retain
cleanup ownership through recovery` fix. The runner-up false assumption, already covered in
§3.6, was that agents need the producer to truncate.

## 5. Gains and losses (frontier view)

**Gains**

- One Evidence envelope across about 30 engines, uniform in practice (measured, §1.2).
- One runtime behind CLI and MCP. Every MCP tool is a `rea <cmd> --json` call, which makes rea
  scriptable from a shell with no MCP client.
- Typed refusals with remediation (§3.9), visible on unsupported hosts and versions.
- A large engine-free surface (artifact graph, .NET metadata, JS applications, objdump).
- Written, checkable invariants: module-boundary lint, jscpd gate, real-toolchain lanes.

**Losses**

- Size: 337k source lines plus 302k test lines for a tool whose engine-free core is perhaps a
  tenth of that. Era 3's fix rate (about 100/day) means any pin goes stale within days.
- Toolchain pinning is tight: node 24.15 for sqlite, npm 11.16. Phase A hit the sqlite floor on
  the fleet's node 24.14.
- Output size by default: 12 MB of JSON for semver. You must ask for views.
- Churn: 64 `!:` breaking subjects and 58 `BREAKING CHANGE` footers. A consumer must pin the
  version (`rea-agents@6.7.0`) and re-measure on each bump.

## 6. `kiss`: what got built that need not have

- **Replay engines and reactive scenarios** (`dc0c2e5ac`, `34c583a17`, `69761e95b`,
  `d86231ad3`), built and then deleted (`e07b81649`). About two weeks of the July platform.
- **Cross-version investigation workspaces** (`41366edd5`), removed in `81996df7a`.
- **Arbitrary ceilings and quotas** (§3.6), added defensively and removed in one day. They were
  replaced by views (§3.7), which is what should have been built first.
- **Schema byte gates and compaction** (`fd08025dc`, `f728295bd`): an optimization that broke
  clients.
- **A readiness tool** dropped in `7acac615c`, and **legacy skill compatibility** dropped in
  `8cf0dd2bf`.
- **Package renames on day one** (`853a54799` → `4c8b3341c`): `reaa`, then `@morluto/rea`, now
  `rea-agents`.

Counterweight: the subtraction was itself disciplined. Each removal named the replacement
(compose with commands, use views), and the only revert in 3328 commits (`283c82f68`) undid a
re-_addition_, not a removal.

## 7. `frontier`: open questions

1. **Is rea a library or a CLI for us?** It ships no stable programmatic API, but the CLI `--json`
   output is the stable Evidence contract. Our plan answers "CLI + files". Revisit only if we
   need retained-session views across calls, which need the MCP or a long-lived process.
2. **Node floor.** sqlite needs node ≥ 24.15 and the fleet has 24.14. Bumping is an all-box
   change and needs its own plan.
3. **Which engine, if any, is worth installing?** Ghidra brings decompilation and xrefs but also
   Java and per-box cost. Measure a question that objdump plus the artifact graph cannot answer
   before installing it.
4. **How do we track upstream?** It moves at about 100 commits/day. Our fork carries only
   `.github/REPL/`. Merge-tracking main is cheap only while we touch no code.
5. **Prompt-injection framing in prg.** rea marks target content (§3.11). prg's `ask` does not
   yet distinguish target-derived rows from user documents.

## 8. The transferable method

- **Fix the onion first, then add producers.** rea's layers survived 30 providers because they
  were fixed on day one (§3.1).
- **Model ownership and unknown as values.** Every provider that treated them as error-path
  plumbing needed a retrofit (§2, §4).
- **Never truncate at the producer. Select over a retained complete result** (§3.6, §3.7).
- **No silent fallback between sources of different strength** (§3.5).
- **Delete orchestration that agents can compose themselves** (§3.8).
- **Turn the invariant into a check** (module-boundary lint, jscpd gate, real lanes) and then
  let agents apply it everywhere (§3.13, §3.16).

## 9. For us: what of rea plugs into prg, the purl way

purl gave prg _search + download → folder → `bin2md --corpus` → case.prg.db_. rea can give prg
_binary → Evidence JSON → folder → the same corpus_. The chain the user named is
**telemetry → repo → source → binary folder → case.prg.db**, and rea fills the last hop prg has
no reader for: shipped bytes.

**Producer shape (purl's shape):** `rea.sh PATH [DIR]` runs a fixed set of engine-free
one-shot commands with `--json` and writes one `.json` per operation into
`$PURL_HOME/rea_<name>_<hex8>/`. hex8 is the sha256 of the target, so a rerun re-syncs the same
directory. A jq projection then writes the `.jsonl`/`.md` rows that `bin2md --corpus` reads. No
MCP client and no `rea setup`. The CLI is the same runtime (§3.2).

**What becomes corpus rows** (from Phase A JSON, not docs):

| rea operation (engine-free)                            | Evidence `normalized_result` field                                  | prg row                                                 |
| ------------------------------------------------------ | ------------------------------------------------------------------- | ------------------------------------------------------- |
| `inspect_artifact` (artifact graph)                    | `observations`, `coverage`, `limitations`, `hypotheses`             | artifact/format facts, one per observation              |
| `objdump symbols` / `file_headers` / `section_headers` | parsed symbol table, headers                                        | symbol, section, import rows                            |
| `analyze_javascript_application`                       | `graph`, `semantic_graph`, `summary`, `statistics`                  | module, export, call rows (via summary view, not 12 MB) |
| `inspect_managed_*` (.NET)                             | members, native boundaries                                          | type/member rows                                        |
| any                                                    | `provider`, `confidence`, `authority`, `evidence_id`, `limitations` | provenance columns on every row                         |

**Rules carried over from this postmortem:**

- Keep `confidence`, `authority` and coverage as columns (§3.4). An empty list with unknown
  coverage is not a "no".
- Mark every rea row as target content (§3.11).
- Prefer rea's summary/page views over raw full results (§3.7). Project at our boundary once
  (AGENTS: "normalize once at the owning boundary").
- Pin `rea-agents@6.7.0` (`23f984b1a`) and re-run the Phase A smoke on each bump (§5 losses).
- Never fall back silently from a deep provider to objdump (§3.5). If Ghidra is absent, the
  row says `provider=gnu.objdump`.

The integration design (decisions and rejections) is Phase C's
`.github/REPL/fix.archive/rea-prg-integration.md`. The end-to-end question ("which libraries
does bin2md link and which symbols does it export?") is Phase Z.

## Evidence

- Repo: upstream `morluto/rea` HEAD `23f984b1a`. Our planning commits are `121ddccb4` and
  `d685e5a07` (this plan, `.github/REPL/01.code.reading.org.txt`).
- Counts: `git log --no-merges --format='%h %ad %s' --date=short > /tmp/rea-log.txt`, then `rg -c`
  per theme: lifecycle/cleanup/ownership/cancel 843 (Oct 298), `fix(..): retain|preserve|keep`
  594, `!:` 64, BREAKING footers 58, fix 1994, feat 253, perf 145, revert 1.
- Monthly: 2026-04 1 | 07 514 | 08 18 | 09 100 | 10 2695 (non-merge).
- Source size: `src/**/*.ts` (non-test) 337k lines, domain 101k, application 55k, process 11k,
  tests 302k.
- Phase A: `/tmp/rea01/cap.tsv`, `a_inspect_artifact_bin2md.json`,
  `a_objdump_symbols_bin2md.json`, `b_js_semver.json`, `c_sqlite_caseprg.json` (refusal).
