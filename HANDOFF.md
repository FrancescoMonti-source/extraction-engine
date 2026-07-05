# Collaboration & handoff log

This repo is the **shared coordination layer** between two assistants (Claude,
GPT-5.5) and the human owner. It exists so neither model depends on its own chat
memory — anyone can re-enter cold by reading `DESIGN.md` and this file.

## Protocol

- **Roles.** The human owns product & clinical decisions. Claude and GPT-5.5
  **both draft and both review** (mutual, not one-directional). The human is the
  relay between the two models and the decision-maker.
- **Source of truth.** `DESIGN.md` = target architecture and vocabulary
  (§16 = deferred capabilities gated on a consumer). `HANDOFF.md`
  (this file) = the review/coordination frame and chronological log.
- **Handoff format** (every exchange): *Goal & acceptance criteria · proposed
  change + reasoning · files changed · open questions/uncertainties.*
- **No rubber-stamping.** State disagreements explicitly with the tradeoff.
  Responses land **in the repo** (update `DESIGN.md` or append a log entry here),
  not only in chat — so the decision and its reasoning survive compaction.
- **Decisions** get recorded in `DESIGN.md` when they change the target
  contract (including §16 when they only shift a deferred capability's
  status or consumer), once the human accepts them.

---
> Closed history (2026-06-19 → 2026-06-30: design reviews, prototype, migration
> slices, test pruning) lives in [`HANDOFF-archive.md`](HANDOFF-archive.md).
> This file starts at the target-contract era (2026-07-01).

## Executor overhaul + CCAM act_channel + prototype purge -- Claude (2026-07-01)

Big session on the `channel-shape` branch (11 commits, green throughout, ending at 68 tests).
Two threads: a scaffolding purge, then the source-roles/channel-shape build.

**Framing established (memory `product-is-the-engine-not-concepts`):** this is NOT a clinical
study. The product is the generic concept-agnostic engine (DESIGN §1). Everything
concept-specific -- `R/concepts-*`, `R/adapter_*`, `R/types/*`, `scripts/*_real.R`,
exploration scripts -- is removable scaffolding, kept only while it validates the engine.

**Purged (~2,100 lines):** the pre-`run_variable` prototype run path -- `scripts/run_structured.R`
+ the `measure_diabetes`/`measure_hyperkalaemia` clinical wrappers + `concepts-hyperkalaemia.R`
+ the `run_structured_measurement`/`.structured_execution_error`/`build_structured_review_view`
helpers; `scripts/run_synthesis.R` (text-side twin, bypassed run_variable) + its orphaned
`build_review_view`; 7 concluded round/phase exploration scripts. Folded each concept's Lucene
query into its concept file and deleted `adapter_smoking.R` (kept `adapter_anastomoses.R` for
its still-used `load_tasks`; deleted its orphaned `_eligibility`). `scripts/` is now just the
3 `run_variable_*_real.R` validation runs + `check_grammar_enforcement.R`. `run_variable_*_real`
are the real-model-on-real-data validation harness (they ARE the validation story; the unit
suite is only tripwires) -- kept while validating, will collapse to one generic driver later.

**Executor overhaul (structured.R 575 -> 402):** internalized channel `produces`; collapsed the
whole-history code executor into a window-optional `measure_code_presence`; then made it
source-agnostic and added the CCAM/act path (owner: "ccam channel is a must have, I filter on
$CODEACTE"):
- Matching is now **exact (a code set) or regex (per-pattern)**, replacing prefix-only
  `code_in_family`. Codes normalized (dots/spaces stripped). `icd10()` takes a regex (DESIGN's
  `icd10("^E1[0-4]")`) or `match="exact"`; new `ccam()` defaults exact. Concept selectors
  migrated (diabetes `icd10("^E1[0-4]")`, dialysis `match="exact"`).
- **Dropped `.usable_icd10_code` + the usable/invalid/field_validity/n_usable apparatus for
  codes** -- HDW codes are standardized by redsan, so usability checks are cruft (the LLM
  accept-only-valid pattern leaking onto deterministic channels; memory
  `hdw-standardized-no-validity-checks`). It was also the ICD-10 coupling blocking CCAM.
- **Role-aware:** `data.R` gains `ACTE_SOURCE` (pmsi$actes: CODEACTE=code, point DATEACTE) and
  `EE_SOURCES` (channel-source-name -> spec registry). `.code_source_binding()` resolves the
  code column + point/interval time from the source's roles; unregistered sources fall back to
  the pmsi$diag shape. `pmsi$diag` output byte-compatible; `code`/`act` share one dispatch arm.
- Params renamed: `source_table`, `code_col`/`start_col`/`end_col`. New floor-worthy test
  `test-slice-act-channel-spec.R` (CCAM exact match over synthetic pmsi$actes, point window).

**Open follow-ups (none blocking):** (1) lab usability -- `measure_analyte_value`'s
`usable = !is.na(value)`/`invalid` is the same cruft (numeric in NUMRES, qualitative in STRRES
which BIOL_SOURCE doesn't read); mirror the code cleanup. (2) output-constructor aliases --
concepts still use legacy `binary_output`/`categorical_output`/`fields_output`; migrate to
`bin_output`/`cat_output`/`struct_output` then delete the aliases (+ `llm_after_lucene(top_n)`
-> `candidate_selection`). (3) rename `measure_analyte_value`'s first param for parity.
The `channel-shape` branch now carries the whole overhaul -- worth merging as one unit before
the next thread.

---

## 2026-07-01 -- lab executor cleanup, plain-function reducers, output-vocab migration

Continuation on `channel-shape` (five commits, suite green at **68** throughout). Closes all
three open follow-ups from the entry above.

**Lab executor de-crufted (`8b2c6c7`):** removed `measure_analyte_value`'s
`usable = is_target & !is.na(value)` / `invalid` apparatus (+ `field_validity`/`validity_reason`/
`n_usable`/`n_unusable`) -- the same standardized-HDW cruft stripped from the code path (numeric
results are NUMRES, qualitative are STRRES which `BIOL_SOURCE` doesn't read, so `!is.na()` guards
nothing). Also deleted the now-orphaned `threshold`/`above_threshold`/`n_above`/present-absent
machinery: hyperkalaemia was deleted and `run_variable` never passed a threshold, so it was all
dead. Memory `hdw-standardized-no-validity-checks` updated (lab now done, not pending).

**Reducer is a plain function, not an operator (`8947670`):** owner -- *"i dont want ad hoc
functions for trivial stuff when i could just ask the reduce of the lab channel to do
`function(x) max(x, na.rm=T)`"*. `max_value()` was **decorative**: the lab dispatch ignored the
declared reducer and hard-coded `max` in the executor. Now:
- `measure_analyte_value` -> **`measure_analyte_values`**: it SCOPES candidate rows and returns
  `candidates` (`task_id, source_row_id, value`); it does NOT reduce.
- `.single_numeric_variable` pulls the channel's **reducer function** off the activation
  (`use_channel(reducer = function(x) max(x, na.rm = TRUE))`) and applies it to the candidate
  values; a numeric output with no reducer function errors.
- Deleted `max_value()`. `min`/`mean`/`latest`/`count` now need no operators -- they are base R.
- **Evidence = every in-window candidate** (the inputs the reducer saw), because the executor is
  reducer-agnostic (a generic `function(x)` picks no row; `mean` matches none). Diabetes slice
  test updated to assert both glucose rows are evidence; value `9.4` still `max(6.1, 9.4)`.
- Memory: new `reducers-are-plain-functions`.

**Output constructors migrated + aliases deleted (`2000601`):** the four concepts now call
`bin_output`/`cat_output`/`struct_output` directly; the legacy
`binary_output`/`number_output`/`categorical_output`/`fields_output` aliases are **removed**.
Internal `$kind` (binary/number/categorical/fields) unchanged, so runner dispatch is untouched.
`spec.R`'s hit-set error message + MIGRATION.md updated.

**Dead `top_n` deleted (`003b4a7`):** `llm_after_lucene(top_n=)` was set-but-not-read (text is
pre-retrieved; nothing read `$top_n`). Per defer-infra the owner chose to DELETE it rather than
carry it or replace it with another unread seam. `llm_after_lucene()` now takes no argument. The
target selection helper is named **`llm_candidate_selection()`** (owner renamed it off the design
doc's `candidate_selection()` to avoid ambiguity with the new STRUCTURED `candidates` frame); it
is **reserved, not built** -- add `candidates = llm_candidate_selection(arrange, limit)` inside
the method only when retrieval runs in-engine and has a consumer. Recorded in
`proposed-design-v2-deltas`.

**Param parity (`66f2246`):** `measure_analyte_values`' first param `biol` -> `source_table`
(matches `measure_code_presence`); internal transmuted frame stays `biol`.

The `channel-shape` branch is ready to land as one unit; no open follow-ups outstanding from
this thread.

---

## 2026-07-01 -- Boolean-envelope demotion (drop decision / decision_state / public role)

Closes the MIGRATION.md "Boolean envelope" row; also reconciles the now-stale "Channel shape"
row (which channel-shape had already completed). Suite green at **68** throughout. The target
was already ratified in DESIGN.md (`§ boolean output`, lines ~940-991) and memory
`combine-output-naming-target-contract` -- this ships it, DESIGN needed no change.

**What the public boolean surface now is** (DESIGN §"Downstream contract" / "Overlap audit"):
- `values`: `task_id, variable, value (0/1), channel_coverage`. Dropped `decision`
  (included/excluded) and `decision_state` (always "determined"). Rationale: observed set
  algebra is always determined, and included/excluded is a *presentation recoding* of `value`
  for cohort selection, not a generic engine field. Uncertainty lives in `channel_coverage`.
- `channel_status` / `membership` / `evidence`: dropped the public `role`
  (asserted/negated/mixed) column. A channel observes only its own hit; its logical position
  in the expression lives in `combine_rule`, not as a per-channel property.
- `overlap`: now groups on the pattern-determined **`value`** (0/1) + `channel_coverage`
  instead of `decision` + `decision_state`. Still one row per membership pattern, NA preserved,
  ggupset/UpSetR-pivotable.

**Dead code removed with its only consumer** (`defer-infra-until-consumer`): the polarity
`roles` field on the `hit_set_expr` combiner (`operators.R`) fed *only* the public `role`
column via `role_of()`. Both gone, and the orphaned `.hitset_expr_roles()` walker in
`hitset.R` deleted. `hit_set_difference()` builds `a & !b` strings directly (never used the
walker), so sugar-lowering is unaffected. DESIGN §989 still reserves internal polarity
derivation for a future sugar consumer -- re-derive from the AST if one appears.

**Not a public-surface change but touched:** `hit_set_overlap()` signature
`(wide, channels, decision, decision_state, channel_coverage)` -> `(wide, channels, value,
channel_coverage)`.

**Channel-shape row reconciled:** `produces` is already derived from the channel `type` inside
the `channel()` constructor (never user-written; read once at assembly for `selected_channels`),
and `act_channel()` + `ccam()` over `pmsi$actes` ship. Both of that row's tasks were done on
channel-shape; MIGRATION.md just hadn't been updated.

**No test churn:** `test-slice-hitset-expr-spec.R` already asserted only `value` +
`channel_coverage` + raw `membership$hit` (its header even said "without exposing migration-era
decision_state/role"), so the floor test proves the demotion without edits. `mean(value)`
semantics unchanged.

**Files:** `R/hitset.R`, `R/operators.R`, `R/run_variable.R`, `MIGRATION.md`, `HANDOFF.md`.

---

## 2026-07-01 -- Source-roles: prune dead legacy_roles + reconcile the row (lab binding deferred)

Investigated the MIGRATION.md "Source registry and roles" row (owner thought it was already
done; it was *mostly* done). Findings, then a scoped cut. Suite green at **68**.

**State found (most of the row had already landed):** `source_spec()` carries the canonical role
map (`subject_id`/`event_id`/`source_item_id`/`code`/`analyte`/`value_num`/`value_str`/`date`/
`event_start`/`event_end`/`document_type`/`source_result_id`); `EE_SOURCES` registers docs/diag/
actes/biology; and the **code/act executor is fully role-driven** -- `.code_source_binding()`
([run_variable.R]) resolves the code column + point/interval time from the source's roles, which
is exactly why `pmsi$diag` (code col `diag`) and `pmsi$actes` (code col `CODEACTE`) share one
`measure_code_presence()` executor.

**The `legacy_roles` apparatus was fully dead** and was removed (owner picked "prune + reconcile
only"): nothing called `source_roles(..., include_legacy = TRUE)`, so the migration-era alias
labels (subject/event/record/interval_start/... ) had zero consumers. Deleted the `legacy_roles`
param on `col()`, the `legacy_roles` field on the col struct + on `source_spec`, the
`include_legacy` branch in `.source_role_map()` and `source_roles()`, and all `legacy_roles = ...`
declarations across DOCS/DIAG/BIOL/ACTE sources. `col()`/`source_roles()` are now single-purpose.
Migration to the target vocab is complete, so the inspectable back-compat labels earned nothing.

**Deferred, with the reason recorded in the row (`defer-infra-until-consumer`):**
- `.lab_source_binding()` -- the lab executor `measure_analyte_values()` still names biology
  columns directly (`DATEXAM`/`analyte`/`value`/`value_raw`/`BIOL_ID`). The code path is
  role-driven because it *had* to be (two coded sources, different code columns); biology has a
  **single source**, so there is no second consumer forcing role-resolution. Add the binding
  when a second biology source appears. NOT built speculatively.
- Source-registry auto-seeding: NOT a thing. `redsan` (v0.1.0) exposes only `get_edsan`,
  `process_pmsi`, `process_biol` -- there is no source-registry API to seed from, and auto-seeding
  is not planned. Source specs are and stay hand-declared (`EE_SOURCES`).

**Design note:** output frames deliberately keep physical/runner column names. "Executors consume
roles" means the executor resolves physical names *from* the spec's roles (as the code path does),
NOT that normalized frames get renamed to role names. The other declared-but-unread source_spec
metadata (`module`/`table`/`identifiers`/`query_date_keys`/`default_batch_key`/`normalizer`) was
KEPT -- DESIGN §4 enumerates it as legitimate redsan-shaped source metadata, unlike the
migration-only `legacy_roles`.

**No test churn:** `test-slice-source-spec-roles.R` already asserted the role→column map with
target names only (no legacy path), so it proves the map still resolves after the prune.

**Files:** `R/data.R`, `MIGRATION.md`, `HANDOFF.md`.

---

## 2026-07-01 -- LLM boundary: investigated + reconciled the row (already functionally satisfied)

Investigated the MIGRATION.md "LLM boundary" row (same pattern as source-roles: find out how much
is already satisfied before touching anything). Verdict: the who-owns-what boundary is **already
implemented and shipped on both sides**; the row's "align method declarations and provenance" is
purely a declarative-surface refactor that duplicates the Text-method row's deferred work. Doc-only
reconciliation, no code. Suite green at **68**.

**Boundary mapped against the code (every responsibility is already in place):**
- *ellmer owns* the structured call (`make_ollama_caller` -> `chat$chat_structured(prompt, type)`)
  and type validation/parsing (`ellmer::type_from_schema()` builds the type; ellmer validates the
  response and returns a parsed R list).
- *engine owns* everything else via the per-task-isolated `run_extraction` loop: candidate
  selection (text pre-retrieved), prompt rendering (`prompt_builder`), evidence-ID validation
  (`resolve_cited_ids()` real-vs-invented + `.materialize_task_evidence()` exactly-one-snippet
  assert), response-to-hit mapping (parser `normalized_value` `documented`->`present` ->
  `.reduce_channel_result` -> `isTRUE(r$hit)`), and provenance (`attempts`: model/seed/
  prompt+schema+query hashes/finish-reason/raw response, plus evidence + `channel_status`).

**Two confirmations that pin down "nothing to build here now":**
- `llm_after_lucene()` / `method` is **set-but-not-read at execution** -- grep of
  run_variable/channel-combine/extract found zero reads. The text arm dispatches on
  `channel_def$type == "text"` and consumes `extractor` (the definition bundle), never `method`;
  `method` is surfaced only by `inspect()`. Reserved declarative surface (like `produces` was),
  NOT dead alias apparatus like `legacy_roles` -- so it stays (it's the documented public tag).
- `positive_hit_when` exists **only in DESIGN.md/HANDOFF.md, never in `R/`**. Response-to-hit
  mapping is presently the binary parser's `documented`->`present`->hit.

**The only unaligned part (deferred, `defer-infra-until-consumer`):** DESIGN §488 wants the
method-specific knobs (`prompt`/`type`/`candidates`/`positive_hit_when`) folded INTO the
`llm_after_lucene(...)` signature instead of the `definition`/`extractor` bundle. That is the SAME
reserved-not-built work as the Text-method row -- gated on in-engine retrieval + a consumer.
`positive_hit_when` in particular is only worth building when a variable needs a response-to-hit
mapping the parser doesn't already bake in. No consumer today, so not built.

**No test churn:** doc-only reconciliation of the MIGRATION row; execution paths untouched.

**Files:** `MIGRATION.md`, `HANDOFF.md`.

---

## 2026-07-01 -- Whole-history text: generic no-window subject eligibility (validated by a disposable variable_spec)

Owner named a consumer (whole-history depression) to unblock the "Whole-history text" row. Two
corrections mid-slice (owner): (1) do NOT build a depression concept -- "whole-history depression"
is JUST a `variable_spec` a study author writes; the engine only needs the GENERIC capability, and
the validating variable_spec is a **disposable test probe**, not shipped machinery. (2) Apply the
prune-tests filter to the probe: the first draft added 7 assertions; only ONE survives the filter
(see below). Suite green at **69** (68 -> 69, +1 assertion; no regressions).

**Generic engine change (the only real gap):** `.retrieve_text_channel` handled event-linkage and
subject+window, but *errored* on subject-linkage with no window. Added a whole-history branch: no
window -> scope the subject's ENTIRE document record (join `docs_index` by `PATID`, no `RECDATE`
filter), the text mirror of the whole-history code path. Whole-history tasks carry no `anchor_date`,
so none is joined (it rides through `retrieve()` as an NA `days_from_anchor` ranking column,
meaningless here). Nothing concept-specific.

**Validation = a disposable variable_spec run through the public surface:** the whole-history slice
test ([test-slice-whole-history-spec.R]) poses a whole-history TEXT demand as a variable_spec
(`window = NULL` over the EXISTING diabetes text channel) + a corpus fixture + fake caller, and runs
it via `run_variable()`. This mirrors the existing whole-history *structured* `wh_variable()` probe.
The variable_spec is test-local -- no concept/template added to `R/`.

**Pruned to the one distinguishing invariant:** the single assertion is `value[["Q4"]] == 1L` for a
subject whose ONLY note is from 2005 -- reachable only when the whole record is in scope (a broken or
reverted no-window branch errors or applies a window that drops the note -> value 0; `value == 1`
also implies real grounding, since binary presence is invalid without a resolved evidence id). The
first draft also asserted recent-mention->present, no-document->`partial`, and evidence-ref grounding;
all three duplicate invariants already guarded by `test-slice-retrieval-wiring.R` and the structured
whole-history test above, so they were cut per [[prune-tests-to-target-invariants]].

**Discipline reaffirmed:** validate an engine capability by writing the throwaway variable_spec a
user would write (TDD from the public surface), NOT by shipping a concept. The variable_spec reveals
the true generic gap; if it had run green untouched, the row would have been already-satisfied.

**Files:** `R/run_variable.R`, `tests/testthat/test-slice-whole-history-spec.R`, `MIGRATION.md`,
`HANDOFF.md`.

---

## 2026-07-02 -- Alignment audit: working model had drifted from DESIGN.md (owner asked to check)

A long design conversation (grain/level naming, per-channel "what counts as a hit" predicate,
`index_event` derived anchor, channel-override at the variable_spec). Before capturing it as
"decisions," audited against DESIGN.md -- and found MOST of it is ALREADY the ratified contract; I had
drifted by reasoning from the CODE (where these are dead/unwired) instead of DESIGN, and told the
owner "unit is dead" when DESIGN says the opposite. Owner was right to be surprised. No engine code
written; this entry + memories are the deliverable.

**Already specified in DESIGN, code lags (the gap is wiring, not design):**
- **unit IS the grain** -- §7 "Grain is the `unit`", first-class, takes the group-by
  (`unit = "PATID"` / `transplant_unit()`). Code: `unit` set-but-not-read, grain implicit in the
  tasks frame.
- **local selector/field override at activation** -- §14.3 (the owner's exact type-2 example) +
  "any field in `use_channel()` replaces the inherited field; a supplied selector replaces it
  locally, does not mutate the concept." Code: selector read from `channel_def`, not the activation.
- **lab hit-predicate** -- §8: unthresholded lab = presence hit; `analyte_value("GLU.GLU", gt = 11)`
  = threshold hit. A target, not banned -- only the dead impl was removed (memory
  `hdw-standardized-no-validity-checks` corrected accordingly).
- **event-derived anchor** -- `anchor = transplant_date()` / `surgery_date()` already derive a date
  from an event.
- **event/stay-grain structured executors** -- §7 (~line 570) explicitly names this as THE current
  migration gap (text resolves event scope; code/lab don't). = the "Event/stay grain" MIGRATION row.
- **grain-agnostic combine over mixed channels** -- §7 `combine = "text_diabet & glucose"` means
  different things at patient vs stay grain -- essentially the diabetes AND example, already in the doc.

**Genuinely new (not generic in DESIGN):** `index_event` -- a GENERIC derived anchor (find the event
matching a code selector, anchor at its date-role), generalizing the domain constructors
`transplant_date()`/`surgery_date()`. Single-match for now (multi-match -> `candidate_selection`).
Prerequisite is a redsan change (denormalize the stay envelope onto `$diag`/`$actes`), then
`ACTE_SOURCE` declares `event_start`/`event_end`. Details + date-typing caveats in memory
`index-event-derived-anchor`.

**Naming (decided after the audit):** output-grain axis renamed `unit`->`output_one_row_per` (frees
`unit` for the measurement unit) -- DESIGN's "Grain is the `unit`" made explicit; rationale is the
fill-and-tweak boilerplate-R-snippet authoring model (memory `variable-spec-boilerplate-explicit-names`).
Channel attachment (`linkage`) named `level` (ratified 2026-07-02).

**Takeaway (memory `design-is-source-of-truth-code-lags`):** read DESIGN before proposing engine
"design"; the gap is usually the code lagging the contract.

**Files:** `HANDOFF.md`; memories `design-is-source-of-truth-code-lags`, `index-event-derived-anchor`,
`hdw-standardized-no-validity-checks`, `MEMORY.md`.

---

## 2026-07-02 -- Reduce/combine composition + deferred `where` filter axis; naming ratified

Clarified (grounded in DESIGN §8 validity matrix) that `reduce` and `combine` NEVER co-occur in one
variable: `combine` produces 0/1 (bin) only; a `num`/`str`/`cat`/`struct` output needs
`combine = NULL`. So "mean Hb for the text&lab-anemia cohort" is TWO independent columns -- a
`bin`+combine cohort and a `num`+reducer value -- composed by a DOWNSTREAM row-filter
(`value[cohort == 1]`), NOT a spec sequence/dependency (that fear was a misread; the columns are
independent). Corrected my own earlier framing: "combine-gated numeric" is NOT a missing capability;
DESIGN excludes it on MECHANICS -- the §8 validity matrix makes `combine` 0/1 (`bin`) only -- NOT
because cohorts are out of scope (they are core: inclusion + extraction IS the engine's job; §955
names cohort *selection* as the use-case `value` serves; §15's out-of-scope item is cohort
*governance*). [corrected 2026-07-02, see below] The lab side of the cohort
still needs the §8 lab hit-predicate (`analyte_value(gt/lt ...)` → hit), which IS the real unwired gap.

Owner WANTS the one-spec form eventually -- `num_output(mean Hb) where (text_anemia & lab_anemia)`, a
`where`/filter axis -- but is HOLDING it (two-column pattern works; add when it hurts). Recorded as a
deferred design axis: memory `where-filter-dimension-deferred`.

Naming ratified: **`output_one_row_per`** (output grain, frees `unit` for measurement unit) +
**`level`** (per-channel attachment, was DESIGN's `linkage`).

**Files:** `HANDOFF.md`; memories `where-filter-dimension-deferred`, `variable-spec-boilerplate-explicit-names`,
`design-is-source-of-truth-code-lags`, `MEMORY.md`.

---

## 2026-07-02 -- Engine scope clarified + channel-override at activation shipped

**Scope correction (owner).** We ARE doing electronic-cohort work -- **inclusion (who qualifies) +
data extraction (what values) is the engine's whole job.** Out of scope is the layer ABOVE: analysis,
cohort GOVERNANCE, study-lifecycle/platform (DESIGN §15: "a higher research platform may later use this
engine"). I had drifted and written "cohort selection is out of scope" (memory + the HANDOFF line
corrected just above): that misread §15 (which lists cohort *governance*, not selection) and §955
(which names cohort *selection* as the very use-case `value` serves; §1193 treats cohort membership as
first-class engine correctness). Consequence: the deferred `where` axis is held on **mechanics**
(combine->0/1), not scope -- gating a value by an inclusion is squarely our job. New memory
`engine-scope-inclusion-and-extraction`.

**Slice: channel-override at activation (DESIGN §14.3).** `use_channel(selector = ...)` now locally
overrides a concept's baseline channel selector for ONE variable, without mutating the concept. The
execution path (`.run_selected_channel`) already did inline `activation %||% concept` for `extractor`;
`selector` now follows the SAME pattern -- resolved ONCE at the top and used by every branch
(code/act/lab/text extraction), AND threaded into `.resolve_text_inputs`/`.retrieve_text_channel` so a
text override applies to BOTH retrieval and extraction. (A half-applied selector would retrieve on the
baseline query but match/extract on the override -- a silent correctness bug; that's why the seam is
uniform, not just the code branch the probe exercises.) `selector` promoted to a first-class
`use_channel()` param (was riding `...`), per boilerplate-explicit-names + DESIGN §14.3's own
`use_channel(selector = lucene_query(...))`.

NB the earlier plan ("wire through `.inherit_from_activation` like reducer/extractor") was modeled on
the WRONG path: that helper feeds only `inspect()`/`resolve_variable_spec`; the EXECUTOR reads the
concept channel directly and resolves overrides inline with `%||%`. Followed the code, not the memory.

**Probe (disposable, in-test).** One E13 subject; same spec run twice -- baseline `icd10("^E1[0-4]")`
hits (1), local override `icd10("^E1[0-2]")` misses (0). The contrast is the only proof the activation
selector -- not the concept's -- drove the executor. Suite 69 -> 71 (one test, two discriminating
assertions; passes the prune filter -- no other test protects the §14.3 override invariant).

**Files:** `R/spec.R` (use_channel selector param), `R/run_variable.R` (uniform selector resolution +
text threading), `tests/testthat/test-slice-channel-override-spec.R`, `HANDOFF.md`; memories
`engine-scope-inclusion-and-extraction`, `where-filter-dimension-deferred`,
`design-is-source-of-truth-code-lags`, `MEMORY.md`.

---

## 2026-07-02 -- Event/stay-grain structured executor (code/act): EVTID scope + numeric count

Closes the code/act half of the DESIGN §7 (~line 570) executor-wiring gap. `measure_code_presence`
(the neutral code + act membership executor) now does two additive things:

1. **Stay-grain scoping.** Grain comes from the SUPPLIED TASK UNIVERSE (DESIGN §7: "one output row
   per unit in the supplied task universe"), and it is carried PER TASK -- each task row says which
   subject AND which stay it is. So when the tasks frame carries a non-NA `EVTID` (stay grain), the
   executor scopes evidence by `c(PATID, EVTID)` instead of `PATID` alone; patient-grain tasks (no
   EVTID column) keep the subject-only join. `source_counts`/coverage group by the same `grain_keys`.
   Important framing: the engine does NOT group-by a column internally -- the caller supplies tasks
   pre-grained (one task_id per unit) and the executor scopes each task's evidence; the per-task
   reducer is the "summarise within grain."

2. **Numeric count over a structured channel.** The executor now also returns `candidates` (one row
   per matching source row, `value = 1L`). A `num_output()` over a code/act channel with
   `use_channel(reducer = function(x) length(x))` then counts them via the EXISTING numeric assembly
   (`.single_numeric_variable`). No bespoke count operator -- "reducers are plain functions"
   (`length`/`sum` both give the count). The membership face (`values`: present/absent) is unchanged;
   both faces ride the same result list.

**Probe (disposable, in-test).** Patient P1, two stays: EV1 = 2 matching CCAM acts (JAFA001) + 1 decoy
(HGPC015); EV2 = 1 matching act. Stay-grain tasks (`window = NULL`, event-scoped). EV1 counts 2, EV2
counts 1 -- a PATID-only join would give BOTH 3 (each stay would see all of P1's matches), so the
values are the proof of EVTID scoping; the decoy proves count = matching-and-in-stay. Suite 71 -> 73.

**Decisions / deferred (flag for ratification):**
- **`output_one_row_per` NOT wired this slice.** Grain is task-frame-driven (the correct locus: each
  task carries its own subject+stay), so no param is needed for the executor to scope correctly.
  `unit` remains stored-but-unread. Renaming `unit`->`output_one_row_per` AND giving it a job (a
  validation guard: "the task frame's task_id is 1:1 with the declared grain column, and carries it")
  is a clean SEPARATE slice -- doing the rename now is label->column churn across ~8 disposable test
  files without a consumer. Recommend deferring; easy to add.
- **Lab executor still PATID-only.** `measure_analyte_values` needs the identical `grain_keys` change
  for stay-grain labs; deferred (no lab-stay-grain consumer/probe yet -- avoid untested code). A
  mixed code+lab variable at stay grain would currently scope code by stay but lab by subject; no such
  variable exists yet, and the first one written would catch it via its own probe. Documented so it's
  not forgotten.
- **Count of an empty stay = NA, not 0.** `.single_numeric_variable` short-circuits empty candidates
  to NA/partial (right for max/mean, debatable for count). The probe only asserts non-empty stays.
  Count-identity (0-fill) is a deferred question; a fix would let the reducer own the empty case
  (always call it) but that touches the max-glucose NA expectation -- out of scope here.

**Files:** `R/structured.R` (grain_keys scoping + candidates return),
`tests/testthat/test-slice-event-stay-grain-spec.R`, `HANDOFF.md`; memory
`design-is-source-of-truth-code-lags`.

---

## 2026-07-02 -- `output_one_row_per` wired: grain is a declared, guarded, executor-driving axis

Gives the output-grain axis a real job (was `unit`, stored-but-unread). `variable_spec(unit=)` is
RENAMED to `variable_spec(output_one_row_per=)` -- a concrete grain COLUMN (default "PATID"), e.g.
`output_one_row_per = "EVTID"` for stay grain. This is DESIGN §7's "Grain is the `unit`" made explicit
and, per the ratified naming, frees `unit` for the measurement unit (`analyte_value(unit=)`).

Three things now hang off it:
1. **Drives structured scoping.** `run_variable` computes `grain_keys = unique(c("PATID",
   output_one_row_per))` and threads it to `measure_code_presence` (which lost its EVTID column-
   sniffing from the previous slice -- the declaration is now authoritative, one source of truth).
   "PATID" -> subject scope; "EVTID" -> `c(PATID, EVTID)` stay scope.
2. **Guarded.** `.check_output_grain` (in `run_variable`, up front) enforces DESIGN §7's linkability
   check: the grain column(s) are present in the tasks frame, non-NA, and the grain-key combination
   is UNIQUE across tasks (one output row per unit -- 1:1 task<->unit). Clear errors otherwise.
3. **Lab loud-guard.** `measure_analyte_values` is still PATID-only, so the lab branch now ERRORS if
   run at non-PATID grain rather than silently mis-scoping (subject labs leaking into every stay).
   Converts the deferred-lab gap from a silent-wrong into a loud-unsupported.

Framing kept straight: the engine does NOT group-by a column internally. The caller supplies the task
universe already at grain (one task_id per unit); `output_one_row_per` DECLARES which column that is,
drives evidence scoping, and is validated against the frame. The per-task reducer is the "summarise
within grain."

**Migration:** all 14 `unit =` call sites -> `output_one_row_per =`. Every one was a patient-grain
fixture (the "surgery"/"transplant" labels were the ANCHOR event, not the output grain; anastomoses'
EVTID is channel linkage, not grain) so all became "PATID"; only the event-stay probe is "EVTID". No
`$unit` reads existed. `unit` is removed from `variable_spec` (loud "unused argument" if passed).

**Probe (disposable, in-test).** `test-slice-output-grain-guard-spec.R`: declaring "EVTID" grain with
patient tasks (no EVTID column) errors; declaring "PATID" grain with a repeated PATID errors. Two
assertions, the guard's two substantive guarantees (linkability + 1:1). Suite 73 -> 75.

**Deferred still open:** lab stay-grain scoping (now loud-guarded, not silent); count-of-empty-stay =
NA not 0; `level` (channel attachment) ratified but unwired.

**Files:** `R/spec.R` (rename + validate + store + template/inspect), `R/run_variable.R`
(`.check_output_grain` guard + grain_keys threading + lab loud-guard), `R/structured.R` (grain_keys is
now a param, sniffing removed), 11 test files + 3 scripts (`unit=`->`output_one_row_per=`),
`tests/testthat/test-slice-output-grain-guard-spec.R`, `HANDOFF.md`; memories
`design-is-source-of-truth-code-lags`, `variable-spec-boilerplate-explicit-names`, `MEMORY.md`.

---

## 2026-07-02 -- index_event derived anchor: the first thing that reads `variable$anchor`

An anchor can be a task COLUMN (`anchor = "inclusion_date"`, one date supplied per task) or now
DERIVED from an event. `index_event(source, selector, at = "event_start")` (`R/operators.R`, class
`ee_index_event`) is the GENERIC derived anchor -- DESIGN §14's `transplant_date()`/`surgery_date()`
are domain-specific forms. Per subject: find the event in `source` whose `code` role matches
`selector`, take its date at role `at` ("event_start"=DATENT, "event_end", "date").

**Mechanism = an anchor-resolution PASS, not an inter-channel dependency.** New `.resolve_anchor` in
`run_variable` runs AFTER `.check_output_grain`, BEFORE channel dispatch: if `variable$anchor` is an
`ee_index_event`, it computes per-subject `(PATID, anchor_date)` and injects `anchor_date` into tasks;
then normal windowing keys off it. A string/NULL anchor passes through unchanged (caller supplied
`tasks$anchor_date`). NB `variable$anchor` was previously set-but-UNREAD (same shape as `unit` before
this session) -- `.resolve_anchor` is the first reader; existing string-anchor tests are untouched
because the pass no-ops on non-`ee_index_event`.

Probed on `pmsi_diag`, which already maps `DATENT`->`event_start` (data.R), so NO source-spec change
was needed. (ACTE_SOURCE still lacks `event_start`; the "stay with CCAM act X, anchored at its DATENT"
variant needs `ACTE_SOURCE` to map DATENT->event_start + act fixtures carrying DATENT -- deferred, no
consumer yet.)

**Probe (disposable).** Two patients, SAME measured-code date (E11 on 2024-05-20) but DIFFERENT index
events (Z94 stay starting 06-01 vs 01-01). anchor = index_event(pmsi_diag, icd10("^Z94"),
at="event_start"); 30-day before-anchor window over an E11 code channel. P1 present (1), P2 absent (0)
-- same code date, opposite outcome, so the anchor is derived per-subject. Plus a contract test:
multiple index events per subject ERROR (single-match is a deliberate boundary; silent-arbitrary would
give a wrong anchor -> wrong cohort membership invisibly). Suite 75 -> 78.

**Contracts / deferred:** single-match only (multi-match -> candidate_selection, future); a unit with
NO matching event ERRORS (every unit needs its index event -- graceful partial-cohort/NA handling
deferred); anchor resolved per SUBJECT (PATID), stay-grain index_event out of scope for now.

**Files:** `R/operators.R` (`index_event()` constructor), `R/run_variable.R` (`.resolve_anchor` pass +
call), `tests/testthat/test-slice-index-event-spec.R`, `HANDOFF.md`; memory
`index-event-derived-anchor`, `MEMORY.md`.

---

## 2026-07-03 -- Backfill: point_date rename + act-anchor composition probe

Two commits landed with their full rationale in commit messages only (`d20dffc`, `89b4da0`);
summarized here so HANDOFF stays the complete chronological record:

- **Time role `date` -> `point_date` (`d20dffc`).** `date` was a type name masquerading as a role
  (every temporal column is a date). `point_date` names the structural slot -- the single instant a
  point-dated record occupies -- as the honest sibling of `event_start`/`event_end`. Concept-agnostic
  by construction: the same role is worn by DATEACTE, DATEXAM, and RECDATE. Pure token rename; no
  logic keys on the literal (executors resolve dates via `source_time_*`, `.resolve_anchor` reads
  `roles[[at]]` generically).
- **Act-anchored forward-window probe (`89b4da0`).** Disposable variable_spec (test-local, not a
  shipped concept) proving three shipped-but-never-co-exercised axes compose in one realistic spec:
  act-anchored derived anchor (`index_event(pmsi_actes, ccam(), at = "point_date")`), a forward
  window (`days_after(1, 30)`), and a cross-source combine (`"pmsi_complication | redo_act"`).
  Green first try -> no engine gap; the shape was already expressible. Retires the stale
  "act-anchored variant pending" note: the act anchor needs the `point_date` role, not `event_start`.

---

## 2026-07-03 -- DESIGN reconciled to two shipped ratified renames (fresh-eyes review, Claude Fable)

A cold re-entry review (README -> DESIGN -> HANDOFF tail -> code) found DESIGN.md lagging the CODE in
the non-licensed direction: §1 allows the doc to be AHEAD of the code ("states the destination
vocabulary even where code lags"), not behind it. Doc-only commit; suite green at **99** before and
after (no code touched). Also verified during the review: `outputs/` is fully gitignored (zero
tracked files), so the local run artifacts honor the no-clinical-data rule.

- **`unit` -> `output_one_row_per`** (ratified + shipped 2026-07-02) had landed in §7's grain-scoping
  paragraph but NOT in the §6 declaration list, the §6/§13/§14 examples, the §12 resolved view, §2's
  layer diagram, or invariant 12 -- so the doc used `unit` for BOTH grain (§6) and measurement unit
  (§8 `unit = "mmol/L"`), the exact ambiguity the rename was ratified to kill. All grain-meaning
  `unit` occurrences now read `output_one_row_per`; §7 retitled "Grain, anchors, windows, and
  linkage". §14's fictional `transplant_unit()`/`surgery_unit()`/`patient_unit()` constructors became
  `output_one_row_per = "PATID"`, per the shipped migration's own finding that those labels named the
  ANCHOR event, not the output grain. The `unit` payload role (labs, line ~115/`UNIT`) keeps the name
  -- that IS the freed measurement meaning.
- **`date` -> `point_date`** (`d20dffc`) had updated the §4 role vocabulary + note but missed the
  worked examples: the biology/documents `source_spec` examples and the §12 resolved view still
  mapped `date =`. Now `point_date =`.
- **§1 status paragraph described the completed migration as ongoing:** it referenced the retired
  `MIGRATION.md` and named `binary_output()`/`number_output()`/public `decision`/`decision_state` --
  all deleted 2026-07-01 -- as transitional shipped surfaces. Rewritten: migration complete,
  declared-but-unbuilt capabilities live in §16, chronological progress lives here.

Raised in the same review but NOT acted on (owner to decide): (a) the §12 five-test floor predates
~6 newer decided invariants -- stay-grain scoping in particular fits the ratified silent/decided/
invisible-to-real-validation gate and is a promotion candidate; (b) HANDOFF at ~5.5k lines no longer
supports the "re-enter cold by reading this file" premise -- consider folding closed history into an
archive and keeping protocol + current-state + recent entries.

**Files:** `DESIGN.md`, `HANDOFF.md`.

## 2026-07-03 -- Floor extended to post-06-30 invariants + closed history archived (Claude Fable)

Items 4 and 5 from the same fresh-eyes review, both owner-ratified ("i agree with you
on 4 and 5 as well").

**4) §12 floor re-opened and extended.** The five-test floor was ratified 2026-06-30;
since then six slices shipped decided invariants with tests that were formally "cuttable
without ceremony". Applied the ratified gate (silent + decided + invisible-to-real-
validation) to each and promoted five invariants (six tests):

- `event-stay-grain #1` / `lab-stay-grain #1` -- grain-key (EVTID) scoping in both
  executor branches; a PATID-only join silently inflates every stay-grain value.
- `channel-override #1` -- the activation selector drives the executor (§14.3); silent
  fallback to the concept baseline mis-measures every locally-overridden variable.
- `index-event #2` -- anchor resolution fail-closed on multi-match; silently picking an
  arbitrary event shifts every window invisibly.
- `lab-threshold #1` -- thresholded-analyte tri-state (hit / measured-below-complete /
  absent-partial); a silent flip feeds wrong availability into the observed algebra.
- `whole-history #2` -- no-window eligibility reaches a document any window would
  exclude; a silently reintroduced window default removes candidates pre-review.

Deliberately NOT promoted: `output-grain-guard` (the guard failing is only harmful
jointly with a second bug -- not silent on its own) and structural/loud tests (envelope
shape, constructors). The "declined thresholded-lab test is not a gap" clause in §12 was
removed -- that shape has since shipped with §8 and its test is now floor. Provenance
remains the one open floor candidate, unchanged.

**5) HANDOFF archived for cold re-entry.** This file had grown to ~5,500 lines / 310KB --
past what "re-enter cold by reading DESIGN.md and this file" can mean in practice.
Closed history (2026-06-19 -> 2026-06-30: design-review rounds, prototype builds,
migration slices 1-6, test pruning) moved verbatim to `HANDOFF-archive.md`; this file
keeps the protocol header, a pointer, and the target-contract era (2026-07-01 onward),
now ~640 lines. Cut point rationale: the 06-30 pruning ratification is the last entry
whose full text matters less than its DESIGN §12 record; everything after it describes
the current code. Nothing was reworded in the archive; do not append there.

**Verification.** Suite green before and after: `[ FAIL 0 | WARN 0 | SKIP 0 | PASS 99 ]`
(doc-only change; no code touched).

## Produced-dataset provenance object shipped; floor candidate closed -- Claude Fable (2026-07-03)

**What.** Invariant 27 ("Provenance is part of the output contract, not optional
documentation") made concrete, owner-directed ("please take care of the offered
slice"). `run_variable()` output now carries `run$provenance`, a serializable
`ee_provenance` record assembled from `resolve_variable_spec()`: identity (variable /
concept / template), the RESOLVED definition (grain, anchor snapshot, window days,
combine expression, output shape, and per channel the type, source, resolved
source-role mapping, and the resolved selector WITH its origin: activation override vs
concept default), plus execution facts (model name, timestamp). Per-attempt LLM
provenance (provider/seed/prompt/schema/query hashes) already rides on
`channel_results[[ch]]$attempts` and is not duplicated. Deferred until knowable (§16
discipline): code commit, source export date, runtime settings beyond model, template
versioning.

**Bug found and fixed on the way.** `.resolve_channel_activation()` resolved
method/extractor/reducer through the activation but pinned `selector =
channel_def$selector` -- so `resolve_variable_spec()` (and anything built on it)
reported the concept BASELINE selector while the executor ran the §14.3 activation
override. Exactly the invariant-27 silent failure: values right, trail lying. The
selector now inherits like every other activation field, with `selector_source`
("activation"/"channel") exposed.

**Floor promotion (§12).** New disposable probe
`test-slice-provenance-spec.R`: #1 pins that provenance records the override
(`^E1[0-2]`, source "activation") and not the baseline (`^E1[0-4]`), plus the resolved
definition; #2 pins execution facts + resolved source-role mappings. `provenance #1`
passes the floor gate (silent; decided -- ratified today in §12; invisible to physician
review, since the values are computed correctly from the override either way) and
joins the floor. The "one open floor candidate" clause is closed in DESIGN §12.

**Files.** `R/spec.R` (selector resolution + selector_source), `R/run_variable.R`
(`.build_provenance()` + envelope field), `DESIGN.md` (§12 ratified object subsection,
floor bullet, candidate closed), `tests/testthat/test-slice-provenance-spec.R` (new).

**Verification.** Suite green: `[ FAIL 0 | WARN 0 | SKIP 0 | PASS 119 ]` (was 99).

## Three real-run scripts collapsed into one generic driver -- Claude Fable (2026-07-03)

**What.** `run_variable_{diabetes,smoking,anastomoses}_real.R` shared one spine
(config -> engine sourcing -> build -> real caller -> run_variable -> PHI detail to
outputs/ -> aggregate-only report) and differed only in data assembly + report shape.
Replaced by `scripts/run_variable_real.R <case>`: the spine is generic; each case is a
CASES registry entry (removable scaffolding) supplying engine_files, bounding defaults,
and build(cfg) -> {tasks, sources, spec, save_extra}. The report needed NO per-case
code: it dispatches on the run envelope (multi-channel combine -> per-channel
contribution + positive attribution over ALL channels; categorical -> levels from
spec$output$levels; fields -> per-field acceptance). Env unified: REAL_N (per-case
default), MAX_DOCS, SMOKE_SEED, DATASETS_DIR. Privacy posture unchanged: console
aggregates only, per-row PHI -> outputs/ (gitignored).

**Latent bug surfaced.** The old diabetes script's engine chain lacked `R/hitset.R`,
so it would have died at spec build ever since any_positive() started lowering to
hit_set_expr() -- evidence the copies had already drifted. The driver's base chain
includes it.

**Verified with real runs** (gemma3:4b, local Ollama): smoking REAL_N=2 (categorical,
2/2 grounded), diabetes REAL_N=2 (OR path; contribution report negative/signal +
silent, positive attributed to the code channel), anastomoses REAL_N=1 (event-scoped
fields; 5 fields valid not_documented, evidence present). Suite untouched:
`[ FAIL 0 | WARN 0 | SKIP 0 | PASS 119 ]`.

**Files.** `scripts/run_variable_real.R` (new), the three per-concept scripts deleted.

## The pipeline model ratified into DESIGN -- Claude Fable (2026-07-04)

**What.** A two-day design conversation (owner-driven, stress-tested on three worked
examples) is now contract text. The core reframe: a variable_spec is a declarative
recipe for a small data-science pipeline (owner's ground truth: `lab %>%
filter(EVTID %in% docs$EVTID, hb < threshold) %>% group_by(EVTID) %>%
summarise(mean(hb))`). Channels are FILTERED ROW SETS carrying the identity spine --
their rows are simultaneously membership hits and value carriers; combine is set
algebra on spine keys at a stated level producing the SURVIVING row set; the output
kind decides what happens to those rows.

**Ratified surface (DESIGN sections in parentheses).**
- `combine` -> `combine_channels` flat expr string + `combine_at_level` defaulting to
  `output_one_row_per` (SS7/SS10); exists-lift to output rows; single-channel variables
  have no combine.
- Payload invariant (SS8): `num_output(values_from =, reduce =)` -- reducer moves off
  the activation onto the output; payloads are ALWAYS post-combine, "raw" has no
  spelling; gate + unconstrained payload = two variables.
- Channels list forms (SS6): bare strings activate; use_channel() only for overrides
  (loses `source` forever and `reducer`); inline typed definers declare variable-local
  channels under non-colliding names.
- Source resolution (SS4/SS5): source_spec gains `kind`; typed definers may omit
  `source =`, resolved unique-or-error (a 2nd lab-kind source makes omission a loud
  error, never a silent default).
- Wrapper razor (invariant 33): window ctors retired -> `window = c(from, to)` days
  (`-Inf` legal, dissolving the whole-history gap); index_event multi-match ->
  `select_event` plain closure (multi-row selection ENTAILS per-event output rows,
  owner-ratified; grain guard enforces); candidate selection -> plain closure over the
  standardized candidate table (`llm_candidate_selection()` reserved name dropped).
- Identity spine upgraded to "combination substrate" (SS4); invariants 30-35 added,
  12 amended; three worked examples added (SS14.7 antecedent de cholecystectomie,
  SS14.8 SSI 6mo post spinal surgery = the combine_at_level/select_event consumer,
  SS14.9 mean Hb in anaemic stays = the values_from consumer); SS16 gains the
  "ratified surface pending wiring" backlog with named consumers.

**Why.** Every piece traces to an owner ruling in-session: the where axis was
proposed, then DISSOLVED by the pipeline reframe (no separate gate axis); the
reduce-scope question flip-flopped until the owner's dplyr line settled it
(reducer sees filtered, join-surviving rows only); channel_hits()/surviving*()
spellings and lab_anemia-as-second-channel were each rejected and the surface
re-derived. Code still speaks the previous spellings -- wiring is gated per SS16.

**Files.** `DESIGN.md` only (375 insertions, 114 deletions). Suite untouched.

## Payload outputs wired: gated cat/num read the survivors' values -- Claude Fable (2026-07-05)

**Trigger.** Stress-testing the ratified matrix with a gated-categorical consumer
(dialysis modality: gate = `dialysis_diag & dialysis_act`, level read from the
surviving act rows' CCAM family, JVJF*/JVJB*). The probe hit the spec guard
("A hit-set expression only produces a 0/1 membership value") and the owner ruled
it a remnant of the pre-pipeline model: hits are binary, but the values BEHIND
them are free -- the combine gates rows, it never produces the value.

**Ratified (DESIGN SS8).** The per-type permission rows collapse into one payload
rule: `bin_output()` lifts membership; any other output must declare its payload
(`values_from =` + `reduce =`). `cat_output(levels, values_from =, reduce =)`
joins `num_output(...)` (cat payload ratified 2026-07-05, this consumer);
str/struct behind a gate stay "revisit with a consumer". Edge rules ratified with
it: a reduce return breaking its own contract (non-numeric / outside `levels` /
not exactly one value) is a HARD error, not a review state; an empty surviving
payload behind a passing gate is NA without calling reduce; `n_payload_rows` on
the values frame records the post-combine rows actually reduced (pre-combine
counts already ride coverage).

**Wired** (SS16 lines deleted: `num_output(values_from =, reduce =)` + payload
constraint; provenance pre/post counts). At the DEFAULT `combine_at_level`
(= output grain) over the observed hit sets -- sub-output-grain evaluation still
arrives with the `combine_at_level` line (consumer 14.8), noted inline in SS16.
- `operators.R`: `num_output(values_from =, reduce =)` (reduce now required),
  `cat_output(levels, values_from =, reduce =)` (payload flavor; without reduce it
  stays the text documented-status flavor).
- `spec.R`: the old guard reworded to the payload rule; `.check_output_payload()`
  normalizes `values_from` (defaults to the sole channel; required + validated
  against activations otherwise); `use_channel(reducer =)` REMOVED and rejected
  loudly (reduction is the variable's question -> lives on the output); reducer
  dropped from activation resolution + provenance channel snapshot.
- `run_variable.R`: `.payload_values()` (a lab row's value = its measurement, a
  code/act row's value = its code, read off evidence), `.reduce_payload()`
  (contract validation), `.single_payload_variable()` (replaces
  `.single_numeric_variable`, also serves single-channel cat-over-codes),
  `.apply_gated_payload()` (gate audit untouched; only the value column changes
  meaning). Provenance output snapshot gains `values_from` + deparsed `reduce`.
- `structured.R`: the code/act `candidates` frame (value = 1L count hack) deleted
  -- its only consumer now reads codes from evidence; count = `reduce = length`.

**Tests.** 142 pass (from 119). New `test-slice-gated-cat-output.R` (the probe,
graduated): gated cat incl. researcher-closure tie-break + gate-fail NA with
silence vs ascertained-negative coverage kept distinct; gated num + n_payload_rows;
empty-payload-behind-`|` -> NA (NOT length 0 -- would conflate no-payload with
measured zero; count-identity stays a deferred question); single-channel cat
payload; build-time payload-rule errors; out-of-levels hard error. Three tests
migrated `use_channel(reducer =)` -> `num_output(reduce =)`.

## combine_at_level wired: the expression is checked per stay, exists-lifted to the output grain -- Claude Fable (2026-07-05)

**Trigger.** Owner greenlit ("we need to do both") wiring the last unwired semantic
axis of the ratified pipeline model via the SS14.8 SSI probe, before tackling the
aggregate membership predicate (SS16 item 7, HAVING shape -- still open, next).

**The probe** (`test-slice-stay-combine-spec.R`, disposable, both canonical
consumers): SS14.8 SSI -- `text_ssi & (cim10_ssi | act_revision)` at `EVTID`, one
row per `PATID`, raw-document retrieval + fake caller. The TRAP patient (text hit
in stay S1A, revision act in stay S1B) scores 0 at stay level; a default-level twin
asserts he scores 1 today, so the axis is a real discriminator and the default
cannot drift. SS14.9 anemia -- `text_anemia & hb_low` at `EVTID` pooled to `PATID`,
`num_output(values_from = "hb_all", reduce = mean)`: the mean reads ONLY qualifying
stays' rows (the non-qualifying stay's Hb 8 is out; the qualifying stay's normal 13
is in), and swapping `values_from` to `hb_low` changes which values enter the mean.
Rejection surface before wiring: `variable_spec` unused-arg on `combine_at_level`;
`analyte_value` unused-arg on `lt`; the dead-weight rule on the payload-only channel.

**Execution semantics** (recorded in SS7 under the grain section): the key universe
at a sub-output level = the UNION of keys observed by the referenced channels (no
roster of unobserved stays; `!A` is complement within observed keys). A channel's
keys are read off its HIT EVIDENCE rows -- structured evidence already carries the
spine; text hits place via the cited documents' `EVTID` threaded from `docs_index`
through eligibility -> `retrieve()` -> materialized evidence. Fail closed twice:
evidence lacking the level key, or a hit row with an empty key, is a loud error.
Task-level membership/overlap audit unchanged; per-key verdicts exposed as the
run's `combine_keys` view. Payload behind a sub-level gate is scoped to qualifying
keys (semi-join on task + key), so SS14.9's invariant holds mechanically.

**Wired** (SS16 line deleted: `combine_at_level` + exists-lift):
- `spec.R`: `variable_spec(combine_at_level =)` (+ template passthrough);
  `.check_combine_at_level()` -- needs a combine expression, must be an
  identity-spine key (PATID/EVTID/ELTID), at the output grain or finer (coarser
  would leak hits across output rows); `.check_expr_channels()` now exempts ONLY
  the payload channel (`values_from`) from the dead-weight rule, and payload
  normalization runs before the expression check.
- `run_variable.R`: `.channel_level_keys()` + the sub-level branch in
  `.hit_set_expr_variable` (vectorized eval over observed task x key pairs,
  exists-lift, `combine_keys` audit frame); `.payload_values(level =)` +
  `.apply_gated_payload` key-scoping; provenance records the EXECUTED
  `combine_at_level` (declared or defaulted; NULL without combine algebra);
  text eligibility keeps `EVTID` in all three linkage branches.
- `retrieval.R` / `extract.R`: candidates + materialized text evidence carry
  `EVTID` when the docs index does (`any_of` whitelists).
- `channels.R` / `structured.R`: `analyte_value(lt =)` (SS14.9's hb_low was the
  consumer the shipped comment reserved it for; gt and/or lt, at least one);
  lab `candidates` keep the identity spine (payload key-scoping join).

**Tests.** 161 pass (from 142), 0 fail, 0 warn. Still §16-pending on this family:
`select_event` + per-event tasks (14.8's anchor half -- the probe used
researcher-supplied anchors); lab subject-context predicates (14.9's sexe/age
threshold); the spec-layer renames (combine -> combine_channels, window ctors ->
c(from, to), channels string/inline forms) -- this slice touched the spec layer,
so their gate is due at the next natural opportunity.

## Aggregate membership predicates wired: hit if the GROUP's aggregate says so -- Claude Fable (2026-07-05)

**Trigger.** The second half of the owner's "we need to do both": SS16 item 7, the
HAVING shape, from the owner's own ask -- "hit if mean hb < 10... It's something
the engine must be capable to do" (workaround until now: precompute the aggregate
column by hand upstream).

**Spelling (proposed by me, on the channel definition, two plain params -- flag
for owner rename if the names don't sit right):**
    group_at_level  = "EVTID"                   the spine key whose groups are tested
    keep_group_when = \(v) mean(v) < 10         plain closure, group values -> one TRUE/FALSE
No wrapper (razor: the engine interprets both parts, but a ctor would add
nothing); validated for every typed channel constructor (pair required together;
spine key only; function only). Semantics = a grouped row FILTER
(`group_by(EVTID) |> filter(mean(value) < 10)`): qualifying groups keep their
ORIGINAL rows; hits/evidence/provenance point at real rows; level algebra,
exists-lift and payload consume them unchanged. SS8 (lab channels) records the
contract; SS16 item 7 deleted.

**The probe** (`test-slice-aggregate-membership-spec.R`, disposable): anaemic
stay = mean Hb < 10. Ascertained-negative vs silence kept distinct (measurements
with no qualifying group = hit FALSE/complete; no measurements = NA/partial); the
hit's evidence = ONLY the qualifying stay's rows (the mixed patient's normal stay
contributes nothing); group-filtered rows feed combine_at_level ("anaemic stay &
same-stay transfusion" discriminates same-stay vs cross-stay); contract-breaking
closure = hard error; declaration-time pair validation. Rejection surface before
wiring was the DANGEROUS kind: channel() accepted the unknown params silently and
the engine returned a WRONG cohort (mean-11.5 patient scored 1) -- exactly the
silent-wrong-member failure this slice closes.

**Wired.**
- `channels.R`: pair validation in `channel()` (all typed ctors).
- `structured.R`: `measure_analyte_values(group_at_level =, keep_group_when =)`
  -- group filter between target-marking and the presentational fields; demoted
  rows stay in observations audit ("group aggregate predicate not satisfied");
  derivation rule records the group clause.
- `run_variable.R`: lab dispatch passes the pair through; non-lab channels with
  a group predicate rejected loudly (consumer discipline); provenance channel
  snapshot gains `group_at_level` + deparsed `keep_group_when`.

**Tests.** 176 pass (from 161), 0 fail, 0 warn. Interim hand-precomputed-column
workaround no longer needed. Open on this family: subject-context predicates
(sexe/age thresholds, SS16); coded-source group predicates (loud error reserves
the seam); activation-level override of the group pair (inherit-only for now).

## Group predicate extended to every structured channel -- Claude Fable (2026-07-05)

Owner ruling ("should be wired for every channel, at some point it will be needed
100%"): `group_at_level`/`keep_group_when` now ride code/act too, via the shared
`.apply_group_predicate()` helper (structured.R). The closure sees the group's
CODES there, so frequency criteria are plain length() rules -- probe: ">=2 acts
in the SAME stay" (AM7 two acts in one stay = 1; AM8 one act in each of two
stays = 0, ascertained/complete; evidence = the qualifying stay's rows). TEXT
still refuses loudly, with the reason in the error: a text hit is an LLM answer
grounded on cited rows, so a group rule that empties the citations must overturn
the answer (ascertained absent? unevaluable?) -- fork deliberately left to a real
consumer, recorded in SS8. Suite 180/0/0.

## Spec-layer renames landed: the ratified spellings are the only spellings -- Claude Fable (2026-07-05)

Owner: "Also renames." The SS16 rename batch (gated on "next touch of the spec
layer" -- touched twice today) is done; DESIGN prose and code now agree:
- `combine` -> `combine_channels` (variable_spec formal + template defaults +
  every test/concept/script; the old name is REJECTED LOUDLY, not aliased).
- Window ctors DELETED (wrapper razor): `window = c(from_days, to_days)` is the
  only spelling -- c(0, 180) forward, c(-1825, 7) lookback+grace, c(-Inf, 0)
  unbounded lookback (rule strings switched to %g so Inf prints; executors takes
  numeric day offsets). before_anchor(days=D, grace_days=G) migrated as c(-D, G).
- Channels entry forms (SS5): `channels = c("a", "b")` plain string activations;
  named use_channel() replacements; named INLINE typed definitions
  (`hb_all = lab_channel(...)` in the variable's list -- SS14.9's shape, now
  exercised by the stay-combine probe with hb_all inline instead of on the
  concept). Inline names colliding with concept channels are rejected; the
  runner resolves defs via .channel_def() (inline-or-concept catalog).
- required_roles / native_grain were ALREADY optional declaration metadata and
  linkage already defaults to the subject path -- noted in SS16, nothing to wire.
  Source-kind resolution (channel omitting source=) remains SS16-pending: it
  needs a content-kind facet on source_spec; gate = a consumer that cannot name
  its source.

Suite 180/0/0 on the first post-migration run. Next: select_event (owner
greenlit) -- scoping rule settled by inspection: every windowed consumer is
subject-scoped, every grain-unit consumer is windowless, so per-event tasks
(windowed, EVTID identity) scope by PATID + window.

## select_event wired: the researcher's rule for which event starts the clock -- Claude Fable (2026-07-05)

Owner: "i remember that necessity and understand what select_event is doing.
Yes we should do it." The last SS16 semantic line with a 14.8 consumer.

**Surface** (as ratified, invariant 35): `index_event(source, selector, at,
select_event = <plain closure>)`. The closure sees the subject's matched event
rows (PATID, EVTID, and the date under its ROLE name, e.g. point_date) and
returns the row(s) that anchor the clock. NULL keeps today's posture: multiple
matches = loud error, the engine never picks (message now points at
select_event).

**Emission** (probe `test-slice-select-event-spec.R`): one selected event ->
anchor as before, task ids unchanged. Several selected events (e.g. identity)
-> ONE TASK PER EVENT, task_id suffixed ::EVTID, each with its own anchor and
window; output_one_row_per must name the event key -- identity under
patient-grain output fails loudly ("one task per patient"). The anchor pass now
runs BEFORE the grain guard so the guard sees the emitted universe. A closure
dropping EVTID/date columns is rejected; a closure selecting nothing = the
no-match loud error. Executed select_event rides provenance deparsed (like
reduce / keep_group_when).

**Scoping rule settled and recorded in SS7:** a declared WINDOW is the scope
(rows gather per subject inside each task's anchored window; a per-event task's
EVTID is task IDENTITY, never a row filter -- forward complications live in
LATER stays); with no window the grain unit is the scope. Verified: every
pre-existing consumer already sat on one side (windowed = subject-scoped,
grain-unit = windowless), so nothing shipped changed meaning. Probe
discriminator: same patient, same November revision -- 1 for the June surgery's
task, 0 for the March one.

**Tests.** 190 pass / 0 fail / 0 warn. SS16 semantic residue: subject-context
lab predicates (sexe/age) and source-kind resolution -- both consumer-gated.
