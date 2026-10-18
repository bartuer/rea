# rea -> prg integration: the purl way (plan 01 Phase C)

Spec: `.github/REPL/01.code.reading.org.txt` Phase C (C.1..C.3). Inputs: Phase A JSON in
`/tmp/rea01/` (c05, node 24.14, rea 6.7.0 @ `23f984b1a`), purl (`cluster/.github/skills/purl/SKILL.md`,
`cluster/.github/REPL/106.purl.org.txt`), prg SKILL.md (SOURCE/TERM/TASK), postmortem.md (Phase B).
Everything below marked MEASURED was run on c05 2026-10-18; spike dirs `/tmp/rea01/proj{,2}/`.

## 1. The shape (one line)

    rea.sh PATH [DIR]  =  rea <op> PATH --json  ->  jq/awk projection  ->  DIR/*.csv + DIR/*.rea.prg.json
                          ->  bin2md --corpus DIR  ->  case.prg.db  ->  /prg ask DIR "question"

prg's slots map as: SOURCE = the projected DIR (a folder, so prg-ask needs no change);
TERM = SQL over the projected tables (symbol name, library, module, relation, state);
TASK = find/count/callers as today. rea is a _producer_ exactly like a purl recipe: it lands
files prg already reads and adds no runtime to prg.

## 2. C.1 -- which Evidence fields become corpus rows (from Phase A JSON, not docs)

Every rea `--json` output is one Evidence record: `{evidence_id, operation, provider, subject{name,
digest.sha256,format}, authority, confidence, limitations[], parameters, raw_result, normalized_result}`.
Errors are a different envelope: `{code, category, message, retryable, remediation, details}`
(MEASURED: sqlite on node 24.14 -> `capability_unavailable` / `unsupported_provider`).

| Phase A file (op)                                | size   | useful payload                                                                                                                                                                 | projection -> table                                                                               | MEASURED rows                                                                       |
| ------------------------------------------------ | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| a_objdump_symbols (inspect-with-objdump symbols) | 667 KB | `normalized_result.stdout` = objdump `-t` text, `exit_code` 0, `completion_status` complete                                                                                    | `symbols.csv` addr,scope,type,section,size,name (awk over stdout lines matching `^[0-9a-f]{16} `) | 4748 (1514 `g F .text`)                                                             |
| objdump file_headers                             | 2 KB   | stdout: format, arch, flags, start address                                                                                                                                     | `artifact.csv` one row (key,value)                                                                | 4 keys                                                                              |
| a_inspect_artifact (inspect-artifact)            | 5.5 KB | `observations[]{kind,subject,value}`, `next_probes[]{operation,rationale}`, `coverage{...}`, `limitations[]`                                                                   | `observations.csv`, `probes.csv`, `limitations.csv`                                               | 1 obs (root-manifest), 1 probe (`open_binary`), coverage `complete-within-substeps` |
| b_js (analyze-javascript-application, semver)    | 12 MB  | `normalized_result.graph.{nodes[159],edges[429]}`, node `{node_id,kind,identity.key}`, edge `{relation,source_node_id,target_node_id,evidence.state}`; `summary`, `statistics` | `js_nodes.csv` kind,key ; `js_edges.csv` relation,src_kind,source,dst_kind,target,state           | 429 edges: imports 270, contains 100, exposes 56; state inferred 330 / observed 99  |
| c_sqlite (inspect-sqlite-database)               | 1 KB   | error envelope only                                                                                                                                                            | `errors.csv` op,code,category,message                                                             | 1                                                                                   |

Field mapping to the corpus vocabulary the plan named:

- **functions** = `symbols.csv` where type=`F` (objdump provider; no Ghidra/rizin on c05, so no
  decompiled bodies -- names, addresses, sizes only).
- **strings** = NOT produced by any engine-free op measured in Phase A. Gap, recorded; plan 02
  may add `strings -n 6` as a sibling file, but it is not rea Evidence and is labelled so.
- **imports / libraries** = native: objdump `-p` NEEDED (bin2md is static: 0 NEEDED, MEASURED) ->
  `imports.csv`; JS: `js_edges.csv` relation=`imports`.
- **modules** = JS `js_nodes.csv` kind=`javascript-module` (105) / `javascript-asset` (49).
- **unknowns** = kept as rows, never dropped: `limitations[]` -> `limitations.csv`, edge
  `evidence.state` (`inferred`/`observed`/`unknown`/`literal`/`union`) as a column, error
  envelopes -> `errors.csv`. Postmortem lesson: unknown is a result value, not an error path.

:decision: the projection keeps rea's `evidence_id` and `subject.digest.sha256` on every produced
file's sidecar row (manifest), so a prg answer cites back to one Evidence record.
:rejected: flattening `authority`/`confidence` into each row -- they are per-record, not per-row;
one manifest row per record carries them.

## 3. C.2 -- the producer

:decision: `rea.sh PATH [DIR]` -- a bash script in `cluster/.github/skills/rea/`, shape copied
from purl.sh: no DIR -> `$PURL_HOME/rea_<basename>_<hex8>/` (hex8 = sha256 of the artifact
bytes, so a rerun on the same binary re-syncs the same dir and two binaries never mix);
never `/tmp`. Stdout = one summary JSON `{src:"rea",path,dir,ops,files,errors,corpus}`; manifest
`rea.prg.jsonl` one row per op `{op,evidence_id,sha256,authority,confidence,file,rc,t}`.
:rejected: inline in prg-ask.sh -- prg-ask already routes non-folder SOURCE to purl; a second
producer hard-wired there doubles the routing. Instead plan 02 adds rea to `purl.sh intent`
routing (a binary PATH -> `rea.sh`), so prg-ask stays unchanged.

:decision: CLI + files, not MCP (confirms the plan's Frontier). Phase A needed 4 single
calls; no multi-call workflow appeared that one CLI call cannot express.
:rejected: `rea mcp` client inside prg -- new runtime for the same JSON.

:decision: tables as **CSV**; the raw Evidence kept as `<op>.rea.prg.json`.
MEASURED in `/tmp/rea01/proj`: `bin2md --corpus` (0.12 s, 4 files) turned `symbols.csv` into a
clean typed table (`SELECT ... WHERE scope='g' AND type='F'` works); a `.jsonl` of observations
became cell rows of JSON text split at commas (`obs_jsonl` count 0 usable rows); a raw `.json`
became one wide table with an `evidence_id_ev_<hash>` column name. In `proj2`, naming the raw
file `*.rea.prg.json` made bin2md skip it (2/2 converted, only the CSV tables).
:rejected: JSONL projection -- bin2md reads it as text, not records.
:rejected: feeding raw rea JSON to bin2md -- 12 MB graph JSON as one table is noise.
:rejected: markdown projection of tables -- CSV gives SQL columns; markdown only gives blocks.

:decision: which ops run is decided by `rea capabilities --json` on the box plus `file PATH`:
ELF/PE/Mach-O -> inspect-artifact + inspect-with-objdump {file_headers,symbols,dynamic};
dir/asar/.js -> analyze-javascript-application; .dll (.NET) -> inspect-managed-artifact;
sqlite -> inspect-sqlite-database (error row on node < 24.15). An unavailable provider writes
an `errors.csv` row, never a silent skip.
:rejected: a fallback chain (try Ghidra, then rizin, then objdump) -- rea itself removed
fallback selection ("no fallback", postmortem); rea.sh mirrors it: one provider per op.

:decision: parse objdump `stdout` with awk in rea.sh (rea returns it verbatim in
`normalized_result.stdout`). :rejected: patching rea to emit structured symbols -- Frontier
says read rea, do not fork it; revisit if plan 02 measures awk misparsing (e.g. names with spaces).

## 4. Known gaps / open

- :open: node 24.14 < 24.15 blocks sqlite inspection fleet-wide (Phase A); separate R-ALLBOX plan.
- :open: no `strings` op without an engine; decide in plan 02 whether a non-rea sibling file is OK.
- :open: 12 MB JS Evidence for a 50-file package -- plan 02 measures size on a real .asar and
  may need `rea inspect-analysis-view` projection before jq.
- JS node identity keys are digests (`<sha>:functions/lt.js`); plan 02 strips the digest prefix
  into a `path` column so TERM can match by file name.

## 5. Draft plan 02 skeleton (phases only; written as `02.rea.producer.org.txt` when started)

    * Phase A -- rea.sh PATH [DIR]: capabilities gate, op table by `file`, run ops, write
                 rea.prg.jsonl manifest + *.rea.prg.json raw.          :test_tool: bash test/rea.test.sh
    * Phase B -- projections: symbols/imports/artifact/observations/probes/limitations/errors CSV,
                 js_nodes/js_edges CSV.   :test_tool: bin2md --corpus DIR; each table count > 0
    * Phase C -- routing: purl.sh intent maps a binary PATH to rea.sh; prg-ask unchanged.
                 :test_tool: prg-ask.sh /usr/local/bin/bin2md "which symbols does it export" cites symbols.csv
    * Phase Z -- E2E (= plan 01 Z.1 made permanent): answer checked against `objdump -p` / `nm -D`;
                 cluster skill rea/SKILL.md "Use today" switches to rea.sh.
