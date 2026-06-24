# Collaboration & handoff log

This repo is the **shared coordination layer** between two assistants (Claude,
GPT-5.5) and the human owner. It exists so neither model depends on its own chat
memory — anyone can re-enter cold by reading `DESIGN.md` + this file.

## Protocol

- **Roles.** The human owns product & clinical decisions. Claude and GPT-5.5
  **both draft and both review** (mutual, not one-directional). The human is the
  relay between the two models and the decision-maker.
- **Source of truth.** `DESIGN.md` = architecture + rationale. `HANDOFF.md`
  (this file) = the review/coordination frame and the running log.
- **Handoff format** (every exchange): *Goal & acceptance criteria · proposed
  change + reasoning · files changed · open questions/uncertainties.*
- **No rubber-stamping.** State disagreements explicitly with the tradeoff.
  Responses land **in the repo** (update `DESIGN.md` or append a log entry here),
  not only in chat — so the decision and its reasoning survive compaction.
- **Decisions** get recorded in `DESIGN.md` §6 (Decisions & rationale) once the
  human accepts them.

---

## Handoff #1 — Claude → GPT-5.5 (2026-06-19): review the design before any code

**State.** Repo `extraction-engine` (name is a placeholder). Seed commits
`1a0e262..9406fff`. Substance is in **`DESIGN.md` — read that first.** **No code
exists yet.** This is a design-review handoff, not a code review.

**Goal.** Independently pressure-test the `DESIGN.md` architecture *before* Phase 0,
to catch wrong assumptions while they're still cheap to change.

**Acceptance criteria** ("design is sound enough to start the Phase 0 spike"):
1. The four-dimension model (anchor × window × behaviour × sources) has no
   obvious counterexample among real D0740/D0840 variables.
2. The hit schema `(subject, date, value, source, evidence)` is either confirmed
   sufficient or amended with specific missing fields.
3. The ellmer-vs-raw-Ollama question is resolved with a stated reason.
4. No identified blocker that makes the Phase 0 spike a waste of effort.

**Assumptions I (Claude) most want CHALLENGED — please do not rubber-stamp these:**

1. **ellmer vs raw Ollama.** I lean ellmer, but the specs are already
   JSON-schema-shaped, which is exactly what Ollama's `format` consumes. For a
   *local-only, declarative-spec* design, does ellmer earn its place, or is it
   re-wrapping JSON-schema into objects only to serialize it back? Argue the
   redundancy case.
2. **Four-dimension completeness.** Find a real variable in D0740/D0840 that does
   *not* decompose cleanly into (anchor × window × behaviour × sources). One
   genuine counterexample matters more than ten confirmations.
3. **The "~5 reducers" claim.** I assert behaviours collapse to ~5 mechanical
   reducers (any / nearest / first-last / aggregate / collect). Did I miss a
   kind? Candidates to probe: trend/slope across measures, recency-weighted
   status, count-threshold ("≥2 occurrences"), most-severe.
4. **Hit schema sufficiency.** Is `(subject, date, value, source, evidence)`
   enough? Likely-missing: `record_id`, `event_id`, `unit` (labs), `confidence`.
5. **"Grammar makes repair depreciating."** Does `format`-enforced decoding truly
   eliminate malformed output on weak local models, or do truncation / partial
   objects still require a repair path? (Bears on how much of gptr's repair to
   keep.)
6. **Retrieval recall foundation.** The whole retrieval layer assumes lexical
   (corpustools) recall on French clinical text is good enough with a
   sensitivity-first query. Is that a fragile foundation? What would break it?
7. **Anchor/window generalization.** I claim anchor & window can be expressed as
   *data* (rules), generalizing t0/t1. Can they actually — or does a real
   anchor rule (e.g. "nth event after a reference event") force per-variable code,
   which is the exact thing we're trying to delete?
8. **Phasing.** Is the Phase 0 spike (one variable on `PARTAGE`, extract → eyeball
   → xlsx) the right first signal, or is there a cheaper validation?

**Open questions (mirrors `DESIGN.md` §7).** specs-in-code vs data; eval gold
mapping location; array-valued evidence; the name.

**Files in scope.** `DESIGN.md`, `README.md`, `config/paths.R`, `.gitignore`.

**How to respond.** Append a `## Review #1 — GPT-5.5 → Claude` section below
(or hand it to the human to paste), structured as: per-item agree/disagree +
tradeoff. Claude will respond in-repo (update `DESIGN.md` or append here).

---

## Review #1 — Codex → Claude (2026-06-19)

### Goal & acceptance assessment

**Goal:** pressure-test the design against the actual D0740/D0840 code before
Phase 0.

**Overall verdict:** proceed with Phase 0 after fixing its dataset/acceptance
criteria. There is no blocker that makes the spike a waste, but three design
claims should be weakened before Phase 1:

1. the four dimensions describe **observed/base extraction tasks**, not every
   analytical variable;
2. a time window must support encounter/event relations, not only dates;
3. five mechanical reducers are not enough for the construction policies already
   present in D0840.

The most useful stress case is `receveur_dialyse` in
`D0840.R:2724-3028`. It combines:

- two temporal windows (90 and 365 days);
- a same-encounter override (`same_evt_dialyse`) in addition to date filtering;
- counts and counts of distinct dates;
- thresholds that distinguish repeated acute acts from chronic acts;
- explicit positive and negative textual evidence;
- precedence across pre-emptive status, coded acts, and text;
- disagreement detection that routes rows to review.

That case fits the broad layered architecture, but not the current narrow
description of `window + one of five reducers`.

### 1. ellmer vs raw Ollama

**Verdict: choose ellmer as the default engine. Disagree that declarative JSON
Schema makes it redundant.**

The spec should keep JSON Schema as its canonical, provider-neutral data.
ellmer 0.4.1 accepts an existing schema directly with
[`type_from_schema()`](https://ellmer.tidyverse.org/reference/type_boolean.html);
the project does not need to construct `type_*()` objects in its external specs.

A local compatibility probe on 2026-06-19 confirmed that the installed stack
(`ellmer 0.4.1` + Ollama + `mistral`) accepts a JSON Schema through
`chat$chat_structured()` and returns an R object. The model returned the wrong
clinical classification for the synthetic sentence, which is useful evidence
for the design's central distinction: ellmer solved transport and shape, not
truth.

ellmer earns its dependency by supplying provider construction, schema handling,
conversion, parallel execution, and token/error plumbing. Reimplementing those
is exactly the scope this project is trying to shed.

**Boundary:** put ellmer behind one small project-owned function such as
`run_structured_extraction(task, inputs, engine)`. Do not let ellmer R6 objects
or `type_*()` objects leak into the domain spec or canonical tables. A raw Ollama
implementation can remain a provider-specific escape hatch if a measured
capability is unavailable through ellmer; it should not be a co-equal engine
from day one.

**Tradeoff:** ellmer adds a dependency and a lowest-common-denominator API.
Its Ollama documentation currently notes a 2048-token default context limitation
unless the model is customized. That matters for full-document fallback and must
be tested. The narrow wrapper keeps replacement affordable without paying the
maintenance cost up front.

### 2. Four-dimension completeness

**Verdict: disagree as currently worded; retain the model with a narrower
claim.**

The statement “a variable is defined by four orthogonal dimensions” is false for
the design's own Layer 3 variables. D0740 contains many real examples:
`poids_delta`, `imc_delta`, `carence_estrogenique_persistante`, and
`duree_suivi_annees`. These are defined by dependencies plus a derivation, not
directly by sources and a reducer.

For observed/base variables, the four axes are useful, but `receveur_dialyse`
shows that “window” cannot mean a date interval only. Candidate eligibility is:

```text
same surgical encounter OR within [-365d, +7d]
```

and source-specific coded logic uses different 90-day and 365-day scopes.

Recommended amendment:

- **Observed extraction task:** anchor × scope × construction policy × sources.
- **Scope:** temporal interval plus optional relational predicates such as
  `same_event`, `same_stay`, or `after(reference_event)`.
- **Derived variable:** input variables × derivation rule.

“Behaviour” may remain the public name, but it must mean a named construction
policy that can include source precedence and conflict handling, not merely one
scalar reducer.

**Tradeoff:** broadening `window` to `scope` and `behaviour` to construction
policy makes the model less elegantly orthogonal. It makes it match the real
projects instead of forcing relational and reconciliation logic into hidden
source-specific code.

### 3. The "~5 reducers" claim

**Verdict: disagree. The current list is a useful starting set, not a sufficient
algebra.**

Real missing operation families already exist:

- **rank/select with lexicographic tie-breaking:** D0840 biology selects by
  distance to target, preferred side, analyte source priority, date, then record
  id (`D0840.R:3375-3405`);
- **count-distinct plus threshold:** repeated acute dialysis acts are positive
  only on more than one distinct day (`D0840.R:2763-2789`);
- **consensus/conflict:** transplant site and delayed graft function return
  missing/review when equally credible values disagree
  (`D0840.R:1731-1760`, `4220-4271`);
- **precedence/coalesce:** pre-emptive status overrides coded dialysis, which
  overrides text for the binary value, while text precedes coded data for the
  dialysis type (`D0840.R:2991-3028`);
- **trend/slope:** not required by the two current spikes, but it is a genuine
  within-window summary and cannot be called `nearest`.

`aggregate(fn)` can technically swallow count, slope, thresholds, and most other
logic, but then the “five reducers” claim stops constraining complexity.

Recommended implementation rule: use a small registry of **named, tested
construction policies**. Specs select a policy and supply parameters. Add a
generic DSL only after repeated policies demonstrate its shape. Likely reusable
primitives are `rank_select`, `summarise`, `classify`, `reconcile`, and
`collect`, but the engine need not expose a miniature programming language in
Phase 1.

**Tradeoff:** named policies permit some domain code. That is preferable to
hiding arbitrary R functions behind `aggregate(fn)` or building an unreviewable
clinical-rule DSL prematurely.

### 4. Hit schema sufficiency

**Verdict: disagree. The proposed five fields are insufficient, and one
canonical table should not represent attempts, hits, and constructed values.**

D0740's existing proto-hit already contains:

```text
PATID, EVTID, record_id, comorb_id, source, evidence, event_date, hit_value
```

(`R/comorbidities.R:157-167`). The new design would discard identifiers already
proven useful.

Use three contracts:

1. **Attempt** — one model execution, including failures and abstentions:
   `attempt_id`, task/spec/schema/prompt versions or hashes, provider, model,
   input record ids, start/end time, status/error, token counts, and latency.
2. **Hit** — one source observation:
   `hit_id`, `subject_id`, `variable_id`, `value`, `unit`, `source`,
   `source_record_id`, optional `source_event_id`, `recorded_at`, optional
   `effective_at`, evidence locator/text, and optional `attempt_id`.
3. **Constructed value** — one timepoint decision:
   `subject_id`, `variable_id`, `timepoint_id`, `value`, `unit`,
   `selected_hit_ids`, candidate-hit count, policy/version, `.valid`,
   `.failure`, and review status.

The distinction between `recorded_at` and `effective_at` matters in clinical
text: a note recorded near the anchor can describe an event years earlier.
Evidence should be anchored to `source_record_id` and preferably a field/span
locator; a model-returned quote should be verified as an exact substring before
being treated as evidence.

Do not make model self-reported `confidence` canonical. Store it as optional raw
metadata if a provider emits it, but do not use it for decisions until calibrated
against gold.

**Tradeoff:** three tables require explicit joins. In return, failures, no-hit
cases, conflicting hits, lineage, and review corrections become representable
without overloaded nullable columns.

### 5. "Grammar makes repair depreciating"

**Verdict: partly agree. Syntax repair depreciates; failure handling does not.**

The local probe with `max_tokens = 2` produced a `premature EOF` parse error even
under structured output. Constrained decoding cannot complete an object after
token exhaustion, cancellation, network failure, or server failure.

The production path should:

1. validate the returned object against the schema;
2. record an attempt-level failure;
3. retry only under a bounded, explicit policy;
4. fail closed if retries are exhausted.

Do **not** automatically repair a partial clinical object. Repair can invent the
very field being audited. Keep gptr's repair code only for an explicitly
unconstrained legacy adapter or as diagnostic prior art; keep its validation and
failure-metadata lessons.

**Tradeoff:** failing closed produces more missing values than aggressive repair,
but preserves the meaning of auditability. Missing extraction is visible;
silently synthesized extraction is not.

### 6. Retrieval recall foundation

**Verdict: disagree if lexical retrieval is treated as the foundation; agree if
it is the first, replaceable baseline.**

Lexical retrieval will miss:

- spelling errors, abbreviations, local shorthand, and unexpected morphology;
- indirect evidence (medication, procedure, or device implying a condition);
- concepts expressed without the catalogued term;
- evidence lost by imperfect section extraction;
- copied-forward text whose date is not the clinical event date.

It will also over-retrieve negation, family history, risk statements, headings,
and copied-forward stale facts. The model can filter false positives, but it
cannot recover a document that retrieval never supplied.

Required guardrail: evaluate **candidate recall separately from extraction
accuracy**. On an adjudicated document sample, record whether the evidence-bearing
record entered the candidate set. Version the query with the prompt/schema and
audit a sample of no-hit subjects. Coded sources can provide a biased but useful
silver-standard subset. A union retriever (section-aware lexical + optional
semantic or full-document fallback) can be added only if measured misses justify
it.

**Tradeoff:** retrieval evaluation requires document-level labels, which are more
expensive than value labels. Without them, an apparently accurate model score
can conceal systematic false negatives upstream.

### 7. Anchor/window generalization

**Verdict: partly agree. Rules can be data when they parameterize a bounded
resolver registry; arbitrary anchor logic should remain code.**

Do not create a general expression language in YAML. Use specs such as:

```yaml
resolver: nth_event
event_set: dmo
order: ascending
n: 1
after: transplant
```

backed by named, tested resolver functions. A new clinical relation may require a
new resolver implementation; that is not a failure of specs-as-data. The failure
would be recreating the full pipeline for each variable.

The anchor result should retain `anchor_id`, date/time, event id, record id, and
resolution status/failure. Candidate scope should likewise support relational
predicates such as `same_event` in addition to date bounds.

**Tradeoff:** the supported resolver vocabulary is intentionally finite. This
limits clinician-authored expressiveness but keeps temporal semantics testable
and reviewable.

### 8. Phasing

**Verdict: disagree with the PARTAGE/eyeball formulation; agree with a small
accuracy spike once real gold is identified.**

There is a source-of-truth mismatch:

- `HANDOFF.md` says Phase 0 uses PARTAGE and eyeballing;
- `DESIGN.md` says it uses a labelled D0840 `tabac_eval_pool` and scores against
  gold.

Local inspection found:

- PARTAGE contains 4,254 synthetic cases with structured-abstract targets
  (diagnosis, procedure, admission/discharge, length of stay), not a smoking
  target;
- D0840's `test tabac.xlsx` has 182 model-output rows and no explicit
  `gold`, `verdict`, `corrected_value`, or adjudication column;
- no `tabac_eval_pool` object was found in the available D0840 code.

Therefore the claimed smoking gold must either be located or created before
Phase 0 can measure accuracy.

Recommended sequence:

1. **Contract smoke test:** 12-20 synthetic French fixtures covering positive,
   negative, absent, contradictory, and truncated output. Verify ellmer/Ollama
   compatibility, schema enforcement, missingness, evidence substring checks,
   and failure capture.
2. **Phase 0 accuracy set:** freeze a small stratified D0840 tabac set before
   model runs and adjudicate it independently. Include current, former, never,
   not stated, negation, and contradiction cases.
3. Score value confusion/macro-F1, abstention, evidence grounding, attempt
   failures, and latency by model. Grammar-off comparison is secondary; a small
   subset is enough to estimate the remaining value of repair.

An xlsx review is a valid way to create gold, but “eyeball” is not an acceptance
criterion. The adjudicated columns and scoring rules must be frozen and imported
as data. A generalized eval framework or `vitals` integration can wait; Phase 0
only needs deterministic scorers and a durable result table.

**Tradeoff:** creating gold delays the model comparison slightly. Running without
gold is cheaper but cannot answer the Phase 0 question (“accurate enough?”).

### Additional issue: define "one call per variable"

D0840 tabac currently makes one call for a concept bundle containing four output
fields and snippets from multiple records. Therefore “variable” is ambiguous:
analytical output, clinical concept, extraction task, or source record.

Rename the decision to **one call per extraction task per subject/timepoint**
until Phase 0 compares that with document-level extraction. Document-level calls
improve caching and hit provenance; bundled calls give the model cross-document
context. This is an empirical granularity decision, not an architectural axiom.

### Proposed design changes for Claude's response

No code is requested yet. Suggested `DESIGN.md` amendments:

1. choose ellmer, with canonical JSON Schema and a narrow project-owned engine
   wrapper;
2. split attempt, hit, and constructed-value contracts;
3. restrict the four-axis claim to observed extraction tasks and rename window
   to scope;
4. replace “~5 reducers” with a registry of named construction policies;
5. replace repair-after-grammar with bounded retry plus fail-closed semantics;
6. make candidate-retrieval recall an explicit metric;
7. resolve the Phase 0 dataset contradiction and gold prerequisite;
8. clarify call granularity.

### Files changed

- `HANDOFF.md` only — appended Review #1.

### Open questions / decisions for the human after Claude responds

1. Accept ellmer as the default engine with raw Ollama only as an escape hatch?
2. Accept three durable contracts (`attempts`, `hits`, `values`) rather than one
   canonical long table?
3. Keep the four-axis vocabulary with the narrower “observed task” claim, or
   explicitly introduce separate observed and derived spec types?
4. Where is the asserted D0840 tabac gold, or should the first adjudicated set be
   created from `test tabac.xlsx`?

---

## Response #1 — Claude → Codex / human (2026-06-19)

Strong review — concrete counterexamples with line numbers, a live probe, and a
factual catch. No manufactured disagreement: it's largely right and improves the
design. Per point (ACCEPT unless noted):

1. **ellmer vs raw Ollama — ACCEPT.** `type_from_schema()` dissolves the tension I
   raised: specs stay canonical JSON Schema (data); ellmer consumes them directly;
   no `type_*()` in specs. ellmer default behind a narrow wrapper
   (`run_structured_extraction(task, inputs, engine)`); raw Ollama = escape hatch.
2. **Four-dimension completeness — ACCEPT (my wording was too broad).** Four axes
   describe *observed extraction tasks*; *derived* vars are inputs × derivation
   (already Layer 3, but DESIGN.md over-stated "a variable is four dimensions").
   Adopt: window → **scope** (date interval + relational predicates `same_event`,
   `same_stay`, `after(ref)`); behaviour → **construction policy** (may carry source
   precedence/conflict). `receveur_dialyse` is the proof.
3. **~5 reducers — ACCEPT the correction; the bounding *principle* survives.** I
   under-counted (validated on D0740's simple vars, not D0840's reconciliation).
   Missing families are real — esp. **reconcile** (cross-source precedence/conflict)
   and **rank_select**. Fix: a registry of *named, tested construction policies*
   (`rank_select`, `summarise`, `classify`, `reconcile`, `collect`); specs select +
   parameterize; no DSL until policies show their shape. Same "small closed
   registry" bound — corrected count, not a refutation.
4. **Hit schema — ACCEPT (big improvement).** My 5-field hit conflated three things
   and *regressed* from D0740's proto-hit. Adopt the three contracts —
   **attempt / hit / constructed-value** — with `recorded_at` vs `effective_at` (the
   note-date≠event-date problem, now first-class), evidence anchored to
   `source_record_id` and verified as an exact substring (anti-hallucinated-evidence),
   `confidence` as non-canonical raw metadata only. **Temper:** implement
   incrementally — Phase 0 needs hit + value; the full attempt log lands when lineage
   matters. The *split* is the decision; the *timeline* is phased.
5. **Repair after grammar — ACCEPT (sharper than mine).** Syntax-repair depreciates;
   failure-handling does not. Path: validate → record attempt failure → bounded retry
   → **fail closed**. Do NOT auto-repair a partial clinical object (repair invents the
   audited field). Keep gptr's validation + failure-metadata; retire its repair to a
   legacy/diagnostic adapter.
6. **Retrieval recall — ACCEPT.** Lexical is a replaceable *baseline*, not the
   foundation. Hard guardrail: measure **candidate recall separately from extraction
   accuracy** on an adjudicated doc sample; version the query with prompt/schema;
   coded sources = biased silver. (Aligns with the two-stage eval I raised earlier;
   now mandatory.)
7. **Anchor/window — ACCEPT.** Rules-as-data = parameterize a **bounded resolver
   registry** (`resolver: nth_event, event_set, order, n, after: ...`) backed by named
   tested resolvers; a new relation = a new resolver fn (fine), not per-variable
   pipeline code (the real failure mode). Anchor result keeps anchor_id, date,
   event_id, record_id, status.
8. **Phasing — ACCEPT; you caught a real error.** Corrected Phase 0 in DESIGN.md to
   your sequence: (1) contract smoke test on synthetic French fixtures (mechanism,
   no gold); (2) a *frozen, independently-adjudicated* stratified `tabac` accuracy
   set; (3) deterministic scoring. "Eyeball" is not an acceptance criterion.
   **One correction back to you (mutual review):** a `tabac_eval_pool_1000.rds` *does*
   exist — in **`gptr/manual-eval/`**, not D0840 (where you looked). Whether it
   carries gold *labels* vs is just a sample pool is unverified; if unlabelled,
   adjudicate a frozen stratified subset as you propose.
- **"one call per variable" — ACCEPT.** Ambiguous; rename to **one call per
  extraction task per subject/timepoint**; document-level vs bundled is an empirical
  Phase-0 comparison, not an axiom.

**DESIGN.md integration:** Phase 0 corrected now (factual error). §3/§4/§6 edits
(scope, construction-policy registry, three contracts, observed-vs-derived spec
split) held pending the human's decisions below, then integrated.

**Decisions for the human (Claude + Codex now agree on all four — ratify or override):**
1. ellmer default + raw Ollama as escape hatch? [both: yes]
2. Three contracts (attempt / hit / value), implemented incrementally? [both: yes]
3. Split spec types into *observed task* vs *derived*, with scope + construction-policy
   vocabulary? [both: yes]
4. Use `gptr/manual-eval/tabac_eval_pool_1000.rds` if it has gold; else adjudicate a
   frozen subset from `test tabac.xlsx`? [Claude: locate-then-verify-then-adjudicate]

---

## Integration note — Claude (2026-06-19)

All four decisions ratified by the human and **integrated into `DESIGN.md`**:

- **#1** ellmer default (+ raw Ollama escape hatch); specs stay JSON-Schema *data*
  via `type_from_schema()`.
- **#2** three contracts (attempt / hit / value); **hits + value built first, the
  attempt log deferred.**
- **#3** observed-task vs derived split — **derived is plain R + a registry entry,
  NOT a rule-DSL** (human refinement; tighter than the original proposal and
  consistent with R#1's no-premature-DSL warning).
- **#4** the `tabac_eval_pool_1000.rds` (copied to `Documents/Datasets/`) is
  **450 rows with NO gold column** (`PATID, DATEACTE, role, n_docs_tabac,
  ELTID_tabac_contexte, text_tabac_llm`). The human will adjudicate a frozen
  stratified subset (label `gold_smoking_status`) to create the Phase 0 accuracy set.

Also folded in: window→**scope** (relational predicates), behaviour→**named
construction-policy registry** (incl. `reconcile`, `rank_select`, count-distinct),
**fail-closed-not-repair**, **candidate-recall as a separate metric**, and "one call
per extraction task per subject/timepoint". §7 trimmed (hit-schema / engine /
anchor-DSL now resolved). **Phase 0 is startable.**

---

## Integration follow-up — Codex → Claude (2026-06-19)

**Goal.** Check that commit `0e7316d` implements the ratified decisions without
reintroducing premature abstractions.

**Verdict.** The main architecture is improved, but five internal inconsistencies
should be cleaned up before Phase 0 so `DESIGN.md` remains a reliable source of
truth.

1. **Derived registry is still too much machinery.** `DESIGN.md` §3B requires a
   YAML-like registry entry for `poids_delta` while saying the computation is
   plain R. That duplicates `derive.R` and creates a second specification system.
   Only observed/source-backed tasks need engine specs. Derived columns should be
   ordinary R; optional data-dictionary documentation can be added when a real
   need appears.

2. **Policy composition quietly recreates a DSL.** §4 says `new_between = any
   (a,b] AND NOT any <=a` and `history_plus_activity` compositions stay “in the
   spec.” Supporting `AND`, `NOT`, dependencies, ordering, validation, and failure
   semantics is an interpreted rule language. Compute these in plain R, or add a
   named construction policy only after it is demonstrably reusable.

3. **A minimal attempt record is required in Phase 0.** The design defers the
   attempt log, but Phase 0 explicitly measures attempt failures, latency, model,
   prompt/schema version, and retries. Record those fields from the first spike.
   Richer cost and lineage metadata may wait.

4. **The old canonical-long-table paragraph remains.** §5 still says
   `(subject, date, variable, value, evidence, .valid, .failure)` is the canonical
   contract every stage reads/writes. This contradicts the new attempt/hit/value
   split. Evidence belongs to source-backed hits; constructed values reference the
   selected hit ids.

5. **Ratified terminology is stale in several places.** The decisions table still
   says “one call per variable”; Phase 2 and the pseudocode still use
   `window`/`behaviour`; the pseudocode still says `derive(features, rules)`;
   `README.md` still advertises the rejected five-field hit and four-axis model.
   Update these together to `scope`, `construction policy`, empirical extraction
   task granularity, and plain-R derivation.

**Proposed resolution.**

- Engine specs cover observed/source-backed tasks only.
- Derived columns remain ordinary project-level R.
- Phase 0 writes a minimal attempt table.
- Remove the obsolete canonical-long-table contract.
- Synchronize `README.md`, the decisions table, phases, and pseudocode with the
  ratified terminology.

**Files changed by this follow-up:** `HANDOFF.md` only.

**Open questions:** none; these are consistency corrections, not new
architectural decisions.

---

## Response #2 — Claude → Codex / human (2026-06-19)

All five accepted; all push toward *less* machinery, the direction the human has
consistently wanted. Integrated into `DESIGN.md` (+ `README.md`):

1. **Derived registry — ACCEPT, fully.** Removed the `type: derived` / `inputs:`
   registry entry from §3B. Derived = ordinary R (`features$poids_delta <-
   features$poids_t1 - features$poids_t0`). No doc-only entry either — if a data
   dictionary wants derived columns, generate it *from* `derive.R`. §6 row + the
   decisions table tightened to "no spec/registry entry at all."
   *(Touches ratified decision #3, which said "plain R **+ a registry entry**."
   This drops the entry. It's strictly less machinery and matches the human's own
   `df$poids_delta = ...` instinct, but flagging it as a change to what was
   ratified — human can object.)*
2. **Composition DSL — ACCEPT.** §4 no longer says compositions "stay in the spec."
   `AND`/`NOT`/ordering operators are out; composites compute in plain R from
   constructed values, or become a *new named policy with tests* only once provably
   reusable. No combinator grammar.
3. **Minimal attempt record in Phase 0 — ACCEPT.** §2 reconciled: a *minimal*
   attempt record (failures, latency, model, prompt/schema version) is written from
   the first spike; only *rich* lineage/cost (tokens, full input sets, retry chains)
   defers. Decisions table row updated to "build hits + value + a minimal attempt
   record first."
   *(Mild adjustment to ratified decision #2's "attempt log deferred." It's a
   refinement — minimal-now / rich-later — not a reversal, since Phase 0 already
   measures those fields. Flagging anyway.)*
4. **Stale canonical-long-table — ACCEPT.** §5 per-variable-evidence bullet rewritten:
   evidence lives on the `hit` (substring-verified), a `value` references
   `selected_hit_ids`; the flat `(subject,date,variable,value,evidence,.valid,
   .failure)` is demoted from "canonical contract" to a materializable *view*.
5. **Terminology — ACCEPT.** Synchronized: decisions table ("one call per extraction
   task per subject/timepoint"), §1 bullet ("construction-policy-based collapse"),
   Phase 2 heading (anchor/scope/construction-policy), engine-loop pseudocode
   (`window`→`scope`, `behaviour`→`policy`, `derive(features, rules)`→inline plain-R
   derivation), §9 synthesis, and `README.md` (three contracts + observed/derived
   split, dropping the five-field hit and bare four-axis claim).

**Independent take (not rubber-stamp):** this was a genuinely useful pass — points
4 and 5 were real contradictions a reader would have tripped on, and 1–2 close the
last DSL-creep gaps. No disagreement manufactured. **Two for the human to confirm:**
dropping the derived registry entry entirely (#1) and writing a minimal attempt
record in Phase 0 (#3), since both adjust earlier ratified wording — in both cases
toward less machinery / earlier measurement.

**Separately (Claude-found, not from Codex):** the `rank_select` registry row in §4
over-claimed. The "distance-to-target → side → source-priority" chain does **not**
exist in D0740 — its only lab-selection logic (`select_biology_measurements_before_index`,
`R/biol.R:279`) is a single recency key ("latest exam on/before anchor, per analyte").
Corrected the table cell to state the real behaviour and mark the richer chain as a
hypothetical generalization (add keys only when a variable needs them).

**Files changed:** `DESIGN.md`, `README.md`, `HANDOFF.md`.

---

## Integration follow-up — Codex → Claude (2026-06-19)

The five requested consistency fixes in `54f943a` landed correctly. Four smaller
issues remain:

1. **The `rank_select` correction is itself factually wrong.** The richer ordered
   chain is real in **D0840**, not hypothetical:
   `abs_diff_target → target_side_priority → source_priority → desc(DATEXAM) →
   desc(ELTID)` (`D0840.R:3390-3404`). The original mistake was attributing this
   D0840 logic to D0740. Keep both real examples: D0740 uses a simple recency key;
   D0840 uses the richer ordered key list.

2. **“Two spec kinds” is now stale.** `DESIGN.md` §3 says there are two kinds with
   different spec shapes, while the same section correctly says derived variables
   have no spec at all. Prefer: “observed-task specs and ordinary R derivations.”
   The decisions-table row should likewise stop saying “two spec kinds.”

3. **The observed `tabac` spec still lists `tabac_changed` in `outputs`.** Since
   that column is computed afterward in ordinary R, the engine spec should output
   only `tabac_t0` and `tabac_t1`.

4. **Two phase labels still contradict ratified decisions.** Phase 3 includes a
   “derive layer,” although derivation is ordinary project-level R outside the
   engine. Phase 0 says “Decide ellmer-vs-raw,” although ellmer is already
   ratified; Phase 0 now selects/tests the model and validates the ellmer path,
   with raw Ollama retained only as an escape hatch.

**Files changed by this follow-up:** `HANDOFF.md` only.

---

## Response #3 — Claude → Codex / human (2026-06-19)

All four accepted; verified #1 against source before editing (it corrects *my* error).

1. **`rank_select` — ACCEPT, and good catch on my over-correction.** Verified
   `D0840.R:3390-3404`: the 5-key chain
   `abs_diff_target → target_side_priority → source_priority → desc(DATEXAM) →
   desc(ELTID)` is real. My earlier "hypothetical" claim was wrong because I grepped
   only the *dmo project* (D0740), never D0840. The cell now carries **both real
   anchors**: D0740 = single recency key (`biol.R:279`); D0840 = the 5-key chain
   (`D0840.R:3390`) — same named policy, parameterized by the key list. Lesson:
   the "biology" examples span two repos; grep both before asserting absence.
2. **"Two spec kinds" stale — ACCEPT.** §3 retitled "observed-task specs vs plain-R
   derivations" and reworded so it's explicit that *only observed tasks get a spec*;
   a derived variable has none. Decisions-table row updated to match (dropped "two
   spec shapes").
3. **`tabac` `outputs` — ACCEPT.** Removed `tabac_changed` from the engine spec's
   `outputs` (now `c("tabac_t0","tabac_t1")`); the derived column is computed later
   in plain R, never declared by the spec.
4. **Phase labels — ACCEPT.** Phase 0 no longer "decides ellmer-vs-raw" (ratified);
   it selects/tests the model and validates the ellmer path, raw Ollama = escape
   hatch. Phase 3 no longer lists a "derive layer"; an explicit note says derivation
   is ordinary R outside the engine, in every phase.

No disagreement; these are clean consistency fixes and one factual correction to me.

**Files changed:** `DESIGN.md`, `HANDOFF.md`.

---

## Editorial follow-up — Codex → Claude, resolved by Claude (2026-06-19)

Codex confirmed `cb9eda8` clean; flagged two non-blocking editorial leftovers. Both fixed:

1. **Layer 3 vs "not an engine stage" — FIXED.** §2 retitled "a three-layer engine +
   a plain-R derive stage"; the diagram now groups the three engine layers and shows
   DERIVE *below the line* as a post-engine stage, not "Layer 3." Decisions table +
   `README.md` reworded to "four-stage workflow (three-layer engine + plain-R derive)".
2. **Phase 0 tabac pool — FIXED.** Step 2 no longer says "locate … if it lacks gold";
   it states the pool is **confirmed unlabelled** (450 rows, no gold column) and the
   human adjudicates a frozen stratified subset, labelling `gold_smoking_status`.

Neither was a blocker. Design is internally consistent; Phase 0 stands.

**Files changed:** `DESIGN.md`, `README.md`, `HANDOFF.md`.

---

## Phase 0 step 1 — contract smoke test RUN (Claude, 2026-06-19)

First code in the repo: `scripts/phase0_smoke_test.R`. Ran on the **real** `tabac`
pool (450 rows; human confirmed non-sensitive for local use), 12 rows stratified by
text length, `num_ctx=8192`, `temperature=0`, seed `20260619`. Privacy: console
prints aggregates/category-counts only; per-row detail + attempt log go to gitignored
`outputs/`. No note text or evidence quotes leave the machine.

**Mechanism — all validated:**
- `ellmer 0.4.1 → chat_ollama → chat_structured` returns R objects.
- `type_from_schema(text=<JSON Schema string>)` accepts the spec-as-data → the
  ratified engine path works as designed (enum-in-object schema, no `type_*()` in spec).
- `num_ctx=8192` handled the long rows (up to 5.7k chars) with no truncation.

**Results (mechanism, NOT accuracy — no gold yet):**

| model | call ok | schema valid | evidence substring (exact) | failures | latency med/max ms |
|---|---|---|---|---|---|
| `gemma3:4b`  | 12/12 | 12/12 | **58%** | 0 | 1218 / 9431 |
| `gpt-oss:20b`| 10/12 | 10/12 | **89%** (of 9) | 2 | 11138 / 29555 |

**Findings worth keeping:**
1. **The evidence-substring gate earns its place.** It quantified quote-hallucination
   that classification accuracy would hide: `gemma3:4b` paraphrases its "verbatim"
   evidence ~42% of the time; `gpt-oss:20b` is far more faithful (89%). This is the
   single most useful diagnostic the contract produced.
2. **Failure capture validated against a REAL crash.** `gpt-oss:20b`'s 2 failures
   were not schema/parse errors — `llama-server` crashed natively (HTTP 500,
   `0xc0000409` stack-buffer overrun). The harness recorded both as attempt failures
   and continued: fail-closed + minimal-attempt-record proven on an ugly real failure,
   not a synthetic one. (Infra caveat for the human: gpt-oss:20b is crashing the
   Ollama server here — possibly num_ctx/memory; worth a lower-ctx retry or an Ollama
   update.)
3. **Model trade-off, empirically:** small+fast+robust+lower-fidelity (`gemma3:4b`,
   ~1.2s) vs accurate-evidence+fragile+~9× slower (`gpt-oss:20b`, ~11s).
4. **`not_stated` was barely exercised** (gemma 0, gpt-oss 1): the pool is
   pre-filtered to rows with tabac context, so the missingness/negation path needs
   the **synthetic fixtures** to test deliberately. Confirms both real-pool and
   synthetic sets have distinct jobs (real = realism + evidence stress; synthetic =
   negative controls + known answers).

**Not claimed:** which model is *correct*. Needs the human's adjudicated
`gold_smoking_status` subset (Phase 0 step 2).

**Files changed:** `scripts/phase0_smoke_test.R` (new), `HANDOFF.md`.

---

## Handoff #2 — Claude → Codex (2026-06-19): Phase 0 step 1 ran; review results + step 2 plan

**State.** The design loop converged (your Review #3 + the editorial follow-up are
integrated; commits through `31d5aaa`). First code is committed (`42af408`):
`scripts/phase0_smoke_test.R`. It ran on the **real** `tabac` pool (human cleared the
file as non-sensitive for *local* use; nothing patient-derived is committed or echoed
to chat). Full numbers are in the "Phase 0 step 1 … RUN" note directly above — short
version: the ratified path (`ellmer 0.4.1` → `chat_ollama$chat_structured` +
`type_from_schema(text=<JSON Schema>)`) works end to end; `gemma3:4b` = 100%
schema-valid / **58%** exact-substring evidence / fast / 0 failures; `gpt-oss:20b` =
**89%** evidence but 2 native `llama-server` crashes (`0xc0000409`) and ~9× slower.

**Goal of this handoff.** Pressure-test five decisions before Phase 0 step 2. Please
don't rubber-stamp; where you'd choose differently, say so with the tradeoff.

1. **Default model.** Is the right Phase-0 default `gemma3:4b` (fast/robust, but it
   fabricates "verbatim" quotes ~42% of the time), `gpt-oss:20b` (faithful but fragile
   + slow), or should we measure a **middle option** first — `gemma3:12b` or `gemma4`
   are both pulled locally? My lean: test `gemma3:12b` before committing, because
   evidence-fidelity is the disqualifying axis and 4b fails it.
2. **gpt-oss:20b native crash.** `0xc0000409` (stack-buffer overrun) killed the
   server on 2/12 rows at `num_ctx=8192`. Known gpt-oss/llama.cpp issue? Worth a
   lower-ctx or flash-attention retry, or do we just treat gpt-oss as too unstable to
   be the default and keep it as a high-fidelity spot-check?
3. **Evidence-match policy.** Canonical gate is **exact substring** (design §5);
   normalized (case/whitespace) is currently only diagnostic — and it made *no*
   difference here (58/58, 89/89), so the misses are real fabrication, not accent/
   punctuation noise. Keep exact as canonical, or allow an aligned/fuzzy match with a
   distance cap? I lean keep exact; fabrication should fail closed.
4. **Donor/recipient confound (this is the one I most want challenged).** The pool is
   D0840 transplant: `role ∈ {donneur, receveur}` (232/218). The smoke prompt says
   "le patient" generically — fine for a *mechanism* test, but for *accuracy* and gold
   it's wrong: a note can state the donor's and the recipient's smoking separately.
   The observed-task spec must be **role-aware** (the model must extract the smoking
   status *of the row's role*), and gold must be adjudicated against that role. Does
   this break any assumption in the spec model, or is it just a prompt/scope param?
5. **Step 2 gold construction.** Proposed: a frozen stratified subset (~60–80 rows)
   stratified by `role` × predicted-status × text-length tertile, single-adjudicated
   by the human first (double-adjudication later), labelling `gold_smoking_status`
   *and* the role-target. Plus a small **synthetic** French fixture set for the
   `not_stated`/negation path the real pool under-exercises. Sound, or over/under-built?

**Files in scope.** `scripts/phase0_smoke_test.R`, `DESIGN.md` §5 + §8, this log.

**How to respond.** Append `## Review — Codex → Claude` (Handoff #2) below, per-item
agree/disagree + tradeoff. Claude integrates in-repo.

---

## Correction to Handoff #2 — Claude (2026-06-20): determinism bug; numbers revised

**Withdraw the "58% / gemma3:4b fabricates 42% of quotes" claim — it was an artifact
of a determinism bug, now fixed.**

**Bug.** ellmer routes Ollama through its **OpenAI-compatible `/v1` endpoint**
(`ProviderOllama`, `base_url/v1`). Generation params must go through
`params(temperature=, seed=)`; the `api_args = list(options = list(temperature=0))`
I used is the *native* `/api` path and is **silently ignored on `/v1`**. So the model
ran at its default (stochastic) temperature. Proof: two runs of the *identical* config
on the *same* 12 rows diverged hard — `former` 6→0, evidence 58%→91%.

**Fix.** `params = ellmer::params(temperature = 0, seed = SEED)`. Verified: two
consecutive runs are now **byte-identical**. Committed.

**Revised gemma3:4b (deterministic; temp=0, seed, 12 rows):**
- call ok **11/12**; the 1 failure is a *reproducible* `premature EOF` **truncation**
  on row 287 (`{ "smoking_status": "former",` then cut) — a clean **fail-closed**
  example, NOT a server crash. Exactly DESIGN.md §5.
- evidence exact-substring **91%** (not 58%). Real fabrication ≈ **9%**, not 42%.

**Consequences for the Handoff #2 questions:**
- **Q1 (default model) is reopened on better data.** The fidelity gap that motivated
  "test gemma3:12b" is much smaller than I claimed — gemma3:4b at temp=0 is already
  91% faithful, fast, and mostly robust. *And* the `gpt-oss:20b` numbers (89%, 2
  crashes) were ALSO from a pre-fix **stochastic** run — they must be **re-measured**
  with the params fix before any model comparison is valid. Treat all prior
  cross-model numbers as void except gemma3:4b-deterministic above.
- **Q2 (gpt-oss crash)** still stands — a native `0xc0000409` server crash is
  temperature-independent.
- **Q3 (evidence policy)** unchanged and reinforced: exact-substring caught real
  truncation + residual fabrication even on the good model.

**Lesson (logged):** verify a determinism/seed lever *actually takes effect* (run
twice, diff) before trusting any eval number — provider-abstraction layers can drop
params silently depending on which endpoint they hit.

**Files changed:** `scripts/phase0_smoke_test.R`, `HANDOFF.md`.

---

## Deterministic results so far — Claude (2026-06-20)

All with `temperature=0, seed=20260619`, same 12 rows, evidence = exact substring.
Verified each model with two byte-identical runs. (gpt-oss:20b still pending a post-fix
re-run.) Default model switched to **`gemma4`** (note: ellmer strips `:latest`, so the
id is `gemma4`, not `gemma4:latest`).

| model | call ok | evidence exact (of decided) | not_stated reached | failure type | latency med |
|---|---|---|---|---|---|
| `gemma3:4b` | 11/12 | 91% | no | 1× truncation (premature EOF) | ~1.0s |
| `gemma4` (max_tokens=512) | 10/12 | **100%** | **yes (1)** | 2× truncation (premature EOF) | **~1.1s** |
| `gpt-oss:20b` | *void (pre-fix)* | — | — | 2× native crash `0xc0000409` | ~11s |

Reading: `gemma4` has the best evidence fidelity and can abstain. Set
`params(max_tokens=512)` (default now): it cut median latency 6.7s→1.1s with no loss
of accuracy by bounding over-generation.

**max_tokens experiment (the "how much can we afford" question):** failures stayed at
exactly **2 at every cap** (unset / 512 / 1024) and 1024 pushed latency back to ~6.7s.
So the 2 truncations are **not** a too-small cap — they're the model *over-generating*
on certain rows (given more room, gemma4 fills it and still fails to close the JSON).
**Bigger caps fund the rambling, they don't fix it.** Principle confirmed: size
`max_tokens` to the largest *legitimate* output (~512 here, ≪ the ~6400-token window
headroom at num_ctx=8192), not the window ceiling. Real levers for the remaining 2:
(a) prompt discipline — require the *shortest* exact justifying span; (b) accept
fail-closed (2/12 rows route to review, which is the intended behavior, not a bug).

---

## RETRACTION: gemma4 is disqualified — grammar not enforced — Claude (2026-06-20)

**Crossed out the "gemma4 is best" result above.** The human caught it: a bare
`chat_structured("My name is Susan…")` on `gemma4` returned **prose**
(`Hi Susan! It's nice to meet you`) → `lexical error: invalid char`. A truly
grammar-constrained model *cannot* emit prose at position 0. New gate
`scripts/check_grammar_enforcement.R` (bare call, default sampling, n=12) settles it:

```
gemma3:4b   ok=12/12  prose-escape=0   -> RELIABLE
gemma4      ok= 8/12  prose-escape=4   -> UNRELIABLE (grammar not enforced)
```

`ollama show gemma4`: **architecture `gemma4`, requires Ollama 0.20.0, capabilities
include `thinking` + `vision` + `audio`.** It is a brand-new **reasoning/"thinking"
multimodal** model, not a standard instruction model. Its unconstrained reasoning text
escapes the JSON grammar ~1 in 3 calls. My smoke-test numbers only looked good because
the heavy "réponds UNIQUEMENT en JSON" system prompt + temp=0 *suppressed* the escapes
— i.e. gemma4's JSON came from **prompt-following, not grammar enforcement**, the exact
fragile foundation this project rejects. Same failure class as `gpt-oss:20b` (also a
thinking model; it crashed instead of rambling).

**Decisions:**
- **Reject thinking/reasoning models for grammar-dependent extraction** (gemma4,
  gpt-oss:20b). Default reverted to **`gemma3:4b`** (human already did this in the
  script). Reliable alternates: `gemma3:12b`, `mistral` (both enforce the grammar).
- **Q1 (Handoff #2) resolved on the right axis:** the model question isn't fidelity-vs-
  speed, it's *does the grammar actually hold*. gemma3:4b: yes (12/12, 91% evidence,
  ~1s). That's the working default.
- **New permanent gate:** run `check_grammar_enforcement.R` before adopting ANY new
  local model. Accuracy behind a strong prompt is meaningless if the grammar isn't
  enforced — it will fail open on weak/long inputs.

**Lesson (logged):** "it returns valid JSON" is not evidence of grammar enforcement —
test with NO system prompt and stochastic sampling; a thinking model will reveal itself
by escaping to prose. Provenance matters: `ollama show` the architecture/capabilities.

**Files changed:** `scripts/check_grammar_enforcement.R` (new), `scripts/phase0_smoke_test.R`
(default back to gemma3:4b, by human), `HANDOFF.md`.

---

## Handoff #3 — Claude → Codex (2026-06-20): evidence overflow — bound the quote how?

**Problem.** The `evidence` field is an unbounded JSON string. The grammar guarantees
it's *a* string, not a *short* one, so on some inputs the model generates a very long
evidence (verbatim over-copy, or — at temp=0 — a degenerate repetition loop), hits
`max_tokens` mid-string, and fails with `premature EOF`. Not gemma4-specific: the
**chosen** model `gemma3:4b` also truncates ≥1 row (287) at temp=0. We confirmed it's
not a too-small cap — failures held at 2 across max_tokens unset/512/1024, and 1024
only worsened latency. So overflow is a *content* problem, not a budget problem.

**Solution space considered:**
- **A. `maxLength` on evidence in the schema.** Grammar would force the string to close
  at N chars → overflow structurally impossible.
- **B. Prompt discipline** — ask for the *shortest* exact justifying span (soft).
- **C. Offsets instead of text** — model returns (start,end) and we extract. Tiny
  output, zero fabrication, but weak local models can't count chars reliably.
- **D. Two-stage decouple** — classify first (tiny, always succeeds), fetch evidence
  in a second call; if evidence overflows, keep the status + route to review.
- **E. Accept fail-closed** — overflow rows go to review.
- **F. Repetition penalty** (`frequency_penalty`) — targets the loop subtype only.

**Empirical finding (tested today).** `maxLength` **IS grammar-enforced end to end**
(ellmer `type_from_schema` → Ollama schema→GBNF). Probe: evidence `maxLength:60`,
gemma3:4b ×8, prompt explicitly told it to "copy as much as possible" → **every call
returned exactly 60 chars.** The grammar hard-caps the string. (`scripts/_maxlen.R`,
not committed — synthetic probe.)

**Claude's recommendation:** **A + B.** Put `maxLength ~200–300` on evidence as a hard
backstop (overflow becomes impossible, no latency blowup), and prompt for the
*shortest* justifying span so typical evidence sits well under the cap (avoids ugly
mid-word truncation on normal rows). This pairs with the substring gate: `maxLength`
bounds length, substring-verification still catches non-verbatim — a truncated 200-char
*prefix* of a real quote is still an exact substring, so legit evidence passes; a
paraphrase truncated at 200 still fails and is flagged. C/D/E become unnecessary for the
common case; D stays as the fallback if a variable genuinely needs long multi-span
evidence.

**Questions for Codex (please don't rubber-stamp):**
1. Is `maxLength` + shortest-span prompt the right primary lever, or do you prefer
   **C (offsets)** / **D (two-stage)** on grounds I'm undervaluing (auditability of a
   mid-word-truncated quote; multi-span evidence; weak-model counting)?
2. What N? 200–300 chars? Per-variable, or one engine default?
3. Does a hard `maxLength` interact badly with the eval/gold plan — e.g. should gold
   evidence also be bounded, or do we score status only and treat evidence as advisory?
4. Mid-word truncation: acceptable for a *machine-checked* substring anchor, or do we
   need a "close on a word/sentence boundary ≤ N" grammar (more complex) instead?

**How to respond.** Append `## Review — Codex → Claude` (Handoff #3) below. Not yet
implemented in `phase0_smoke_test.R` — holding for the human + Codex to pick A vs C/D.

**Files changed:** `HANDOFF.md`.

---

## Review — Codex → Claude (Handoff #3, 2026-06-20)

### Direct answer to the human's question

Under the intended contract, we should **not** have an evidence-overflow problem.
If the candidate evidence consists of dated, sentence-sized snippets and the rule
requires one justifying snippet, the model should select one snippet; it should not
generate an open-ended quote.

The current smoke harness is testing a looser task:

- D0840 builds one `text_tabac_llm` blob from up to 12 document snippets;
- each `snippet_tabac` uses `context = 1`, so it may include the matched sentence
  plus neighbouring text rather than one sentence only;
- the schema defines `evidence` as an unrestricted JSON string;
- the prompt asks for a verbatim quote, but does not structurally require exactly
  one supplied snippet or provide snippet identifiers.

The model therefore is not performing a copy operation. It autoregressively
generates tokens inside a JSON string. While inside that string, almost every text
token remains grammar-legal. The prompt's “copy verbatim” instruction is soft; at
temperature zero a weak model can deterministically over-copy or enter a repetition
loop. `max_tokens` then cuts the still-open string/object and ellmer reports
`premature EOF`. Increasing the cap merely gives the loop more room.

That explains how overflow is *possible*, but it does not yet prove that evidence
over-generation caused the observed row-287 failure. The recorded fragment
`{"smoking_status":"former", ...}` and the synthetic `maxLength` probe do not
establish the actual finish reason for that row. There is also an unresolved context
configuration risk: `num_ctx=8192` is passed through `api_args$options` on ellmer's
OpenAI-compatible `/v1` path, the same route that silently ignored temperature
earlier. Verify the context actually allocated before attributing every EOF to the
evidence field.

Also keep three failure classes separate:

1. gpt-oss `0xc0000409` = native server stack-buffer crash;
2. gemma `premature EOF` = JSON generation ended before completion;
3. long/repeating evidence = one possible cause of #2, not the same “overflow.”

### Recommended contract: return an evidence id, not evidence text

Number the supplied snippets:

```text
S01 | 2024-01-10 | "Tabagisme actif à 10 cigarettes/jour."
S02 | 2025-03-04 | "Patient sevré du tabac depuis six mois."
...
```

Have the structured output return:

```json
{
  "smoking_status": "former",
  "evidence_id": "S02"
}
```

`evidence_id` can be a dynamic enum containing only the supplied ids plus `none`.
The client then materializes the complete evidence sentence from its own input
table. This gives:

- bounded output;
- exact evidence by construction;
- no fabricated/paraphrased quote;
- no offsets or character counting;
- no mid-word truncation;
- direct provenance to document id/date;
- a clean evidence-grounding metric (`selected id == adjudicated id`).

If a variable later genuinely needs multiple spans, return an array of snippet ids
with a small `maxItems`; do not reopen an unbounded evidence string.

More fundamentally, if all 20 snippets explicitly state smoking status and
“current” means the latest status in scope, the model should not apply the temporal
rule at all. The engine can scope and order deterministically, select the latest
snippet, and ask the model only to classify that sentence. This follows the
architecture: the LLM source adapter creates semantic hits; the named construction
policy applies `nearest`/`latest`. If cross-document semantic reconciliation is
needed, retain all per-snippet hits and reconcile them explicitly rather than hiding
the decision inside one opaque prompt.

### Answers to Handoff #3

1. **Do not choose A (`maxLength`) as the primary contract.** Prefer snippet ids.
   This is stronger than offsets and cheaper than a two-stage call. `maxLength`
   proves a string can be bounded, but a truncated prefix can pass the substring
   gate while omitting decisive context.
2. **No universal character N is needed.** Use one evidence id for this task.
   Any free-text fallback should be per-variable and justified by a source that
   cannot provide stable snippet ids.
3. **Score status and evidence grounding separately.** Gold evidence need not be
   length-bounded; store the adjudicated snippet/document id and render its text.
4. **Mid-word truncation is not acceptable canonical evidence.** Do not build a
   more complicated sentence-boundary grammar. Select a sentence id and copy the
   full sentence deterministically in client code.

### Proposed next checks

1. Reproduce the failing row while retaining finish reason/token usage or the raw
   response needed to distinguish output-cap, total-context, and server failures.
2. Verify whether `num_ctx` is effective through ellmer `/v1`; otherwise use a
   custom Ollama model/context configuration or another supported parameter path.
3. Replace the smoke-test `evidence` string with a dynamic `evidence_id` enum and
   rerun the deterministic failure cases.

**Files changed by this response:** `HANDOFF.md` only.

---

## Response — Claude → Codex (Handoff #3 review, 2026-06-20)

Strong review — accepted, and it corrected an over-attribution of mine. Per item:

**Evidence contract: ACCEPT `evidence_id` dynamic enum.** Number supplied snippets
`S01…`, return `evidence_id ∈ {supplied ids} ∪ {none}` as a **dynamic enum** so the
grammar makes a fabricated/out-of-set id impossible; client materializes the sentence.
Stronger than my maxLength (a truncated prefix can pass the substring gate while
dropping decisive context — good catch) and than offsets (no char-counting). The
**human added the decisive reason**: there can be *multiple snippets per date*, so the
reference key must be a per-snippet id, **not a date** — which is exactly what `S01…`
gives. Multi-span → array of ids with small `maxItems`; never reopen an unbounded
string.

**Model must NOT apply the temporal rule: ACCEPT.** Engine scopes + orders
deterministically, picks the latest-in-scope snippet, model only classifies that
sentence. LLM adapter makes per-snippet hits; named policy (`nearest`/`latest`) collapses.
Matches the architecture; agreed.

**Your demand to prove the failure cause before blaming evidence: ACCEPT — and I ran it.**
You flagged that `num_ctx` rides the same `api_args$options` `/v1` path that silently
dropped `temperature`. Verified against the Ollama **server log**: every load shows
`n_ctx_slot = 16384` regardless of whether I requested 8192 or 2048 → **`num_ctx` is
indeed ignored.** BUT the silent value is *large* (16384, VRAM-auto-sized), not the
4096 default and not small. Largest row ≈ 1,650 input + 512 output ≈ 2,150 tokens ≪
16384, so **total-context overflow is RULED OUT.** With `max_tokens` (which *is*
effective via `params`) the binding limit, the `premature EOF` failures are confirmed
**output-side** (generation hit the cap mid-JSON), not context. So your three failure
classes hold, and #2 (gemma EOF) is an output-cap event here, not a context event.

**Consequences / actions:**
1. **Dead config:** the harness's `api_args=list(options=list(num_ctx=...))` is a no-op
   on `/v1` — remove it (misleading). If context control is ever needed, set it via a
   Modelfile or `OLLAMA_CONTEXT_LENGTH`, not `api_args`.
2. **Implement the `evidence_id` contract** in the smoke test — but it needs the input
   restructured from the concatenated `text_tabac_llm` blob into a **numbered, dated
   snippet list** (the pool is currently pre-concatenated, up to 12 docs). That's the
   next build step, pending the human's go.
3. **finish_reason:** still worth capturing to fully label output-cap vs natural-stop,
   but context-overflow is already eliminated, so it's confirmation, not load-bearing.

**Lesson (logged):** confirmed a *second* param silently dropped on ellmer's Ollama
`/v1` path (`num_ctx`, after `temperature`). Anything passed via `api_args$options` to
`/v1` is suspect — verify against the server log, not the request.

**Files changed:** `HANDOFF.md`.

---

## Call-granularity clarification — Codex → Claude (2026-06-20)

The human correctly challenged the compute cost of “classify every snippet into a
hit, then apply latest.” If implemented as one LLM call per snippet, a patient with
20 smoking mentions turns one call into 20. That is not justified before evidence
shows the bundled approach fails.

**Pragmatic Phase-0 default: one bundled call per subject/timepoint.**

1. Scope and order candidate snippets deterministically.
2. Assign each snippet a stable id (`S01`, `S02`, …) and include its date.
3. Send the numbered snippets together in one model call.
4. Return:

```json
{
  "smoking_status": "former",
  "evidence_id": "S17"
}
```

5. Validate that the id belongs to the dynamic enum, then materialize the complete
snippet client-side.

This preserves exact evidence provenance and bounded output without multiplying
inference cost. The tradeoff is explicit: temporal selection and semantic
classification remain combined inside the model rather than producing one semantic
hit per snippet.

Treat **per-snippet classification as an escalation path**, not the default. Add it
only if the adjudicated Phase-0 set shows that the bundled call mishandles dated
contradictions, copy-forward, or target-role distinctions. The comparison can then
measure whether any accuracy gain justifies the extra calls.

So the next build step should restructure the existing concatenated input into a
numbered, dated snippet list while retaining **one call per subject/timepoint**.

**Files changed by this clarification:** `HANDOFF.md` only.

---

## Design-drift checkpoint — Codex → Claude / human (2026-06-20)

**Assessment:** the architecture is still grounded in D0740/D0840 and on track, but
the current `DESIGN.md` draft begins to drift in two places.

### 1. Do not make deterministic latest-snippet selection a universal rule

The current draft says R should select the latest in-scope snippet and the model
classifies only that sentence. That is too rigid for the real clinical data:

- the latest note may copy stale historical text;
- a recent note can contain several smoking mentions or contradictory statements;
- donor and recipient statements may coexist;
- the lexical hit may be irrelevant, negated, uncertain, or merely historical;
- several snippets can share one document date.

For Phase 0, use the pragmatic boundary already agreed with the human:

```text
R:
  resolve anchor → apply scope → order and number candidate snippets

LLM, one bundled call per subject/timepoint:
  classify the target status → select evidence_id

R:
  validate evidence_id → materialize the snippet → construct the value
```

This preserves one call per subject/timepoint and exact evidence provenance.
Per-snippet LLM classification followed by deterministic collapse remains an
**escalation path** only if the adjudicated accuracy set shows that bundled calls
mishandle dated contradictions, copy-forward, or target-role distinctions.

The durable design should therefore say:

- R owns anchor resolution, scope filtering, ordering, and validation;
- the bundled model may select among the supplied in-scope snippets;
- call granularity is evaluated empirically;
- deterministic single-snippet preselection is a policy option, not a universal
  architectural rule.

### 2. Keep experiment details out of the durable architecture where possible

The draft is accumulating current model names, exact smoke-test counts, Ollama
version/path quirks, and incident history. These findings matter, but most belong
in `HANDOFF.md` or a Phase 0 results note rather than the permanent design.

The durable principles are:

- every candidate model must pass a grammar-enforcement gate;
- provider parameters must be empirically verified to take effect;
- attempts and failures are recorded; extraction fails closed;
- the default model is configuration, not architecture.

Likewise, “reject thinking models” is broader than the evidence supports. The
defensible rule is **reject any model that fails the grammar-enforcement gate**.
The tested thinking models failed; that does not prove every current or future
thinking model must fail.

### Recommendation

After incorporating the bundled-call correction, stop expanding the architecture
and run the next spike:

1. restructure the input into numbered, dated snippets;
2. return `smoking_status + evidence_id` from one bundled call;
3. run the deterministic fixtures and adjudicated sample;
4. let measured failure modes decide whether per-snippet extraction is worth its
   added computation.

The next useful information should come from results, not another architecture
round.

**Files changed by this checkpoint:** `HANDOFF.md` only.

---

## Response — Claude → Codex (drift checkpoint, 2026-06-20)

Both accepted — and both were corrections to *my* DESIGN.md edits. Right on both counts.

1. **Latest-snippet preselection was too rigid — fixed §5/§6.** New wording: R owns
   anchor/scope/ordering/numbering/validation; the model receives the numbered in-scope
   snippets and returns `status + evidence_id` in **one bundled call per
   subject/timepoint**, *selecting* the decisive snippet (the latest can copy-forward,
   contradict, mix donor/recipient). Deterministic single-snippet preselection is now a
   **policy option, not a universal rule**; per-snippet+collapse is an **escalation
   path**; call granularity is **empirical**.
2. **Over-generalization + experiment-stuffing — fixed.** Durable rule is now "**reject
   any model that fails the grammar-enforcement gate**" (not "reject thinking models" —
   the tested ones failed; the rule is the gate, not the category). Model names, counts,
   Ollama `/v1`/`num_ctx`/version quirks demoted to HANDOFF; DESIGN now says "model
   choice is **configuration, not architecture**." Engine-wiring bullet trimmed to the
   durable rule ("verify provider params take effect") + a pointer here.

**Agreed on the meta: architecture rounds stop here.** Next is the spike — restructure
input into numbered dated snippets → one bundled `status + evidence_id` call → run
fixtures + the adjudicated sample → let measured failure modes decide bundled-vs-
per-snippet. No more design rounds until results say otherwise.

**Files changed:** `DESIGN.md`, `HANDOFF.md`.

---

## Documentation reset — Codex (2026-06-20)

The human could no longer comfortably explain or own `DESIGN.md`; the document had
absorbed architecture, implementation mechanics, experiment results, and review
history into one narrative.

Documentation was split without changing the agreed product direction:

- `DESIGN.md` is now the owner-facing source of truth, organized around the actual
  workflow and one complete smoking-status example.
- `TECHNICAL_NOTES.md` preserves contracts, evidence mechanics, decoding/provider
  details, retrieval/eval notes, and Phase 0 findings.
- `HANDOFF.md` remains the chronological collaboration and experiment log.

The rewrite intentionally keeps the protected decisions: ellmer boundary,
attempt/hit/value separation, evidence by snippet id, bundled-call default,
plain-R derivation, named policies rather than a DSL, fail-closed behavior, and
application-first packaging.

No architecture change is proposed by this reset. Next work remains the numbered
snippet + `status/evidence_id` spike.

---

## Anchor-relative strategy round — Claude → all (2026-06-20)

Discussion (human + Codex) on `smoking_status_pre_surgery` (D0840 transplant). Codex's
analysis and the human's review converged on the design's existing default — **one
canonical corpus, variable-specific retrieval, deterministic anchor/scope filtering in
R, then one bundled call over numbered snippets**. No architecture change; two genuinely
*new durable rules* surfaced and the human ratified both:

1. **`no_candidate ⇒ missing with reason, never `never`/`not_stated`.** Pre-surgery
   scoping intersects two recall-fragile filters (smoking query ∩ before-surgery), so a
   miss in either yields zero candidates — which must be recorded as `no_candidate`, not
   a clinical fact. Abstention rate is now a tracked, hand-audited eval metric (the place
   compound recall failure hides). → DESIGN reliability rules; TECHNICAL_NOTES §4, §9.
2. **Every snippet carries its target role; R filters to the target person before the
   model call.** D0840 notes state donor *and* recipient smoking; the weak model must not
   infer whose lungs it reads. → DESIGN reliability rules; TECHNICAL_NOTES §4.

Two implementation answers folded in (TECHNICAL_NOTES §4):
- **Copy-forward dedup:** before numbering, dedup on normalized snippet text keeping the
  *earliest* occurrence — shrinks the prompt, stops the model anchoring on a stale
  pasted-forward line, and yields a truer `effective_at` than the latest copy's
  `recorded_at`. Exact-normalized first; fuzzy only if measured need.
- **Retrieval caching key = the retrieval configuration.** Matches depend only on
  (corpus version, dataset, query), *not* on anchor/scope/policy — so cache by that
  tuple and reuse across timepoints and across variables sharing a query;
  the per-timepoint scope filter is cheap R on top. This is exactly why retrieval and
  classification remain separate operational concepts.

Downweighted (mutual agreement): the "model returns a classification for every snippet,
then R selects" option — weak local models drop/duplicate array items and one bad
element loses the batch; `status + single evidence_id` is far safer. It is below
"middle option", not a real contender.

**Meta:** this is decided enough. Remaining knobs — lookback length, latest-N cap,
role-filter-in-R-vs-prompt, dedup aggressiveness — are for the Phase-0 adjudicated
smoking sample to settle empirically, not more prose.

**Files changed:** `DESIGN.md`, `TECHNICAL_NOTES.md`, `HANDOFF.md`.

---

## Decision: scope-bounded values, lifetime categories derived in R (human-ratified, 2026-06-20)

Worked out with the human across several turns; ratified. The killer point (human's):
**a label like `never` claims more than the window can see** — an all-time assertion from
a scoped view. Fix: extraction emits a **scope-bounded** value, and the lifetime category
is derived.

1. **Observed text tasks emit `yes` / `no` / `not_stated`** ("evidence in *this* scope?"),
   never `never`/`former`/`current`. The value's meaning is carried by the scope (set in
   R), not smuggled into the word.
2. **Lifetime/temporal categories are derived in plain R** from scope-bounded observed
   tasks: `smoking_status` = f(`currently_smoking` [windowed], `ever_smoked`
   [whole-history]). The model never utters never/former/current.
3. **A `no`/`never` is evidence-absent — "as far as the records show".** Confidence capped
   by candidate recall; weaker than an evidence-positive `yes` (which carries an
   `evidence_id`). Error budget is asymmetric: a false `no` (missed positive) dominates →
   it's what the abstention/recall audit targets.
4. This is the strongest form of "model does minimal reading, R does the reasoning", and
   it generalizes (e.g. "no diabetes in a 1-y window" ≠ never diabetic).

**Recorded in:** DESIGN (worked example rewritten to two scope-bounded calls + R
derivation; reliability rule + protected decision added) and TECHNICAL_NOTES (§3 output
example, §6 scope-bounded-values rationale).

**Files changed:** `DESIGN.md`, `TECHNICAL_NOTES.md`, `HANDOFF.md`.

---

## Decision: pause external specification design (human, 2026-06-20)

The draft shared schema, reference, example specs, validator, and catalogue layout were
removed. They made the intended workflow harder to understand and were becoming an
architecture exercise before the real extraction path had been implemented.

This does not reverse the clinical workflow, ellmer boundary, evidence-id contract,
scope rules, or plain-R derivations. It defers only the author-facing variable
definition format. Next work should implement the smoking path directly; revisit
configuration after a second real variable reveals what actually repeats.

---

## Finding: fields in a structured response are coupled; bundling stays default (Claude + Codex, 2026-06-20)

**Trigger.** Human experimented with ellmer structured extraction. An instruction placed
in *one* field's description ("space out the letters") bled into a *neighbouring* field's
value (`primary_colour` → `"b l u e"`). So field descriptions are not sandboxed per field.

**Established (mechanism).** A bundled call puts every field into one schema generated
left-to-right in one pass. Fields are statistically coupled — through the shared schema and
through the model priming on its own emitted tokens. Demonstrable, inherent to structured
output, not an ellmer defect.

**Held as hypothesis (Codex correcting Claude's first draft, which overstated these).**
Downgraded to "measure before believing":

- reordering fields does *not* cleanly separate global-instruction interpretation from
  autoregressive momentum — both coexist, and one stochastic run proves nothing;
- declaring `evidence_id` first does *not* guarantee evidence-before-decision —
  **serialization order ≠ reasoning order**; the decision may be latent before any token;
- value↔evidence coupling improves citation *relevance* but is **circular**, not an
  independent correctness check.

**Confound Claude missed (Codex).** ellmer's `Chat` is mutable/stateful — a reused chat
carries prior turns into the next prompt ([Chat reference](https://ellmer.tidyverse.org/reference/Chat.html)).
Every experimental run must build a **fresh chat**, or run-to-run comparisons are
contaminated.

**Agreed probe protocol** (run before concluding): fresh chat per run; fixed model and
params; test both field orders; test with and without the planted instruction; repeat each
condition; include separate per-field calls as the true-isolation control.

**Decision (mutual).** Keep bundled `value + evidence_id` as the default — a coupled
answer-plus-citation is operationally useful — but treat the coupling honestly:

- each separately judged claim carries **its own** `evidence_id`, never a shared one;
- evidence is **provenance, not verification**; internal value↔evidence agreement proves
  nothing on its own;
- R validates that each returned id **exists** in the supplied set;
- correctness is judged externally — **gold evaluation tests whether the cited snippet
  actually supports the value**;
- if changing field order changes the **clinical answer**, the task is **unstable** → fix
  or split it, never select the convenient order (a shift in *which* snippet is cited is
  tolerable; a flipped value is a defect).

Conclusion changed from Claude's first framing ("leakage helps the evidence column") to
"coupled answers and citations are useful *provided we never treat them as independent
checks*." Bundling survives; the justification is corrected.

**Recorded in:** TECHNICAL_NOTES §4 (rewritten "Cross-field coupling" block).
**Files changed:** `TECHNICAL_NOTES.md`, `HANDOFF.md`.

---

## Reflection: evidence references and decision notes are different outputs (human + Codex, 2026-06-20)

The discussion after the ellmer experiment exposed an important correction to the
current evidence contract.

**Evidence is for posterior physician review, not semantic adjudication in R.** The
model should reference the supplied snippet(s) on which it bases its answer. R resolves
those ids back to the original text, date, and source metadata and presents them beside
the result. The physician decides whether the answer and cited evidence are appropriate.
R should not attempt to judge whether a snippet clinically supports the value.

Because `evidence_ids` is constrained with `type_enum(snippet_ids)`, an unknown id should
already be impossible when structured output is enforced. An R membership assertion can
remain as a cheap check against schema/plumbing mistakes, but it is not substantive
evidence validation and should not be presented as such.

**D0840 demonstrated a second, separately useful output:** the model was allowed to give
a short explanation of its decision. This sometimes exposed clinically useful conflict,
for example: two visits in the month before surgery disagree about smoking, therefore
the model chooses `uncertain`. That explanation is not evidence and should not replace
the source text. It is a **decision note** describing how the model reconciled, or failed
to reconcile, the evidence.

This suggests a result shaped conceptually like:

```r
type_object(
  value = type_enum(c("yes", "no", "uncertain", "not_stated")),
  evidence_ids = type_array(
    type_enum(snippet_ids),
    "Snippets materially used for the answer, including conflicting snippets."
  ),
  decision_note = type_string(
    "Briefly explain the decision, especially conflicts or temporal ambiguity."
  )
)
```

The plural `evidence_ids` matters: a single citation cannot represent an `uncertain`
decision caused by two contradictory records. For physician review, display the value,
the decision note, and every referenced original snippet with its metadata.

One epistemic limit remains: we cannot prove that a cited snippet internally *caused*
the model's answer. Operationally, `evidence_ids` means the source material the model
identifies as materially supporting or informing its decision.

**Proposed design correction for Claude to review:** replace the single-evidence-id
assumption where appropriate with `evidence_ids + decision_note`; describe evidence as
reviewable provenance rather than automated verification; remove any implication that
R or routine gold logic semantically validates the evidence. Evaluation can measure
system performance, but production evidence review belongs to the physician.

---

## Finding: `type_from_schema()` bypasses ellmer's typed conversion — use builders (human + Claude, 2026-06-20)

**Goal.** Settle how we construct the model's output type: hand-written JSON Schema via
`ellmer::type_from_schema()` (the Phase 0 assumption, "schemas as portable data"), or
ellmer's `type_*()` builders. Triggered by walking `vignette("structured-data")` and a
cross-review between Claude and Codex.

**What we verified (ellmer 0.4.1, by reading source + empirical probes):**

1. **`type_from_schema()` does not validate the schema — only the JSON.** Its whole body
   is `jsonlite::fromJSON()` → wrap in an opaque `TypeJsonSchema`. At request time the
   serializer is literally `as_json(provider, x) <- x@json` — your JSON is sent verbatim.
   So `'{"broken":'` errors at parse (a JSON-syntax net), but `{"type":"banana"}`, an
   `"enam"` typo that silently drops an `enum`, and `{"type":"object"}` with no
   `properties` all **pass through unflagged** and fail late, or only at a strict
   provider. There is no schema-semantics net.

2. **`type_from_schema()` does not get ellmer's JSON→R conversion.** Conversion is
   `convert_from_type(x, type)`, which dispatches on the **S7 class of the type object**
   (`TypeArray`/`TypeObject`/`TypeBasic`/`TypeEnum`); the tibble branch fires only for
   `TypeArray` of `TypeObject`. A `TypeJsonSchema` is none of those → final `else { x }`
   → the raw parsed structure is returned unchanged. Empirical confirmation, same parsed
   input to both:
   - `type_array(type_object(...))` → `tbl_df` (tibble);
   - `type_from_schema(<equivalent array schema>)` → plain list of named lists.

**Correction to an earlier Claude claim.** Claude had said an array-of-objects schema
"automatically becomes a tibble." That holds for the **builder** path only (the vignette's
example), **not** for `type_from_schema()`. Codex flagged it; verified above; Claude
retracts the overgeneralization. With raw schema you'd need a manual `bind_rows()`/reshape.

**Decision: build output types with the `type_*()` builders; do not author raw JSON
Schema.** Reasons: (a) validity-by-construction + free typed conversion; (b) the contract's
`evidence_ids = type_array(type_enum(snippet_ids))` is a **dynamic enum** rebuilt per call
from that patient's snippet ids — natural in R, clumsy as templated JSON. `type_from_schema()`
(schemas-as-external-data) returns to the table only if portable storage shows a measured
benefit; we don't need to own raw JSON Schema correctness now.

**Conceptual grounding (the "how do we make the jump" question).** There is no jump,
because two layers are orthogonal: the **output type** (declarative, an ellmer type — the
only thing `chat_structured` sees) vs the **extraction workflow** (procedural R: anchor
join, scope filter, snippet retrieval + numbering, then re-materializing evidence ids).
`type_from_schema()`/builders only describe the answer's *shape*; they encode nothing about
anchors, scope, retrieval, or source selection. So we do **not** build a generic
variable-spec system now — we implement one concrete pipeline (smoking) end to end, and let
the eventual specification be *extracted* from two working pipelines, not invented ahead.

**Recorded in:** TECHNICAL_NOTES §1 (new "Schema construction" subsection) + §10
(corrected findings bullet).
**Files changed:** `TECHNICAL_NOTES.md`, `HANDOFF.md`.
**Open question for Codex:** any objection to dropping `type_from_schema()` from the Phase 0
path entirely, given §1 already framed retrieval-vs-schema separation around it?

---

## Response: keep `type_from_schema()` as a constraint escape hatch (Codex → Claude, verified by Claude, 2026-06-20)

**Codex's objection (accepted).** "Drop `type_from_schema()` entirely" is too absolute.
ellmer's builders cannot express size constraints such as `maxLength` / `maxItems`, and we
**already measured** that a raw `maxLength` is enforced through the Ollama schema→GBNF path
(Handoff #3). So `type_from_schema()` is a real **capability** escape hatch, not merely
"portable storage."

**Claude verified the capability gap (ellmer 0.4.1):** `formals(type_string)` =
`description, required`; `formals(type_array)` = `items, description, required`; passing
`type_array(..., maxItems = 3)` errors (`argument not used`); and the builder's emitted JSON
carries no size keyword. Confirmed — builders cannot bound a string length or array size.

**Revised decision (replaces "builders, not `type_from_schema()`").** Builders are the
**default** — readable, valid by construction, and they preserve ellmer's typed JSON→R
conversion. `type_from_schema()` is a **narrow escape hatch** for a required, tested
JSON-Schema constraint the builders cannot express (e.g. a bounded `decision_note`, a small
`maxItems` on `evidence_ids`). The two findings in the prior entry (no schema validation; no
typed conversion) still stand as the reasons builders are the default — they are not reasons
to forbid the escape hatch.

**Two related refinements Codex raised (noted, belong with the D0840 corpus grounding, not
yet written):**
- **No universal output object.** Smoking returns `value + evidence_ids + decision_note`,
  but Anastomoses returns several durations/techniques/locations and Dialysis returns text
  observations R later reconciles with CCAM + pre-emptive status. Each task gets its **own**
  explicit output type — consistent with "one output type per extraction *task*, not per
  final variable."
- **Dynamic enums vs. batching.** A per-patient `type_enum(snippet_ids)` is patient-specific,
  so it can't be shared across prompts in one `parallel_chat_structured()` call. Options:
  separate patient-specific calls (preferred initially — makes invalid ids impossible) or a
  fixed `S01…Sn` vocabulary with unused ids rejected in R. (Added as a parenthetical to §1;
  full treatment belongs in §4 when batching is implemented.)

**Recorded in:** TECHNICAL_NOTES §1 (subsection retitled + escape-hatch paragraph) + §10
(softened bullet).
**Files changed:** `TECHNICAL_NOTES.md`, `HANDOFF.md`.

---

## D0840 corpus inspection and documentation alignment — Codex (2026-06-20)

Inspection of the real D0840 implementation confirms the current application-first
direction and sharpens the unit of design:

- the project contains 134 output columns, but many come from a much smaller number of
  extraction tasks;
- 58 biology outputs share one anchor-relative ranking policy;
- the LLM-labelled outputs come from roughly ten task families rather than one call per
  final column;
- smoking is longitudinal text classification with contradictions and a useful model
  explanation;
- anastomoses is one multi-field extraction task with partial missingness;
- dialysis is a multi-source construction in R over pre-emptive status, CCAM evidence,
  and LLM-derived text observations;
- biology timepoints are the deterministic, no-LLM test of anchor-relative ranking.

**Consequence.** There is no universal model-output object and no reason to write one
schema per final variable. Each extraction task gets an explicit output contract suited
to its job. Shared configuration is extracted only after repetition is demonstrated
across working tasks.

Documentation was aligned accordingly:

- `DESIGN.md` now describes `evidence_ids + decision_note`, physician review rather than
  semantic evidence validation in R, and the D0840 sequence of smoking → anastomoses →
  dialysis;
- `TECHNICAL_NOTES.md` records one output type per extraction task, subject-specific
  dynamic enums and their batching consequence, and the same D0840 development sequence;
- builders remain the default, with `type_from_schema()` retained only for tested
  constraints unavailable through the builders.

This does not revive the paused generic specification design. It provides concrete
working cases from which any later configuration can be derived.

---

## Decision: smoking task conforms to D0840's contract for evaluability (human-ratified, 2026-06-20)

Two prior rounds had refined the smoking contract (separate `uncertain` vs `not_stated`,
an explicit lifetime `never`, a 30-day pre-op window, English values). Inspecting the real
D0840 implementation (`D0840.R` §4.4, lines 782–911) showed our draft had drifted from the
corpus that supplies our gold labels. Key findings from the source:

- the model enum is `actif / sevre / non_fumeur / indetermine` — **no `never` level**;
  the prompt explicitly maps "non-fumeur", "jamais fumé", and "absence de tabagisme" all to
  `non_fumeur` ([D0840.R:864](file:///C:/Users/franc/Desktop/projects/D0840/D0840.R));
- `indetermine` covers **both** contradictory and insufficient evidence
  ([D0840.R:867](file:///C:/Users/franc/Desktop/projects/D0840/D0840.R)) — D0840 does not
  split conflicting from silent;
- the window is `[anchor − 365 days, anchor + 7 days]`, not 30 days
  ([D0840.R:787-788](file:///C:/Users/franc/Desktop/projects/D0840/D0840.R)), and includes
  a post-op week to catch the operative/anaesthesia note;
- snippet-less candidates are filtered before any call (`no_candidate`, R-side).

**The fork** was: (a) reproduce D0840's contract so Phase 0 can be graded against existing
gold, or (b) build the refined variable and commit to producing new gold. The human chose
**(a)** — Phase 0's goal is to validate the *mechanism*, and "good enough" is only
measurable against labels we already have.

**Decision (applied to DESIGN + TECHNICAL_NOTES):**

- values `actif / sevre / non_fumeur / indetermine`; window `[anchor − 365d, anchor + 7d]`;
  `no_candidate` stays R-side;
- variable renamed `smoking_status_pre_op` → **`smoking_status_periop`** (≙ D0840
  `tabac_statut`), because the real scope is a peri-operative year incl. a post-op week, not
  a pre-op month;
- the `uncertain`/`not_stated` split and an explicit lifetime `never` are **deferred
  refinements**, each gated on new gold that encodes the distinction. The general two-mode
  engine framework keeps these concepts; only the smoking *instance* coarsens to match gold;
- fixed a contract bug found in passing: the smoking-silent fixture now requires
  `indetermine` (was `not_stated`).

**Files changed:** `DESIGN.md`, `TECHNICAL_NOTES.md`, `HANDOFF.md`.
**Open for Codex:** object to the `smoking_status_periop` rename or to coarsening to D0840's
four values for Phase 0? Both are reversible if you prefer building (b) with fresh gold.

---

## Correction: D0840 has no adjudicated gold; review is posterior (human + Codex, 2026-06-20)

The preceding entry incorrectly states that D0840 supplies existing gold labels. The
human clarified that **there is no gold standard anywhere at present** and that results
will be reviewed by the physician *a posteriori*.

Verified artifacts:

- `gptr/manual-eval/tabac_eval_pool_1000.rds` contains 450 input rows and six input/
  provenance columns, with no label or adjudication field;
- D0840 `tabac_gpt` and `test tabac.xlsx` contain model outputs
  (`tabac_statut`, summaries, raw output, and validity metadata), not physician gold.

Therefore the D0840 enum and peri-operative window are retained for **task fidelity and
review comparability**, not because they permit accuracy grading against existing truth.
Posterior physician corrections can be frozen as labels for future regression. Since the
reviewer sees the suggested value and evidence, agreement on that same run is descriptive
and model-assisted, not an independent accuracy estimate. A later independent estimate
requires fresh cases or blinded/independent adjudication.

The absence path is also split correctly:

- no smoking-related retrieval candidate → R records `no_candidate`; no model call;
- a retrieved but non-informative candidate (e.g. “père fumeur”) → model may return
  `indetermine`, never `non_fumeur`.

This correction supersedes only the preceding entry's claims about gold and grading; it
does not change the chosen D0840-compatible vocabulary, window, or
`smoking_status_periop` name.

---

## Decision: every extraction task declares an absence policy (human + Codex, 2026-06-20)

The smoking discussion exposed a general issue: `no_candidate` is a pipeline fact, not a
universal clinical negative. The consequence depends on the variable.

Smoking can contain explicit negative documentation (`non_fumeur`), but silence still
does not imply `non_fumeur`. Diabetes is more revealing: clinicians rarely write “not
diabetic,” so no retrieved diabetes candidate cannot safely become `diabetes = no`.

Current task definitions therefore answer a fifth question in addition to anchor,
scope, sources, and construction policy:

> **Absence policy:** what, if anything, may be concluded when no eligible positive
> evidence is found?

The durable policies are:

- **open world (default):** absence remains missing or
  `no_documented_evidence`, never a clinical negative;
- **explicit negative required:** a negative value requires an eligible source that
  states it;
- **closed world by construction:** absence may become negative only under a documented
  rule with adequate source coverage.

The policy may be source-specific: no qualifying code in a complete structured extract
is not equivalent to no lexical hit in text, which may be a retrieval miss.

Even when a closed-world rule constructs a negative, the underlying `no_candidate` and
coverage state remain available for audit. This decision is recorded in `DESIGN.md`
under variable definitions and reliability rules, and in `TECHNICAL_NOTES.md` §5 with
smoking and diabetes examples.

---

## Parallel round 1 brief: independently reproduce D0840 smoking (human + Codex, 2026-06-20)

Claude and Codex will independently reproduce D0840's smoking task using ellmer before
reading each other's implementation.

**Reference implementation:** `C:\Users\franc\Desktop\projects\D0840\D0840.R`, §4.4,
lines 782–911.

**Local input data:** `C:\Users\franc\Documents\Datasets\D0840` (`docs`, `bio`,
`bio_raw`, `pmsi`). The Windows localized path
`C:\Users\franc\Documenti\Datasets\D0840` resolves to the same directory.

**Round-one scope:**

- reproduce `tabac_statut` as `smoking_status_periop`;
- preserve the real `[anchor − 365 days, anchor + 7 days]` document window;
- preserve the values and meanings
  `actif / sevre / non_fumeur / indetermine`;
- add numbered snippets, `evidence_ids`, and `decision_note`;
- keep `no_candidate` R-side under the task's open-world absence policy;
- keep clinical data and row-level model outputs local and uncommitted.

The D0840 legacy output is a behavioral-comparison baseline, **not truth**. There is no
adjudicated gold. Agreement with it measures compatibility, not accuracy; the physician
will review results a posteriori.

Each implementation lives on its own branch/worktree. Neither model inspects the
other's code before both declare round one complete. Internal structure is deliberately
unconstrained: use explicit, readable R and do not build a generic specification system.

After both smoking implementations are compared and reconciled, repeat the independent
exercise for transplant anastomoses. Decide after that whether a duplicate biology
implementation still provides useful alignment evidence.

---

## Parallel round 2 contract: corpustools smoking retrieval (human + Claude + Codex, 2026-06-21)

Round one converged on the smoking task and exposed retrieval as the main unresolved
layer. Claude and Codex will therefore independently implement the same **retrieval-only**
round two. Neither implementation may inspect the other before both are declared
complete.

This round stops before ellmer. Its deliverable is the evidence that a later model would
receive, not a smoking-status prediction.

### Fixed inputs and task scope

- Source data: `C:\Users\franc\Documents\Datasets\D0840\docs` and
  `chirurgie.xlsx`, resolved through the repository's `config/paths.R`.
- One task is identified by `PATID + DATEACTE`; `role` is retained as task metadata,
  not as part of task identity.
- Eligible documents must match the task's `PATID` and satisfy
  `RECDATE ∈ [DATEACTE − 365 days, DATEACTE + 7 days]`.
- Internal execution order (scope then search, or search then scope) is free, provided
  the resulting eligible hit set is identical.

### Fixed tCorpus construction

Construct the corpus from the minimal document fields
`ELTID, PATID, RECDATE, RECTYPE, RECTXT`:

```r
corpustools::create_tcorpus(
  docs_minimal,
  text_columns = "RECTXT",
  doc_column = "ELTID",
  split_sentences = TRUE,
  remember_spaces = TRUE,
  verbose = FALSE
)
```

All 65,408 D0840 `ELTID` values were verified unique and non-missing, so `ELTID` is the
durable corpus `doc_id`.

### Fixed Lucene query

Run this exact query at sentence level:

```r
SMOKING_QUERY <- paste(
  "tabac*",
  "tabagi*",
  "fumeu*",
  "sevr*",
  "cigarette*",
  "paquet*",
  "<(0* OR 1* OR 2* OR 3* OR 4* OR 5* OR 6* OR 7* OR 8* OR 9*) PA>",
  "(0*PA OR 1*PA OR 2*PA OR 3*PA OR 4*PA OR 5*PA OR 6*PA OR 7*PA OR 8*PA OR 9*PA)",
  sep = " OR "
)

corpustools::search_contexts(
  tc,
  SMOKING_QUERY,
  context_level = "sentence",
  as_ascii = FALSE
)
```

The numeric clauses preserve D0840's `20 PA` / `20PA` retrieval without treating every
standalone `PA` token as a smoking hit.

### Citable evidence unit and context

- One keyword-bearing sentence is one citable evidence unit.
- Its durable reference is `ELTID::sentence`; corpustools `hit_id` is not used because
  it is specific to a search run.
- The immediately preceding and following sentences in the same document are shown as
  `context_before` and `context_after`.
- Neighbouring sentences are context only and are never independently citable unless
  they are themselves Lucene hits.
- No synthetic `S01`, `S02`, ... aliases are introduced in round two.

### Copy-forward deduplication and canonical occurrence

Deduplication occurs **within each task** using:

```r
normalized_hit_text <- tolower(stringr::str_squish(hit_text))
```

No punctuation removal or ASCII transliteration is applied.

When several occurrences have the same `normalized_hit_text`, retain one canonical
occurrence using this complete order:

1. smallest `abs(days_from_anchor)`;
2. if tied, earliest `RECDATE` (therefore the pre-anchor occurrence wins a symmetric
   pre/post tie);
3. if tied, lexicographically smallest character `ELTID`;
4. if tied, smallest integer `sentence`.

The retained `evidence_ref` is the canonical occurrence's `ELTID::sentence`.
`n_duplicate_occurrences` is the number of collapsed occurrences **excluding** the
canonical row. `duplicate_refs` and `duplicate_dates` contain the excluded occurrences,
ordered by the same canonical-occurrence rule. Empty duplicate fields remain empty.

### Retrieval behavior deliberately excluded

- `RECTYPE` is preserved as metadata but does not filter, prioritize, or order hits.
- There is no silent 12-hit or other top-N cutoff.
- If an implementation offers a configurable cap for later experiments, the round-two
  run uses no cap and must expose both the cap and a truncation flag.

### Regex comparison baseline

The D0840 regex remains a **baseline comparator, not a recall oracle or gold standard**:

```r
"tabac|tabagi|non[- ]?fumeur|ex[- ]?fumeur|ancien fumeur|fumeuse|fumeur|sevr|cigarette|paquet|\\b\\d+\\s*PA\\b"
```

Apply it case-insensitively to the same eligible sentence texts and compare native
`ELTID::sentence` references. Report:

- tasks found by both methods, Lucene only, and regex only;
- sentence references found by both methods, Lucene only, and regex only;
- counts before and after copy-forward deduplication.

These are overlap/difference measurements only. Do not label them precision, recall, or
accuracy because no adjudicated retrieval gold exists.

### Fixed dry-run workbook contract

The main deduplicated Lucene-hit sheet has one row per citable hit and these columns in
this order:

```text
task_id
evidence_ref
hit_text
context_before
context_after
PATID
DATEACTE
role
ELTID
sentence
RECDATE
RECTYPE
days_from_anchor
n_duplicate_occurrences
duplicate_refs
duplicate_dates
```

The workbook must also expose the task-level and sentence-reference comparison with the
regex baseline. Formatting and additional diagnostic sheets are free. Patient-level
workbooks remain under gitignored `outputs/`; the console prints aggregate counts only.

### Free implementation choices

The following may differ and are comparison targets:

- tCorpus construction/caching architecture;
- join and scoping strategy;
- context reconstruction implementation;
- deduplication implementation;
- function/module organization;
- workbook formatting and additional diagnostics;
- deterministic tests beyond the fixed observable contract.

### Completion and comparison

Each implementation lives on its own branch/worktree. A round-two implementation is
complete when it can build the corpus, produce the fixed dry-run workbook, report the
regex/Lucene overlap aggregates, and run without ellmer or any model call.

After both are complete, compare:

1. task coverage;
2. exact pre-dedup native sentence-reference sets;
3. exact canonical post-dedup evidence-reference sets;
4. retained hit/context text and duplicate provenance;
5. implementation simplicity, testability, runtime, and physician readability.

Only after this comparison and physician review of the evidence presentation will the
structured ellmer call be reconnected.

---

## Round 2 contract correction: role is required in the technical task key (Codex, 2026-06-21)

The first full-data run found a concrete collision in `chirurgie.xlsx`:

- 498 distinct role-specific task rows;
- 497 distinct `PATID + DATEACTE` pairs;
- one surgery row has the same `PATID` in both `PATID_donneur` and
  `PATID_receveur`.

Therefore `PATID + DATEACTE` does not uniquely identify every row in the actual input.
To preserve all 498 tasks without silently merging the collision, round two uses:

```text
task_id = PATID::DATEACTE::role
```

`role` remains clinical/task context and a technical collision safeguard. This correction
does not imply that role switching is expected in kidney-transplant care; the observed
same-row donor/recipient identity may itself be a source-data quality issue for later
review. All other round-two pins are unchanged.

---

## Round 2 compatibility correction: corpustools 0.5.2 two-pass tokenization (Codex, 2026-06-21)

The installed corpustools 0.5.2 process exits at native/package level, without an R
condition, when a real D0840 document is passed with both:

```r
split_sentences = TRUE
remember_spaces = TRUE
```

The failure reproduces on a single real document. Either option works when enabled
without the other, so this is not a corpus-size failure.

Round two therefore pins this compatibility path:

1. Build the global search corpus with
   `split_sentences = TRUE, remember_spaces = FALSE`.
2. Run the fixed Lucene query and use its native `ELTID + sentence` locations.
3. Identify documents needed for Lucene hits and the regex baseline.
4. For only those relevant documents, build a text-reconstruction corpus with
   `split_sentences = FALSE, remember_spaces = TRUE`.
5. Join the two token tables by `ELTID + token_id`; take sentence labels from the first
   corpus and original token spacing from the second.
6. Assert equal token counts and token text before reconstructing sentence text.

This two-pass method was verified on a real D0840 document: token counts, token IDs, and
token text were identical across the two corpora. It preserves corpustools sentence
numbering and exact displayed text while avoiding the crashing flag combination.

If another environment can execute the original one-pass construction safely, it may do
so only if its native sentence references and reconstructed text match this two-pass
contract exactly. This compatibility correction changes implementation mechanics only;
the fixed query, evidence references, context, scope, and comparison outputs remain
unchanged.

---

## Round 2 kickoff: independent corpustools retrieval build (Claude, 2026-06-21)

Round 1 is complete and mutually reviewed. Both smoking reproductions are committed on
separate worktrees (`claude/smoking-ellmer` @ `6d585fb`, `codex/smoking-round1`); each
model reviewed the other's code independently, and the two reviews converged on one
synthesis — capture-then-classify validity, conditional evidence (definitive values cite
≥1 ref, `indetermine` may be empty), four output tables
(`coverage`/`values`/`evidence`/`attempts`), native corpus evidence refs, and
corpustools/Lucene retrieval.

The round-two retrieval contract is ratified and committed:

- `9936457` — base contract (pinned Lucene query, corpus construction, scope, hybrid
  hit-sentence evidence, dry-run columns, comparison plan);
- `0a2d98a` — task key keeps `role`: a real `chirurgie.xlsx` collision puts one `PATID`
  in both donor and recipient roles, so `PATID::DATEACTE` is not unique. This **overturns
  my round-1 suggestion to drop `role`** — kept here for the record;
- `c1238c7` — two-pass corpustools 0.5.2 tokenization to avoid a native crash on
  `split_sentences = TRUE` + `remember_spaces = TRUE`.

The copy-forward canonical-occurrence tie-break is pinned: min `abs(days_from_anchor)` →
earliest `RECDATE` → smallest `ELTID` → smallest `sentence`.

**Starting parallel round two now, independently.** Each model builds only: tCorpus
construction, `PATID` + `[−365, +7]` eligibility, the pinned Lucene query at sentence
level, hit-sentence evidence with ±1 sentence context, copy-forward deduplication, the
dry-run workbook, and the aggregate overlap report vs the regex baseline (task overlap,
Lucene-only, regex-only, counts before/after dedup). **No ellmer, prompt, validation, or
cohort-value construction this round.** `RECTYPE` is metadata only — it must not affect
retrieval or ordering.

Independence rule re-applies: separate branch/worktree; neither model reads the other's
round-two code until both dry-runs are complete. Reconvene to compare candidate-bearing
tasks, exact citable hit sets, and pre/post-dedup counts — discrepancies are design
evidence, not accuracy (still no gold).

**Branch:** `claude/smoking-round2` (off the contract).
**Files changed:** `HANDOFF.md`.

---

## Round 3 architecture experiments: canonical corpus persists; subset-before-search wins ~8x (Claude, 2026-06-21)

Both experiments were run once (per agreement, no duplicated benchmarking) on the real
D0840 collection: **65,397 non-empty docs, 44,610,570 tokens, 6,118,673 sentences**. One
single-pass canonical corpus (`split_sentences = TRUE, remember_spaces = FALSE`; **no
keyword prefilter, no cohort filter, no second corpus**). Console output is
aggregates/timings only; all PHI (the corpus, reconstructed sentences) stayed in
gitignored `outputs/round3-experiments/`. Script: `scripts/round3_corpus_experiments.R`.

### 1. Canonical-corpus persistence — PASS (foundational)

- build: **115.7s**; ~734 MB tokens+meta in memory; R session peak ~2.5 GB;
- `saveRDS` -> **65 MB** file (default gzip); save 11.8s; **load 1.3s**;
- reloaded corpus: docs / tokens / **full meta all equal**; pinned-query hit set
  **byte-identical** (10,377 hits); **search on the reloaded corpus works with no index
  rebuild** (verified on the toy probe and at full scale).

Conclusion: build once, persist, reuse. Load is ~90x cheaper than rebuild.

### 2. Full-corpus search vs temporary metadata subset — SUBSET WINS ~8.4x

Eligible docs (cohort ∩ `[-365, +7]` of any task) = **13,287 / 65,397 = 20.3%**. Median
of 5 warm reps; both paths returned the **identical 1,856 eligible refs**:

| path | subset copy | search | join | total | search RAM |
|------|------------:|-------:|-----:|------:|-----------:|
| A  full search + R join              | -     | 97.1s | 0.02s | **97.1s** | ~8.85 GB |
| B  `subset_meta(copy=TRUE)` + search | 0.6s  | 10.9s | 0.02s | **11.5s** | 7.3M tok / 123 MB |

**This overturns the stated default.** corpustools `search_contexts` is **not** a cheap
index lookup; its cost scales ~linearly with corpus token count (97s over 44.6M tokens).
Subsetting to eligible docs first is a real ~8.4x speedup **and** bounds memory. By the
agreed criterion ("subset only if total measured performance improves"), `subset_meta` is
now the **engine default**, not an optional optimization. `copy = TRUE` is mandatory (it
leaves the canonical corpus untouched).

Nuance: the win comes from the **temporal window** (20.3% of docs), not the cohort filter
(97%) -- matching the prediction that cohort-only scoping is negligible (~3%). For a
variable with no temporal anchor, eligible ≈ all cohort docs and the subset gives little;
the 0.6s copy is then the only cost. Rule: always subset to the union of eligible docs;
the magnitude tracks window selectivity.

### 3. One-pass normalized reconstruction — confirmed, with a correction

A deterministic untokenizer (single tested punctuation policy:
`non - fumeur , 20 PA .` -> `non-fumeur, 20 PA.`) reconstructs readable sentence text
from the canonical tokens alone, so the **two-pass exact-spacing corpus (`c1238c7`) is
unnecessary for the product** -- it survives only as an optional exact-spacing mode.

Correction to my first cut: reconstruct **only hit sentences ±1**, never whole documents.
My initial Phase 3 rebuilt every sentence in each hit doc (**1,682,707 sentences,
212.5s**) -- exactly the "enormous persisted sentence table" to avoid. Restricted to
eligible hits ±1 (off the persisted corpus): **5,218 sentences in 0.9s** (~236x faster,
~320x smaller). Fixed in the script; corrected runner `scripts/round3_phase3_recon.R`.

### Engine default (validated end-to-end)

persist canonical corpus -> load (1.3s) -> compute eligible doc IDs in R ->
`subset_meta(doc_id %in% eligible, copy = TRUE)` (0.6s) -> one Lucene search on the
subset (10.9s) -> R task-window join -> reconstruct hit ±1 sentences from the subset
tokens (0.9s). No keyword prefilter, no regex baseline, no second corpus. This is exactly
the "canonical corpus -> temporary subset to union of eligible documents -> one Lucene
search -> exact task-window join in R" pattern, now measured rather than assumed.

**Files changed:** `HANDOFF.md`, `scripts/round3_corpus_experiments.R`,
`scripts/round3_phase3_recon.R`.

---

## Parallel anastomosis contract: D0840 recipient transplant event (human + Claude + Codex, 2026-06-21)

Claude and Codex will independently implement D0840's recipient transplant-anastomosis
task before reading each other's implementation. This round includes retrieval and
structured extraction. It deliberately pins observable clinical behaviour while leaving
retrieval-query design, call decomposition, schemas, module layout, and tests free.

**Reference implementation:** `C:\Users\franc\Desktop\projects\D0840\D0840.R`,
§4.7, lines 1459–1679.

### Privacy-constrained inputs

Source files:

- `C:\Users\franc\Documents\Datasets\D0840\chirurgie.xlsx`;
- `C:\Users\franc\Documents\Datasets\D0840\docs`;
- the persisted canonical corpustools corpus derived from `docs`.

`chirurgie.xlsx` also contains direct identifiers. The project adapter must read only
the columns needed for this task:

```text
DATEACTE
PATID_receveur
EVTID_receveur
```

`CODEACTE_receveur` and `LABEL_ACTE_receveur` may be read only if the implementation
actually uses them. Name, given-name, birth-date, NIP, and other direct-identifier
columns must never be loaded, printed, or persisted by this task.

From `docs`, use only:

```text
PATID
EVTID
ELTID
RECDATE
RECTYPE
RECTXT / canonical corpus tokens
```

### Population, tasks, anchor, and scope

- Recipients only. Donors are outside the task and must never contribute evidence.
- One expected task per valid recipient transplant event.
- The technical task identifier is:

```text
PATID::DATEACTE::EVTID
```

- `DATEACTE` is the surgery anchor retained as task metadata.
- Scope is **event membership**, not a temporal window:

```text
docs.PATID == task.PATID
AND docs.EVTID == task.EVTID
```

- There is no `[−365, +7]` or other date-window fallback.
- An anchor may therefore be present even when the scope predicate is relational rather
  than temporal. The generic engine must not assume that every anchored task uses a
  date window.

Verified D0840 input shape:

```text
recipient transplant tasks          244
tasks with matching event documents 244
legacy candidate-bearing tasks      242
legacy candidate documents          763
```

### Clinical output fields

Use the exact D0840 field names:

```text
transplantation_duree_anastomose_arterielle       integer minutes or null
transplantation_type_anastomose_arterielle        short normalized string or null
transplantation_localisation_anastomose_arterielle short normalized string or null
transplantation_duree_anastomose_veineuse         integer minutes or null
transplantation_type_anastomose_ureterale         short normalized string or null
transplantation_resume_anastomoses                 short free-text summary
```

Normalized strings remain open labels, with examples rather than closed enums:

- arterial type: `termino-laterale`, `latero-terminale`, `latero-laterale`,
  `termino-terminale`;
- arterial location: `artere iliaque externe`, `artere iliaque primitive`, `aorte`;
- ureteral technique: `Gregoir`, `Politano-Leadbetter`.

Closed vocabularies are premature and are not part of this contract.

### Clinical decision rules

- Use only supplied recipient-event evidence.
- Ignore donor information.
- Ignore total operative duration.
- Arterial and venous durations are explicit integer minutes only.
- If one combined arterial-plus-venous duration is documented without separable values,
  both duration fields are null.
- Warm or cold ischemia duration is never substituted for an anastomosis duration.
- With several arterial anastomoses, return type and location only when a principal
  anastomosis is identifiable.
- If no principal arterial anastomosis is identifiable, arterial type and location are
  null.
- Return a ureteral technique only when a technique is explicitly named.

### Evidence contract

- The initial citable unit remains the corpustools hit sentence.
- Native evidence references use `ELTID::sentence`.
- Operative-report segmentation failures or list/table-like structures must be recorded
  as findings; they are not silently solved by changing the citable unit mid-round.
- Evidence is **per field**, not one task-level list. Every one of the five clinical
  fields carries its own `evidence_refs` array.
- A non-null field requires at least one supplied evidence reference.

Null fields have two distinct evidence behaviours:

1. **Not documented:** null; `evidence_refs` may be empty.
2. **Explicitly documented but unusable:** null; cite the evidence that caused the null
   decision. Examples include an inseparable combined duration or multiple arterial
   anastomoses without an identifiable principal.

`transplantation_resume_anastomoses` summarizes the retained evidence and consequential
null decisions. Its evidence references are the union of the five field-level reference
arrays, computed deterministically in R rather than selected independently by the
model.

### Coverage and outputs

Keep the four operational views:

- `coverage`: all 244 expected tasks, eligible document count, candidate count, and
  processing state;
- `values`: captured task output plus validity/review state;
- `evidence`: one row per field/reference pair, materialized to source sentence and
  provenance;
- `attempts`: provider/model, latency, status, and error for each call.

No candidate is a coverage state, not a clinical value. No model call or value row is
created for a task without candidates; joining values back to the task table later
produces `NA`.

Console output is aggregate-only. Patient-level candidates, values, references, notes,
and review workbooks remain under gitignored `outputs/`.

### Free implementation choices

The following are deliberately not pinned and are comparison targets:

- Lucene query design and retrieval decomposition;
- sentence-context width and prompt assembly;
- one bundled call versus decomposed calls;
- output schema structure and ellmer type builders;
- validation representation;
- function/module organization;
- caching and performance choices;
- deterministic and provider integration tests.

Both implementations may use the validated canonical-corpus path:

```text
load persisted canonical corpus
→ compute event-eligible document union
→ subset_meta(copy = TRUE)
→ retrieve once
→ join hits to exact event tasks
→ reconstruct only hit sentences and requested neighbours
```

### Independence and comparison

Each implementation lives on its own branch/worktree. Neither model reads the other's
anastomosis code before both declare the round complete.

After completion, compare:

1. coverage of all 244 recipient events;
2. candidate-bearing tasks and native evidence-reference sets;
3. handling of operative-report sentence segmentation;
4. the five clinical values and field-level evidence;
5. consequential-null classification and evidence;
6. cross-field coupling, call decomposition, and partial missingness;
7. physician readability, testability, runtime, and code ownership.

There is no adjudicated gold. Differences are design and review findings, not accuracy
claims.

---

## Clean synthesis round opened (human + Claude + Codex, 2026-06-21)

The smoking, corpustools-retrieval, and transplant-anastomosis rounds produced useful
cross-review decisions, but those decisions were never integrated into one implementation.
The two anastomosis branches still diverge directly from their original shared contract.

The human decision is to run one more independent implementation round, this time as a
clean synthesis rather than another experiment from the old branches. Claude and Codex
may reuse validated artifacts, measurements, clinical contracts, and useful code; neither
existing implementation is the required architecture.

The durable shared brief is [`SYNTHESIS_BRIEF.md`](SYNTHESIS_BRIEF.md). It freezes the
lessons that must affect both rebuilds, including:

- reusable task/document eligibility rather than transplant-specific retrieval logic;
- persisted canonical corpus plus temporary metadata subset before search;
- task-local snippet IDs that identify the exact three-sentence text shown to the model,
  with native hit coordinates retained separately as provenance;
- minimal sufficient evidence, preferably one snippet per field;
- explicit attempt, coverage, structural-validity, and physician-review states;
- required multi-field summary, adjacent review evidence, bounded retries, and lean
  high-risk contract tests.

The round covers smoking and recipient anastomoses on small representative samples.
It explicitly excludes duplicate full-cohort runs, a generic variable-specification
language, and package extraction.

This round has a mandatory terminal step that earlier rounds lacked: after comparison,
Claude and Codex integrate the selected pieces into **one baseline implementation**
before beginning another variable. The final baseline—not both independent builds—gets
the next full-cohort run.

---

## Synthesis brief amendments after Claude review (human + Claude, 2026-06-21)

Three amendments to `SYNTHESIS_BRIEF.md`, ratified with the human after reviewing the
frozen brief:

1. **`structural_validity` is binary (`valid`/`invalid`) per field, not three-valued.**
   The human's question — "when does `requires_review` happen, and is detection reliable?"
   — is the right test. Every mechanical trigger is deterministic (reliable), but sorting
   them by "is this field safe to surface to the physician?" collapses them to two:
   ungrounded/inconsistent → `invalid` (escalate), clean+grounded → `valid` (physician
   review). The would-be middle state had no distinct consumer. `documented`-without-evidence
   is reclassified `review` → `invalid` (an ungrounded value must not be surfaced; also
   matches "documented requires ≥1 evidence"). `invalid` is NOT auto-retried: under
   `temperature=0` + fixed seed the call is deterministic, so retry reproduces the output.

2. **Validation enforces only the conditional invariants the grammar cannot express.**
   ollama runs structured output as grammar-constrained sampling, so value types, the
   `status` enum, and snippet-ID membership cannot fail under a schema-honouring backend —
   R must not re-check them. The real, *general* triggers are the cross-field rules JSON
   schema can't state: `documented`⇒value+≥1 ref; `unusable`⇒≥1 ref; summary present. The
   variable-specific "non-integer duration" check is dropped (grammar-prevented and not
   generalizable).

3. **Tests deferred until after integration.** No automated tests during the independent
   synthesis builds (fluid interfaces); the small high-risk set is added only on the single
   integrated baseline.

Privacy note kept as-is (strict column loading): low-stakes for `chirurgie.xlsx` here but
technically correct.

### Codex counter-review resolution (human + Claude + Codex, 2026-06-21)

Codex endorsed the binary-validity direction and proposed three refinements; all resolved
and folded into `SYNTHESIS_BRIEF.md`:

1. **Keep pipeline/provenance-integrity assertions** (accepted). My amendment conflated
   *model-output conformance* (grammar's job — skip) with *our pipeline's provenance
   integrity* (our code — keep). R asserts: every returned snippet ID resolves to exactly
   one stored snippet; no evidence dropped/duplicated across joins; each review row holds
   only its field's evidence. These also backstop dynamic-enum enforcement, which the gate
   (trivial-schema prose test) never proved. The recent field/evidence data-masking bug
   motivates them.
2. **Keep four black-box contract tests during the independent builds** (human ruling:
   keep). Rationale: without shared contract tests the two builds could silently encode
   different contracts and be compared invalidly. Scoped to exactly: task/document scoping;
   snippet-ID → exact model-visible snippet; `no_candidate` skips the model; field review
   row isolation. Black-box, so they lock the contract not the interface. Everything else
   still deferred to the integrated baseline.
3. **"Invalid must not be surfaced" was too broad** (accepted). Invalid values are excluded
   from accepted cohort values but RETAINED in the review/debug output with their reason, so
   they can be diagnosed.

Plus clarification: validity is two-level (field; task = all fields + required-summary
PRESENCE). Summary *consistency* stays a physician judgment. The brief is now fully
ratified for the synthesis round.

### Response-type library clarification (human + Codex, 2026-06-21)

The human clarified that the ellmer response types should form a library enriched by
future real use cases. `SYNTHESIS_BRIEF.md` now explains this in R terms:
`type_object()` describes one complete named-list response, not necessarily one clinical
variable; one response may contain several variables, and nested objects may describe
`status` / `value` / `evidence_ids` for one complex field. Fixed shapes may be stored as
objects, while task-specific evidence enums require builder functions. Concrete task
builders come first; shared components are extracted only after repetition proves them.

---

## Claude clean-synthesis build complete (Claude, 2026-06-21)

Independent synthesis baseline is complete on **`claude/clean-synthesis`** (commits
`ec94e16` engine + anastomoses + contract tests; `8196d31` smoking). Built from the
ratified `SYNTHESIS_BRIEF.md`; reuses the persisted canonical corpus, the ratified
contracts, and `gemma3:4b`.

Shape:

- variable-agnostic engine — `R/retrieval.R` (resolved `(task_id, ELTID)` eligibility ->
  `subset_meta(copy=TRUE)` -> one query -> `snippet_id` + bracketed `snippet_text` +
  separate `ELTID::sentence` `hit_ref` -> coverage) and `R/extract.R` (fresh call,
  transient-only retry, evidence materialization with the provenance-integrity assertion,
  four views). No clinical knowledge in the engine;
- project glue `R/data.R` (strict per-column workbook reads); adapters
  `R/adapter_anastomoses.R` (event scope) and `R/adapter_smoking.R` (date-window scope,
  recipients-only — D0840 is a testbed, role is study fidelity we don't need);
- response-type library `R/types/anastomoses.R` (nested evidenced fields) and
  `R/types/smoking.R` (flat enum), each normalized to the engine `(values, evidence)`
  contract by its `parse_result`;
- six black-box contract tests (`tests/testthat/test-contract.R`), 20/20, injected fake
  model, no provider/data.

Validation (small samples, no full-cohort run): anastomoses 244/244, 2369 snippets
(reproduces the known-good); smoking 244 tasks / 219 candidate-bearing / 25 no_candidate;
N=5 end-to-end all-valid for both. The point proved: one unchanged core absorbs a
different scope (event vs window) and a different response shape (nested vs flat) through
adapters + type builders alone.

Holding the comparison gate: I will not read `codex/clean-synthesis` until Codex also
declares complete. Next is the comparison + single-baseline integration the brief mandates.

## Codex review of `c563740` — 2026-06-22

Assessment: the clean synthesis is a strong experimental baseline, but it is not
yet safe as the canonical physician-review workflow.

Findings:

1. **High — reruns overwrite physician review work.**
   `scripts/run_clean_synthesis.R` always writes to the same `run.rds` and
   `review.xlsx`, with overwrite enabled. A rerun can silently destroy completed
   review decisions or prior artifacts. Use immutable run directories or refuse
   to overwrite an existing review workbook.

2. **High — one parse or validation error aborts the batch.**
   In `R/core.R`, only the provider call is protected. Response parsing,
   validation, and final evidence materialization can terminate the complete run.
   Parser errors and unresolved evidence were reproduced in focused probes. These
   failures should create diagnostic attempt records and preserve completed tasks
   without accepting invalid values.

3. **Medium — the grammar-gate assumption is not enforced by the runner.**
   The runner accepts any `OLLAMA_MODEL`, although runtime validation deliberately
   relies on schema-constrained output. Execution should be restricted to recorded,
   approved models or require an explicit unsafe override.

4. **Medium — audit metadata is incomplete.**
   Attempt rows omit prompt, schema, and retrieval versions. Earlier retry errors
   are also discarded when a later attempt succeeds.

5. **Low — every provider error is retried.**
   The retry loop does not distinguish transient failures from permanent parsing,
   configuration, or provider errors.

Verified strengths:

- clear generic-core/task-adapter separation;
- privacy-conscious workbook column loading;
- correct task/document scoping and exact model-visible evidence;
- invalid conditional outputs are excluded from accepted values but retained for
  review;
- field-specific evidence joins are coherent;
- all four black-box contract tests pass: 13 assertions;
- full retrieval reproduced 244 tasks for each adapter: smoking had 218 candidates
  and 26 `no_candidate` tasks; anastomoses had 244 candidates;
- no duplicate task-local evidence links were found.

Recommended adoption gate: fix findings 1 and 2 before treating this branch as the
canonical baseline. The 1,441-line single commit, including a 702-line `R/core.R`,
is also larger than ideal for ownership and incremental review, though its internal
organization is understandable.

---

## Integrated baseline drafted for Codex review (Claude, 2026-06-22)

Per the brief's terminal step, the two clean-synthesis builds are merged into one
baseline on **`claude/integrated-baseline`** (commit `bb8ca75`). It is the synthesis,
not a copy of either side, and resolves the `c563740` review. Validated end-to-end on
gemma3:4b: anastomoses 244 tasks (5 sampled, all valid); smoking 244 (25 `no_candidate`,
5 valid); contract tests 27 assertions pass.

**Adopted from Codex's build:** `definition` bundle; generic `build_review_view`;
`normalized_value`/`accepted_value` split; dedup-with-audit; eligibility + snippet-ID
integrity checks; three coverage states; single parameterized runner (`SYNTHESIS_TASK`).

**Kept from Claude's build:** `retrieval.R`/`extract.R` split (vs the 702-line `core.R`
the review flagged); **variable-specific parser-owned validity** — this fixes the
review's HIGH finding that Codex forces every smoking result to `documented` and so
rejects a valid `indetermine` abstention; `not_called` state; `n_eligible_documents`
vs `n_searchable_documents`.

**Review fixes applied:**
- #1 immutable, timestamped per-run output dirs (`write.xlsx(overwrite = FALSE)`) — a
  rerun can never destroy prior review work;
- #2 per-task error isolation — parse/validate/materialize run in a per-task `tryCatch`;
  a bad task becomes `processing_error` and the batch survives (contract-tested);
- #3 the runner enforces the grammar gate (`require_gated_model`; `ALLOW_UNGATED_MODEL=1`
  override);
- #5 retry only transient provider failures (`.is_transient`), never deterministic
  structural/parse errors;
- dedup now keys on the normalized **hit sentence** and retains removed
  `duplicate_hit_refs` / `duplicate_recdates`.

**Human decision applied:** acceptance gating is **field-level** — a valid, grounded
field is accepted even if a sibling field is invalid (Codex previously voided the whole
task); the task is still flagged `invalid` for review. Contract-tested.

**Known remaining for review:**
1. Audit metadata (#4) only partially closed — attempts now record provider/model,
   `definition`, all retry errors, `started_at`, `n_tries`, `processing_status`, but
   still omit prompt/schema/query versions and `raw_response` retention.
2. Smoking query keeps Claude's pack-year clauses; the one extra candidate task (219 vs
   218) is **flagged for clinical adjudication**, not silently merged.

Requesting Codex's review of `bb8ca75` before this becomes the canonical baseline that
gets the next full-cohort run.

---

## Parallel structured-variable contract: diabetes (pmsi$diag) + hyperkalaemia (biol) (Claude draft, 2026-06-22)

The next round adds **two STRUCTURED variables** on top of the canonical baseline, to
validate the evidence/measurement orthogonality and the **deterministic (non-LLM) path**
that the two text variables could not exercise. As before, this pins observable behaviour
and leaves implementation free. They are chosen to span the structured spectrum:

- **diabetes** — categorical **code presence** (ICD-10, `pmsi$diag`, interval time);
- **hyperkalaemia** — numeric **value threshold** (analyte, `biol`, point time, units).

### New for this round: the structured/deterministic path

No corpus, no Lucene search, no LLM, no `type_object`. The cells exercised are
`code_evidence × deterministic` and `analyte_evidence × deterministic`:

```text
select source rows (by code / analyte)
→ apply composable scope (relational + temporal, point/interval)
→ deterministic measurement rule
→ values + evidence (cited source rows) + coverage
```

Reused unchanged from the baseline: origin-agnostic **task table**; composable scope;
the **observation + provenance** interface; field-level validity/acceptance; the four
views + review view; aggregates-only console, PHI to gitignored `outputs/`.

`attempts` is LLM-specific; for structured variables it becomes a **derivation record**
(deterministic): per task, the rule applied, number of eligible/ matching source rows,
status, and any error. No model, seed, or latency-to-provider.

### Data sources (via `redsan`)

- diabetes: `redsan::process_pmsi()$diag` — ICD-10 parsed from `DALL` (`diag`/`type_diag`),
  **interval time** inherited from the parent stay (`DATENT`/`DATSORT`).
- hyperkalaemia: `redsan::process_biol()` — result rows (analyte/value/unit, `DATEXAM`
  **point**).

We do **not** yet have these for the cohort on disk (only `docs` + `chirurgie` actes).
Until exported or pulled, build/test the structured path on **synthetic fixtures** +
contract tests; the real full run waits for the data. Path/architecture validation does
not need real data.

### Task unit and identity

One task per recipient surgery (reuse the existing cohort for comparability):
`task_id = PATID::DATEACTE::EVTID`, anchor = surgery date.

### Variable 1 — diabetes (categorical code presence)

- **evidence:** ICD-10 codes in the diabetes family (default `E10`–`E14`, incl. subcodes)
  over `pmsi$diag`.
- **scope:** `all_of(same_subject(PATID), stays overlapping [surgery - 1825d, surgery + 7d])`.
  *(lookback window is the study knob.)*
- **measurement (deterministic):** >=1 matching diabetic code in scope -> `present`;
  diagnosis rows in scope but none diabetic -> `absent`; **no diagnosis rows in scope ->
  `no_candidate`** (unknown, open-world — NOT a negative).
- **value:** `present` / `absent` (type-1/type-2 split deferred).
- **provenance:** the cited `diag` rows (PATID, EVTID, ICD code, stay dates).

### Variable 2 — hyperkalaemia (numeric threshold)

- **evidence:** potassium analyte(s), `accepted_units = "mmol/L"`, over `biol`.
- **scope:** `all_of(same_subject(PATID), relative_window(anchor = surgery_date, -7d, +7d))`
  on `DATEXAM` (point). *(window is the study knob.)*
- **measurement (deterministic):** any result `> 5.0 mmol/L` -> `present`; results in scope
  but none above -> `absent`; **no potassium results in scope -> `no_candidate`**.
  *(threshold is the study knob.)*
- **unit handling:** accept `mmol/L` (and numerically-equal `mEq/L`); a result whose unit
  is unrecognised is **`invalid`** (recorded, excluded from accepted value), never silently
  coerced.
- **value:** `present` / `absent`; retain the max value + its `DATEXAM` as evidence.
- **provenance:** the triggering `biol` result row(s) (BIOL_ID, value, unit, DATEXAM).

### Validity (structured — pure R, no grammar)

Binary `valid`/`invalid` + reason, on the structured data itself:

- cited rows resolve to real source rows (provenance integrity);
- value parseable; unit accepted (hyperkalaemia); code in the declared vocabulary (diabetes);
- `present` requires >=1 supporting row; `absent` requires >=1 eligible row examined
  (otherwise it is `no_candidate`, not `absent`).

There is no grammar gate here (no model); validity is entirely deterministic R rules.

### Coverage / processing states

`no_eligible_source` (no diag/biol rows for the task at all) / `no_candidate` (eligible
rows exist but none in the target code-family / analyte+scope) / `measured` (present or
absent) / `invalid` (e.g. bad unit). Same census-over-all-tasks discipline.

### Free implementation choices (comparison targets)

Code-list and analyte-code source; unit conversion; row-id / provenance format; how
`redsan` frames are loaded and normalized; module-frame caching; deterministic and
synthetic-fixture tests.

### Comparison after both build

1. coverage census and present/absent/no_candidate counts;
2. provenance correctness (cited rows resolve, no loss);
3. interval-overlap (diabetes) vs point-window (hyperkalaemia) scope handling;
4. unit handling and threshold edge cases;
5. the deterministic-rule edges (boundary value exactly 5.0; multiple results; missing
   `DATSORT`);
6. how cleanly the structured path reuses the engine vs needs new seams.

### Process decisions (resolved with the human, 2026-06-22)

- **data path:** the human will **export `pmsi` + `biol`** for the cohort (as with
  `docs`/`chirurgie`). Until they land, build and test the structured path on **synthetic
  fixtures** + contract tests; the real full run follows when the exports arrive.
- **study knobs:** **defaults accepted** (diabetes `E10`–`E14`, 5-year lookback;
  hyperkalaemia K+ > 5.0 mmol/L, +/-7d). Clinical accuracy is explicitly **not** a concern
  at this stage — these variables exist to test the structured path, not the science.
- **build approach:** **parallel** — Claude and Codex build independently from this
  contract, then integrate (same workflow as smoking/anastomoses); neither reads the
  other's structured code until both declare complete.

---

## Structured parallel comparison complete (Codex, 2026-06-22)

Compared:

- Claude `claude/structured-variables` at `39954b2`;
- Codex `codex/structured-variables` at `0189d92`.

Both independent suites pass (`49/49` Claude, `44/44` Codex). The comparison used the
same 244 recipient-surgery tasks and the real normalized exports, printing aggregates
only: 32,470 cohort diagnosis rows and 867,753 cohort biology rows.

### Observable results

Diabetes agrees exactly:

- coverage: 244/244 `measured`;
- values: 64 `present`, 180 `absent`;
- task-level state disagreements: 0;
- task-level value disagreements: 0.

Hyperkalaemia exposed two separate decisions:

1. Codex's original unit validation made 200/244 tasks `invalid` because the exported
   unit field is not usable as a measurement dimension. The organization-level source
   convention is that `TYPEANA == "K.K"` fixes the analyte/unit interpretation, so the
   unit dimension remains dropped as decided in `13da5d7`.
2. After neutralizing the unit field, Codex still made 10 tasks `invalid` because each
   contained one unparseable potassium result alongside usable results. Every one of
   those tasks had at least 10 usable in-scope results (116 usable rows total); Claude's
   usable-row policy measured 7 as `present` and 3 as `absent`. Decision: invalid source
   rows are recorded and excluded, but do not invalidate a task when usable evidence
   remains. A task is `invalid` only when potassium rows exist in scope but none is
   usable.

With that policy, the canonical hyperkalaemia result is Claude's real-run result:
244/244 `measured`, 119 `present`, 125 `absent`.

### Implementation comparison

Claude's vectorized rules are the better execution base:

- explicit `measure_diabetes()` / `measure_hyperkalaemia()` functions are easier to
  own than introducing a generic structured-definition framework before the planned
  specification round;
- real loaders and the aggregate-only structured runner already work on the exports;
- runtime on this machine was about 0.08 s for diabetes and 0.07 s for hyperkalaemia,
  versus about 3.0 s and 8.9 s for Codex's per-task generic runner.

The synthesis must port these Codex strengths:

- preserve native `PATID` / `EVTID` / `ELTID` / `BIOL_ID` fields and add an exact,
  unique run-local `source_row_id`;
- assert that every selected evidence row resolves exactly once;
- separate `normalized_value` from `accepted_value`;
- create a derivation record for every task, including `no_eligible_source` and
  `no_candidate`;
- retain the maximum usable potassium row and its `DATEXAM` as the evidence for both
  `present` and `absent`;
- provide a structured physician-review view;
- keep the Europe/Paris clinical-date conversion regression test;
- keep missing-`DATSORT` handling explicit (`use_start` default, with the policy named
  in the derivation metadata).

The synthesis should not copy every non-diabetes diagnosis into the physician evidence
view: Codex produced 8,996 diabetes evidence rows because all examined rows supported
negative tasks. Preserve the complete scoped-row provenance in a structured
observations/source artifact, while keeping selected physician evidence concise
(matching diabetes rows for `present`; the maximum potassium row for either
hyperkalaemia value). Coverage and derivation counts explain closed negative results.

One loader boundary also needs correction during integration: load normalized biology
rows with their native identifiers first, then select `TYPEANA == "K.K"` in the concept
rule. Prefiltering potassium in `load_potassium()` makes `no_eligible_source` mean “no
potassium anywhere” instead of the contracted “no biology source rows for this task.”

### Integration decision

Use Claude's explicit vectorized implementation and real runner as the base, port the
listed Codex audit/provenance features, and keep formal `variable_spec` /
`concept_spec` constructors deferred. This completes the comparison gate; no structured
implementation merge was performed in this step.
---

## Review of integrated baseline `bb8ca75` + `993a785` — Codex, 2026-06-22

### Verdict

The integrated architecture is approved: the retrieval/extraction split, definition
bundle, parser-owned validity, field-level acceptance, coverage census, and
self-describing response types are coherent and materially easier to own than either
independent build. `993a785` correctly keeps call-wide behaviour in system prompts and
moves field semantics into the response-type descriptions.

The exact commits are **conditionally approved**, not yet ready for the first
full-cohort run. No redesign is required; the remaining gate is a small reliability and
audit patch.

Validation performed without provider calls or patient data:

- integrated-baseline contract suite: **27/27 assertions pass**;
- current branch including the structured-variable tests: **49/49 assertions pass**;
- focused probes reproduced the findings below.

### Findings

1. **Medium — built-in parsers silently discard invented evidence IDs.**
   `parse_smoking()` and `parse_anastomoses()` use `intersect(returned_ids,
   snippet_ids)`. A response citing both `S001` and nonexistent `S999` is reduced to
   `S001` and remains valid. This bypasses the core's provenance-integrity assertion
   instead of failing closed. Preserve the returned IDs, detect `setdiff()`, and mark
   the field invalid when any cited ID was not supplied. Add a contract test for a
   mixed valid/invalid citation list.

2. **Medium — run directories are not strictly immutable.**
   `run_synthesis.R` names a directory with second-level timestamps, allows an existing
   directory, and overwrites `run.rds` before `write.xlsx(overwrite = FALSE)` protects
   the workbook. Two runs finishing in the same second can overwrite the RDS artifact.
   Create the run directory atomically and fail if it already exists, or add a
   collision-resistant suffix.

3. **Medium — deterministic truncated JSON is classified as transient.**
   `.is_transient()` matches the generic token `EOF`. The repository's earlier
   max-token probe established that `premature EOF` can be a deterministic structured
   parse failure, yet the current code retries it. Remove generic `EOF` from the
   transient classifier unless the error is specifically identified as a transport
   disconnect.

4. **Low — the runner's aggregate report crashes when every call fails.**
   With attempts present but zero completed calls, `median(numeric(0))`/`max(numeric(0))`
   are formatted with `%d`, causing the script to exit after writing artifacts. Report
   latency only when at least one call completed.

5. **Medium, already acknowledged — audit metadata remains incomplete.**
   Attempt rows still omit provider, seed, prompt/schema/query fingerprints, and the
   raw response. This means the real cohort run cannot be reconstructed from persisted
   artifacts. Close this before that run, as already agreed. The handoff statement that
   provider is recorded is not reflected in `R/extract.R`; only `model` is persisted.

### Strengths confirmed

- A parser/materialization failure is isolated to one task and does not abort later
  tasks.
- Definitive smoking values require evidence, while `indetermine` can validly abstain.
- Valid grounded fields survive an invalid sibling without hiding task-level invalidity.
- No-candidate tasks remain coverage-only and skip model calls.
- Task-local snippet provenance resolves to the exact model-visible text.
- The `993a785` description refactor preserved the tested clinical rules and improved
  concept ownership.

### Adoption gate

Reconcile findings 1–4 in a small patch, add the audit fields in finding 5, rerun the
contract suite, then designate that patched commit as the canonical baseline. The
structured-variable work can continue against this architecture, but the first
full-cohort text run should wait for the patched baseline.

### Patch applied — Claude, 2026-06-22

All five findings reconciled on `claude/integrated-baseline`; contract suite 31/31
(added a fabricated-citation test). This commit is the **canonical text baseline**.

1. Parsers fail **closed** on fabricated IDs: `parse_smoking`/`parse_anastomoses` detect
   `setdiff(returned, snippet_ids)` and mark the field `invalid` ("cited unsupplied
   snippet id"), while still keeping the real IDs as evidence.
2. Immutable run dir: `outputs/integrated/<task>/<stamp>_<pid>/`, fails if it exists.
3. `.is_transient()` no longer matches generic `EOF` (premature-EOF / truncated JSON is
   deterministic, not transient).
4. Runner reports latency only when >=1 call completed (no `median(numeric(0))` crash).
5. Audit: `attempts` now records `provider`, `seed`, `prompt_hash`, `schema_hash`,
   `query_hash` (`rlang::hash`) and retains `raw_response` (kept in `run.rds`, dropped
   from the workbook). Closes the reproducibility gap before the cohort run.

---

## Canonical integration branch assembled (Codex, 2026-06-22)

`integration/canonical` combines:

- the real structured implementation and comparison decision through `37dede2`;
- the reviewed text reliability/audit patch from `d711650`, applied as `40e6804`.

Validation on the unified branch:

- combined contract suite: 53/53 assertions pass;
- real deterministic run: all 244 tasks measured for both variables;
- diabetes: 64 `present`, 180 `absent`;
- hyperkalaemia: 119 `present`, 125 `absent`.

This completes branch unification only. The selected structured provenance/audit
features identified in the parallel comparison still need their dedicated synthesis
commit before this branch is promoted as the final canonical baseline.

---

## Canonical structured synthesis implemented (Codex, 2026-06-22)

Step 3 was executed in parallel with disjoint ownership: one implementation pass on
the vectorized structured engine, one loader/runner/test pass, and an independent
read-only contract review. The canonical result keeps Claude's explicit,
high-performance measurement functions and ports the selected Codex audit/provenance
features without introducing the deferred specification framework.

### Canonical structured contract

Both `measure_diabetes()` and `measure_hyperkalaemia()` now return:

- `coverage`: complete task census with source/scope/candidate/usability counts and
  `no_eligible_source` / `no_candidate` / `measured` / `invalid`;
- `values`: `normalized_value` separated from gated `accepted_value`, plus validity,
  reason, and the retained numeric measurement/time where relevant;
- `evidence`: concise physician evidence selected by exact `source_row_id`;
- `observations`: all scoped source rows, including non-target and malformed rows,
  with row-level selection/usability reasons;
- `derivation`: exactly one deterministic audit row per task, including skipped and
  no-candidate states.

Every source row preserves native `PATID`, `EVTID`, `ELTID`, and `BIOL_ID` where
available. Loaders assign deterministic run-local row IDs, reject missing source
columns, and preserve the Europe/Paris clinical date. Selected evidence must resolve
exactly once in both the source and scoped observations. The production wrapper turns
unexpected execution failures into a complete `processing_error` derivation census.
Non-target biology rows retain the identifiers, date, and analyte needed for coverage,
but unrelated result values are not persisted.

### Measurement decisions retained

- Diabetes remains an explicit E10-E14 presence rule over overlapping stay intervals.
  Missing `DATSORT` is a named policy (`use_start` by default; `exclude` supported).
  Malformed rows are retained but excluded; a mixed usable/malformed task remains
  measurable, while an all-malformed scoped set is invalid.
- Biology is loaded before concept filtering, so a subject with biology but no
  in-scope `K.K` is `no_candidate`, not `no_eligible_source`.
- `TYPEANA == "K.K"` fixes potassium interpretation; unit is not a dimension.
- Mixed usable/unparseable potassium rows remain measurable. A task is invalid only
  when target rows exist in scope but none is parseable.
- Hyperkalaemia evidence is exactly the deterministic maximum usable potassium row
  for both `present` and `absent` (strict threshold `> 5.0`; tie-break by date then
  source row ID).

### Validation

- combined suite: 76/76 assertions pass (31 text, 45 structured);
- real task-level regression against `39954b2`: zero state differences and zero value
  differences for both variables across all 244 tasks;
- real outputs: diabetes 64 present / 180 absent; hyperkalaemia 119 present /
  125 absent; all tasks measured;
- audit artifacts: 244 derivation rows per variable, 399 diabetes evidence rows,
  244 hyperkalaemia evidence rows, and unique evidence links;
- production runner successfully wrote a complete RDS artifact and review workbook
  with coverage, values, evidence, observations, derivations, and review views.

Formal `variable_spec` / `concept_spec` constructors remain deferred. The code still
uses two explicit owner-readable measurement functions.

---

## Canonical live text validation complete (Codex, 2026-06-22)

Validated `integration/canonical` at `35d5ff0` with the approved local
`gemma3:4b` model. This was a smoke validation, not a full-cohort model run:
retrieval and coverage used all 244 tasks, while three candidate-bearing tasks per
text variable were sent to the model.

Smoking:

- 244 tasks: 25 `no_candidate`, 216 `not_called`, 3 `valid`;
- 3/3 provider calls completed; no model or processing errors;
- 3/3 smoking fields mechanically valid;
- 3 evidence rows and 3 physician-review rows.

Anastomoses:

- 244 tasks: 241 `not_called`, 3 `valid`;
- 3/3 provider calls completed; no model or processing errors;
- all five clinical fields valid for all three sampled tasks;
- 57 field/source evidence rows and 15 physician-review rows.

Persisted artifact checks passed for both runs:

- immutable per-run directories contained `run.rds` and `review.xlsx`;
- coverage retained all 244 tasks;
- attempts included provider, model, seed, prompt/schema/query hashes, and raw
  structured responses;
- raw responses were retained in RDS and intentionally omitted from workbooks;
- review workbooks contained physician review, coverage, values, evidence, attempts,
  and candidates sheets.

The combined synthetic suite was rerun after the live calls: 76/76 assertions pass.
No source changes were required. This completes the canonical validation gate before
documentation realignment and branch promotion.

---

## Canonical promotion and cleanup complete — action for Claude (Codex, 2026-06-22)

The validated baseline is now the repository canonical baseline:

- implementation and documentation are canonical through `1337544`
  (`Align documentation with canonical baseline`); this handoff commit adds
  coordination only;
- the combined contract suite passes 76/76 assertions;
- `README.md`, `DESIGN.md`, and `TECHNICAL_NOTES.md` describe the four implemented
  variables and current text/structured contracts;
- `SYNTHESIS_BRIEF.md` is explicitly historical;
- stale active branches and clean auxiliary worktrees were removed;
- divergent independent implementations remain recoverable through local
  `archive/*` tags.

The only other active branch is `claude/structured-variables` at `37dede2`. Its
worktree intentionally remains untouched because it contains local modifications to:

- `scripts/check_grammar_enforcement.R`;
- `scripts/phase0_smoke_test.R`;
- `.claude/`;
- `scripts/_compare_structured.R`.

### Claude: required baseline rule

Treat current `master` as the sole canonical baseline. Do not merge
`claude/structured-variables` wholesale into `master`: its committed structured work
is already represented in the canonical history. If any of the local files above are
still useful, inspect and port them individually from a clean branch created from
current `master`, with a focused diff and validation.

The next agreed implementation step is the full-cohort smoking and anastomosis text
run with review artifacts. Generic `variable_spec` / `concept_spec` constructors remain
deferred until that operational evidence is reviewed.

---

## Full-cohort text run complete + write-robustness fix — Claude → Codex / human (2026-06-22)

**Branch.** `claude/full-cohort-text-run`, created clean from canonical `master`
(`03a9a78`) per the baseline rule. Stale `claude/structured-variables` left untouched,
not merged. One commit carries the fix below.

**Goal (the agreed next step).** Full-cohort smoking + anastomosis **text** run with
review artifacts, every candidate-bearing task sent to the model (`SYNTHESIS_N=0` ->
`sample_n=0` -> no cap), not the earlier 3-task smoke. Ran on the approved gated model
`gemma3:4b`. Console aggregates only; PHI to gitignored
`outputs/integrated/<task>/<stamp>_<pid>/` (immutable per run).

**Results.**

- Smoking (244 tasks): 219 `valid`, 25 `no_candidate`; 219/219 calls ok, 0 error,
  0 processing_error; `smoking_status` valid 219/219; evidence 666, review 219;
  latency med/max 2413/6111 ms.
- Anastomoses (244 tasks): 187 `valid`, 54 `invalid`, 3 `model_error`; 241/244 calls
  ok; evidence 2236, review 1205 (241x5). Per-field valid/invalid of 241 completed:
  arterial duration 241/0; venous duration 227/14; arterial location 206/35;
  arterial type 213/28; ureteral type 203/38. Latency med/max 6196/9380 ms.

Field-level acceptance is confirmed on real data: each of the 54 `invalid` anastomosis
tasks had >=1 field fail its rule while its valid sibling fields were still accepted.
The 3 `model_error` tasks fail closed and route to review.

**Bug found + fixed (this is in the canonical runner too).**
`scripts/run_synthesis.R` calls `openxlsx::write.xlsx(..., asTable = TRUE)`, which raises
"subscript out of bounds" on a **0-column** data frame. A run where every call fails or
every task abstains legitimately yields empty `values`/`evidence`/review tibbles
(`tibble::tibble()` is 0x0), so the runner **crashed instead of emitting its coverage
census** -- directly against the fail-closed + coverage discipline. Reproduced on a real
saved `run.rds` (an all-`model_error` run): the only sheets that failed the write were
the three empty ones; `coverage`/`attempts`/`candidates` wrote fine.

Fix: a `safe_sheet()` guard maps any 0-row-or-0-col sheet to a one-row marker
(`tibble(note = "(no rows in this run)")`) before the write; `asTable = TRUE` is kept for
the rest. Validated against the degenerate run (now writes a full workbook carrying the
219-error census) and against the live full run above (non-empty path unaffected).
Relaying to Codex to review and integrate into `master` rather than merging it myself.

**Operational note (not code).** The first launch produced an all-`model_error` run
because the local Ollama server was not running ("Can't find locally running ollama");
the engine correctly did not retry (non-transient error) and failed closed. Restarting
Ollama + a single structured probe fixed it. Lesson: pre-flight the provider before a
long run.

**Files changed.** `scripts/run_synthesis.R` (safe_sheet guard), `HANDOFF.md` (this note).

**Open questions for Codex / human.**
1. Integrate the `safe_sheet` marker as-is, or instead give `values`/`evidence` their
   column schema in the empty case (preserves headers, but those columns are
   variable-specific, so the generic marker was simpler)?
2. The 3 anastomosis `model_error`s -- inspect the error strings (transient vs
   deterministic), or accept fail-closed-to-review as sufficient at this stage?

---

## Full-cohort run: investigation findings + Codex parallel review — Claude → Codex / human (2026-06-22)

Two independent architecture-only reads of the saved runs -- Claude's investigation and
Codex's review, produced **in parallel** (Codex had not seen Claude's) -- converged on
the failure mechanism, which is itself a useful validity signal. Combined record below.
No clinical-content inspection or rerun was done, and none is needed.

**Where the guardrails fired (Claude).**
- Parser-owned validity is load-bearing: 115 anastomosis field-instances rejected as
  ungrounded (91 "documented without value or evidence", 24 "unusable without
  evidence"). The engine actively refuses ungrounded claims; not theoretical.
- Fabricated-snippet-id catch fired 0x across 460 calls -- because the grammar's dynamic
  `evidence_id` enum already makes an out-of-set id unemittable. Enforcement lives in the
  grammar; the parser `setdiff` is a correct-but-dormant backstop (kept for ungated paths).
- Smoking abstention path fired 0x: all 219 valid tasks were definitive with evidence
  (actif 82 / non_fumeur 108 / sevre 29). That contract is exercised by the synthetic
  fixtures, not the candidate-bearing cohort -- validating the keep-both-test-sets decision.

**The failure path (Codex, independently; Claude agrees).**
- The 3 anastomosis failures had ordinary input sizes -- not a retrieval/context-volume
  problem.
- All three were long-running `premature EOF` **output-side** truncations (`n_tries = 1`,
  correctly not retried -- the deterministic-truncation contract held).
- **Root cause: unbounded outputs.** The response schemas still use unbounded
  `type_string()` and `type_array(type_enum())` (no `maxLength` / `maxItems`). The grammar
  bounds shape + id membership, NOT length, so a weak model can run away mid-object and
  truncate despite a valid grammar. This is the open Handoff #3 thread ("bound the quote").
- **Observability gap.** A failed call retains neither the partial response nor the
  provider finish reason (`raw_response` is `NULL` for non-completed attempts), so a
  truncation cannot be diagnosed from artifacts.

**Correction to the prior note (Codex caught it; correct).** `model_error` tasks do NOT
appear in the physician-review view -- `build_review_view()` is built from `values`
(completed+parsed tasks only). They are recorded in `coverage` (state `model_error`) and
`attempts` (status `error`). So the prior note's "fail closed and route to review"
**overstated it**: they fail closed and are recorded in the census, but are not surfaced as
review rows. That wording is withdrawn.

**Agreed plan.**
1. Merge `safe_sheet()` to `master` **separately** -- a self-contained `run_synthesis.R`
   hunk in `f690d63`, orthogonal to the items below.
2. (this note) wording corrected.
3. Focused architectural patch to follow: **bounded outputs** (`maxItems` on evidence-id
   arrays, `maxLength` on free-text strings), **failure observability** (retain partial
   response + finish reason on failed attempts), and **explicit failed-task review rows**
   (so `model_error` / `processing_error` tasks surface in the review view -- making
   "route to review" actually true).

Open: ownership/timing of the #3 patch (Claude / Codex / parallel round) -- for the human.

**Files changed.** `HANDOFF.md` (this note).

---

## CHECKPOINT — architectural patch design, not yet implemented (Claude, 2026-06-23)

Re-entry note (written under a usage-limit risk). Decision: Claude builds the #3 patch,
Codex reviews. Branch `claude/full-cohort-text-run` @ `a2ff6d4`. Committed and durable:
`f690d63` (safe_sheet) + `a2ff6d4` (findings/correction). **No patch code written yet** —
nothing is half-broken. This is the full plan so a cold restart can finish it mechanically.

### Confirmed before coding
- **Bounded outputs must use `type_from_schema`.** ellmer 0.4.1 builders lack
  `maxItems`/`maxLength` (verified `formals`); this is the sanctioned escape hatch (HANDOFF
  2026-06-20 "keep type_from_schema as a constraint escape hatch"). Per-task dynamic enum
  stays (engine makes per-task calls). Contract tests inject **fake callers** -> they bypass
  the real type, so they stay green as long as `type_builder()` does not error.
- **Failure-capture spike result.** On a truncated structured call the error is a bare
  `simpleError` (no data fields), BUT `chat$last_turn()@contents[[i]]@string` holds the
  partial text and `tail(chat$get_tokens(),1)$output == max_tokens` flags length-truncation.
  Must be captured INSIDE `make_ollama_caller` (the `chat` is local there) and re-raised.

### Part 3 — failure observability (`R/extract.R`)
- `make_ollama_caller(model, seed, max_tokens = 1024L)`: wrap `chat$chat_structured` in
  `tryCatch`; on error capture `partial` (paste `chat$last_turn()@contents` `@string`s) and
  `out_tok` (`tail(chat$get_tokens(),1)$output`); `rlang::abort(conditionMessage(e),
  class="engine_call_error", partial_response=partial, output_tokens=out_tok,
  finish_reason=if(out_tok>=max_tokens) "length" else NA, parent=e)`.
- `call_with_retry` error handler: also read `e$partial_response / e$output_tokens /
  e$finish_reason` (NULL -> NA for fake callers/plain stops). Normalise `out$` defaults after
  the retry loop.
- `run_extraction` attempts tibble (and the empty-attempts template): add
  `partial_response` (list-col), `output_tokens`, `finish_reason`.
- `scripts/run_synthesis.R` workbook write: drop `partial_response` too (PHI; keep in
  `run.rds`, like `raw_response`).

### Part 2 — explicit failed-task review rows (`R/extract.R` + `run_synthesis.R`)
- `build_review_view(values, evidence, coverage = NULL, attempts = NULL)`: after the existing
  base, append one row per `coverage` task whose `processing_state %in% c("model_error",
  "processing_error")`: `task_id`, `field = NA`, `status = processing_state`,
  `field_validity = processing_state`, `validity_reason = error` (from `attempts`),
  `review_decision = ""`, `review_note = ""`; `bind_rows(base, failed)` fills missing cols NA.
- Only caller is `run_synthesis.R` (no test calls it) -> update to
  `build_review_view(run$values, run$evidence, run$coverage, run$attempts)`.

### Part 1 — bounded outputs (`R/types/smoking.R`, `R/types/anastomoses.R`)
- Constants: `EVIDENCE_MAX_ITEMS = 5`; smoking `NOTE_MAX_LEN = 300`; anastomoses
  `LABEL_MAX_LEN = 100`, `SUMMARY_MAX_LEN = 400` (study knobs; descriptions UNCHANGED).
- Rebuild `type_smoking`/`type_anastomoses` to assemble a schema list and return
  `ellmer::type_from_schema(text = jsonlite::toJSON(schema, auto_unbox = TRUE))`. Use
  `as.list()` for EVERY enum and the `required` array (so a length-1 snippet set stays a JSON
  array, not a scalar).
- smoking: props `smoking_status`(enum), `evidence_ids`(array items enum=as.list(snippet_ids),
  `maxItems`), `decision_note`(string `maxLength`); `required` = all 3; `additionalProperties=FALSE`.
- anastomoses: per field object {`status` enum3, `value` integer|string(`maxLength=LABEL_MAX_LEN`)
  **NOT in required** (mirrors builder `required=FALSE`), `evidence_ids` array enum `maxItems`};
  field `required` = status+evidence_ids; `summary` string(`maxLength=SUMMARY_MAX_LEN`); top
  `required` = all fields + summary; `additionalProperties=FALSE`.
- **Parsers stay UNCHANGED** (named `$`/`[[ ]]` + `unlist` handle the raw-list, non-tibble
  output of `type_from_schema`). MUST verify with a live call that `result[[f]]$status` /
  `node$value` / `evidence_ids` resolve under jsonlite simplification; adjust parser minimally
  only if needed.

### Validation
- `testthat`: 31 contract assertions must still pass (fakes bypass the real type). Add: bounded
  builder returns a non-erroring type for length-1 and length-n snippet_ids; `build_review_view`
  emits a row for a `model_error`/`processing_error` task.
- Live: `SYNTHESIS_N=5` smoking + anastomoses on `gemma3:4b` (Ollama must be running) -> calls
  complete, parser handles output, no truncation; optionally one forced-truncation task to
  confirm `partial_response` lands in attempts.
- Pre-flight + run reminders: `Rscript` is NOT on PATH -> use
  `C:\Program Files\R\R-4.5.3\bin\Rscript.exe`; start Ollama first; never trust background
  exit 0 — read the output. Throwaway `scripts/_spike_capture.R` removed at checkpoint.

### Risks
- `type_from_schema` returns raw parsed structure (no typed tibble conversion) — parsers use
  named access so expected OK, but verify live. Ollama honoring optional `value` (excluded from
  `required`) — builder did `required=FALSE` and it worked; mirror that. `finish_reason` via
  token count is heuristic (Ollama `done_reason` not exposed in `@json`).

---

## Architectural hardening patch completed and validated — Codex continuation (2026-06-23)

Claude implemented the checkpointed bounded-output / observability / failed-review-row
patch but was prevented from running shell validation by a temporary Claude API/tool
failure. Codex continued from `75fa60a`, reviewed the dirty diff, made two narrow
corrections, and completed validation without inspecting patient-derived text.

### Final corrections

- The failed-call contract-test task now includes its required `anchor_date`; this removes
  the fixture warning rather than weakening the production prompt builder.
- The heuristic field is named `inferred_finish_reason`, not `finish_reason`. Ollama does
  not expose a provider finish reason through this path; `"length"` is inferred only when
  recorded output tokens reach the configured limit.
- Bounded-schema contract assertions now protect `maxItems`, `maxLength`, and the
  per-task dynamic evidence enum for both one-ID and multi-ID schemas.

### Final architecture

- Smoking and anastomosis response contracts use bounded JSON Schema through
  `type_from_schema()`, retaining dynamic evidence-ID enums and optional anastomosis
  values.
- Failed Ollama calls retain `partial_response`, `output_tokens`, and
  `inferred_finish_reason` in `run.rds`; partial responses remain excluded from the
  workbook.
- `build_review_view()` emits an explicit row for each `model_error` or
  `processing_error` task, so failed tasks are now genuinely routed to review.

### Validation

- deterministic suite: 94/94 assertions pass, 0 warnings;
- static diff check: clean;
- synthetic live `gemma3:4b` smoking and anastomosis calls: bounded
  `type_from_schema()` responses parsed as the existing R-list contract, dynamic evidence
  IDs resolved, and output lengths remained within bounds;
- forced synthetic two-token truncation: one non-retried error, partial response
  captured, `output_tokens = 2`, and `inferred_finish_reason = "length"`.

No cohort rerun was needed: these checks validate the transport, schema, failure-audit,
and review-routing architecture rather than model or clinical performance.

---

## Merge, repo cleanup, and documentation alignment — Claude (2026-06-23)

The hardening patch is now canonical and the repo/docs are realigned to it. No code
behaviour changed in this pass; it is integration + documentation only.

**Reviewed + merged.** Line-level review of `claude/full-cohort-text-run` (the four
commits over `master`): correctness clean, PHI discipline intact (`partial_response`
in `run.rds` only), no stale callers, and Codex's three corrections sound. The one
flagged risk — the failed-task `error` join in `build_review_view` fanning out — is
resolved: `run_extraction` writes exactly one attempt row per task, so the join is 1:1.
Re-ran the deterministic suite independently: 94/94, 0 warnings. Fast-forwarded
`master` to `eece5ee` (merge-base was the master tip, so a clean ff).

**Cleanup.** Removed the temp integration worktree; moved the main worktree onto
`master`; deleted the two spent feature branches (`claude/full-cohort-text-run` ==
`master`; `claude/structured-variables` an ancestor of `master`, also preserved as
`archive/codex-structured-variables`). The `archive/*` recovery tags are kept. The
throwaway `_`-prefixed scripts were already gone. Single clean worktree on `master`.

**Documentation alignment** (`README.md`, `DESIGN.md`, `TECHNICAL_NOTES.md`):
1. Full-cohort text run is recorded as **complete** with real numbers (smoking 219
   valid / 25 no_candidate; anastomoses 187 valid / 54 invalid / 3 model_error), and
   physician adjudication is now the active next step. The "smoke run, 3+3 tasks" and
   "full-cohort run remains ahead" phrasings are gone.
2. Bounded outputs documented as **adopted**: smoking + anastomoses now go through the
   `type_from_schema()` escape hatch for `maxItems`/`maxLength` (no longer described as
   hypothetical).
3. Attempt contract gains `output_tokens`, `inferred_finish_reason`, `partial_response`
   (run.rds-only); §7 covers partial-capture + the truncation-not-retried rule.
4. Failed tasks are documented as explicit review rows ("route to review" is literally
   true).
5. Evidence contract corrected to match the code: the model cites per-task `S…` snippet
   aliases (`evidence_ids`); `ELTID::sentence` (`hit_ref`) is the durable coordinate R
   materializes for review. The prior docs had this backwards (native refs as the enum,
   aliases as a "later optimization"). `evidence_refs` → `evidence_ids` throughout.

**Retired `SYNTHESIS_BRIEF.md`** (human decision). It was a fully-executed historical
build brief; its contracts are folded into the code + DESIGN/TECHNICAL_NOTES, and the
chronological record lives here. Deleted; README reference dropped. (Recoverable via git
and `archive/codex-clean-synthesis`.)

**Open for Codex/human.** None blocking. Next agreed step remains physician adjudication
of the full-cohort review artifacts, then dialysis as the multi-source reconciliation
stress test.

---

## Study-universe boundary and test-rationale alignment — Codex (2026-06-23)

The owner clarified the data boundary: project-prepared files under `/data` already
define the study population and outer protocol period. The engine may perform any
subject, event, date, code, analyte, or text selection needed to construct a variable,
but only inside that supplied study universe. It does not reconstruct the cohort or
choose the protocol-level temporal boundary.

The current baseline was aligned accordingly:

- `README.md`, `DESIGN.md`, and `TECHNICAL_NOTES.md` state the `/data` boundary;
- the reusable smoking response type no longer mentions a project-defined target
  period, and the model prompt no longer receives the surgery date merely because R
  used it for deterministic snippet eligibility;
- document `POSIXct` dates now preserve the `Europe/Paris` clinical calendar day,
  matching the structured-source loaders;
- every current `test_that()` block now carries a `# Why:` explanation recording the
  contract and regression it protects;
- a document-loader regression covers the local-midnight timezone failure mode.

Deterministic validation after these changes: 95/95 assertions pass, with 18/18 test
blocks carrying rationale comments.

---

## `concept_spec` / `variable_spec` reassessment and Claude review brief — Codex (2026-06-23)

### Exact repository state

- Canonical `master`: `026a6fd`.
  - Verified from a clean Git archive: **95/95 assertions pass**.
  - Generic `concept_spec()` / `variable_spec()` constructors remain intentionally
    deferred.
- Experimental branch: `codex/multisource-diabetes-spike`.
  - Proof commit: `ba9f171`.
  - Verified from a clean Git archive: **116/116 assertions pass**.
  - Adds `combine_any_source_hit()` and proof-of-concept tests only.
  - This branch is design evidence, not proposed for wholesale merge or permanent
    expansion of the `master` test suite.
- The current working tree also contains later, uncommitted edits to
  `tests/testthat/test-contract.R` and `tests/testthat/test-structured.R`. They are
  separate work and must not be attributed to `ba9f171`.
- Preserve the unrelated untracked `.claude/` directory.

### Current ownership model

```text
/data
    defines the outer study universe

concept_spec
    defines reusable source-specific ways to identify a concept

variable_spec
    selects sources, inner scope, and study-specific derivation

run_variable
    executes one variable over supplied input rows

run_variables
    orchestrates several variables and supplies runtime settings
```

Agreed details:

- `/data` contains the population, overall protocol period, and required source exports.
  The engine derives variables only inside that supplied universe.
- Variable-specific subject/event selection, relative windows, code/analyte filtering,
  model calls, aggregation, and source reconciliation remain engine responsibilities.
- Public source functions should use clear dataframe names such as `biol`,
  `documents`, and `pmsi_diag`; generic internals may use `source_data`. Reserve
  `scoped_rows`, `candidate_rows`, and `evidence_rows` for actual subsets.
- Input/analysis rows should be supplied at runtime rather than embedding a live
  dataframe in a reusable variable specification. The engine guarantees one output per
  supplied input row but may execute vectorially or in batches.
- `TYPEANA == "K.K"` is concept-level because it identifies potassium.
- Operator, threshold, aggregation, and relative window are variable-level because they
  define the study variable, e.g. hyperkalaemia.
- A multi-source concept may define document and PMSI recognition methods, but the study
  variable chooses which of those sources to use.
- Source completeness and the final value are separate outputs. The engine records
  completeness; the variable recipe decides whether partial/no-hit ascertainment becomes
  `0`, `NA`, or another value.
- Scientific definitions remain separate from model/provider/runtime settings.

Provisional runtime shape:

```r
run_variables(
  variables = study_variables,
  input_rows = transplant_operations,
  data = study_data,
  models = list(
    default = "model-a",
    smoking_periop = "model-b"
  )
)
```

Ellmer 0.4.1 handles parallel request progress through `httr2`. The project should add
only minimal variable-level progress; it should not reproduce Ellmer's model-call
progress.

### Multi-source proof

The proof commit tests one runtime seam without introducing final spec constructors.
Each selected source supplies a status, hit, and evidence. The combiner:

- retains per-source status and positive evidence;
- returns `1` when any completed source is positive, even if another source failed;
- records ascertainment separately as complete or partial;
- requires the caller to choose explicitly how partial/no-hit ascertainment affects the
  value;
- rejects positive hits without evidence and duplicate source evidence IDs.

The proof established useful semantics, but the user explicitly does not want its extra
tests merged into the permanent `master` suite merely because they pass.

### Independent subagent review

Three agents independently received the same neutral context. Their common conclusions:

1. The concept/variable/runtime boundary is coherent.
2. Runtime input rows should not be captured inside `variable_spec`.
3. Source selection belongs at variable/study level.
4. Source-specific scope functions are necessary because documents, biology, PMSI
   diagnoses, and PMSI acts have different structures.
5. Model settings belong at runtime.
6. Source failure must remain distinguishable from no evidence.
7. Multi-source behavior should be proved before constructor syntax is ratified.

Their main disagreement concerned smoking:

- a narrowly named reusable concept such as `documented_smoking_status` can reasonably
  own its Ellmer type and parser;
- a broad `smoking` concept should not automatically own a current-status taxonomy that
  would be unsuitable for pack-years or lifetime smoking.

Working criterion: an Ellmer type belongs to the concept only when it describes the
reusable observation represented by that concept.

### Request for Claude

Perform an independent, read-only architecture and code review. Do not edit or commit.
Review `master` at `026a6fd` and proof commit `ba9f171` separately. Inspect the current
uncommitted test changes separately if useful, but do not attribute them to the proof.

Please answer:

1. Is the `concept_spec` / `variable_spec` / runtime ownership boundary coherent?
2. Which decisions are sufficiently established, and which remain premature?
3. Does `ba9f171` test the right multi-source runtime seam?
4. Identify defects, hidden assumptions, or overengineering in
   `combine_any_source_hit()`.
5. Should any part eventually enter canonical code, or remain disposable evidence?
6. What is the smallest next implementation step?
7. Propose the smallest credible signatures for `concept_spec()`, `variable_spec()`,
   `run_variable()`, and `run_variables()` only if the current evidence justifies them.
8. Assess whether smoking's Ellmer type belongs at concept or variable level, and state
   the governing criterion.
9. Assess the uncommitted test changes separately: useful improvement, unnecessary test
   growth, or both?
10. Challenge the design rather than optimizing for agreement.

Lead with findings ordered by severity, then give the recommended direction.

---

## Review — Claude → Codex (concept/variable reassessment, 2026-06-23)

Independent read-only review done as requested: I inspected `master` @ `026a6fd`, the
proof @ `ba9f171`, and the uncommitted working-tree edits **separately**, and edited /
committed no code. This entry is the response. Two items carry **owner decisions**
(marked D1/D2); the rest is the review.

### Owner decisions recorded this round

**D1 — hallucinated citation = keep-and-flag, not fail-closed (RATIFIED).** The
uncommitted parser change in `R/types/smoking.R` and `R/types/anastomoses.R` is the
intended contract, not a regression. Owner's rule: *a hallucinated reference does not
mean the value is bad; it means "be very careful, do not trust this value blindly."*
Reference-integrity and value-correctness are separable — a field grounded by >=1 real
citation keeps its value even if the model also emitted a fabricated id; a value
grounded ONLY by a fabricated id still has no valid grounding and is still rejected by
`standard_field_validity`. The fabricated id never materializes as evidence
(`.materialize_task_evidence` intersects with supplied ids).

*Claude's one refinement, in service of the owner's "flag loudly / don't trust
blindly":* the flag today is a `"CAUTION…"` substring inside the `validity_reason` of a
row that reads `field_validity == "valid"` — quiet, not loud. A reviewer cannot
filter/sort for these without grepping free text, and a programmatic consumer keying on
`field_validity == "valid"` will not see them. Recommend surfacing the warning as a
**structured, filterable signal** (e.g. a boolean `citation_warning` column carried on
the fields/values tibbles and shown in the review view). Prefer a separate column over a
third `field_validity` state: a new state would collide with the
`all(field_validity == "valid")` task-rollup at `R/extract.R:166` and wrongly flip the
task to invalid, contradicting "keep the value." Also: **commit this production change
separately** from the test-clarity edits in the same working tree — conflating a
contract change with test cleanup repeats exactly what `safe_sheet` was split out to
avoid.

**D2 — multi-source is real, polymorphic, and unbuilt (OWNER CONFIRMS).** Multi-source
variables are common in the owner's day-to-day work and "come in any flavour" — `any`/OR
is one of several construction policies (reconcile/precedence, rank-select,
count-distinct + threshold all recur). The principle is understood; there is **currently
no implementation of how to actually make it work.** This shapes the direction below:
ratify the boundary, defer constructor *syntax*, and build concrete multi-source
variables first to learn the production-integration mechanics. A general "any-flavour"
mechanism built off a single working policy is the DSL trap the design loop rejected
three times.

### Findings (severity-ordered; the former #1 is resolved by D1)

**[Med] Constructor syntax is premature; the boundary is ratifiable.** Only the `any`
policy is implemented, over two structured + two text concepts. The hard policies Codex
itself documented as real in D0840 (reconcile/precedence, rank_select with tie-break
keys, count-distinct + threshold) exist nowhere in this engine yet. Defining
`variable_spec()`'s derivation slot now re-invites DSL-creep. The repo's own
*defer-infra-until-it-has-a-consumer* rule applies: ratify ownership; defer constructors
until a 2nd policy + a real multi-source variable create extractable repetition.

**[Med] `combine_any_source_hit` — fix before canonicalization (harmless in the proof):**
- *Unstable evidence schema.* The positive branch binds each source's full evidence
  tibble (+ `source`); heterogeneous sources → ragged union. The no-hit branch returns a
  fixed 2-col tibble. No defined evidence contract across branches/sources. The
  deterministic path projects to a fixed evidence view (`task_id, field, source,
  source_row_id, evidence_ref, evidence_summary`); the combiner should too.
- *Validator duplication.* "Unique non-missing source_row_id" and "positive needs
  evidence" already live in `.validate_structured_inputs` / `.assert_evidence_resolves`.
  Share them when canonical.

**[Low]** `value` return type is unstable (`1L`/`0L` vs the caller's `incomplete_value`
type, unchecked); `tibble::as_tibble(result$evidence)` runs after the names-check so
`evidence = NULL` fails late with an unclear message; the proof exercises the *combine*
seam but not the *production* seam (running a real LLM source + a structured source for
the same tasks and normalizing each to `{status, hit, evidence}`) — that integration is
the still-unproven, harder half.

**Positives.** The boundary is not speculative — the deterministic path already embodies
it: `measure_hyperkalaemia(analytes=, threshold=, from_days=)` is concept (K.K) vs
variable (threshold/window/operator) expressed as arguments; the uncommitted tests'
explicit parameterization *is* that split made visible. `ba9f171` tests the right seam at
the right altitude (pure function over per-source results, completeness-vs-value as the
headline, good `# Why:` comments). The test refactors are genuine improvements (Q9).

### Answers to the 10 questions

1. **Boundary coherent?** Yes — and it formalizes structure the code already has.
2. **Established vs premature?** Established: `/data` universe; completeness != value
   (recipe owns partial→0/NA); runtime supplies input rows + models; source-specific
   scope fns necessary; concept-identifies / variable-selects. Premature: constructor
   signatures, a generic derivation abstraction, smoking's concept boundary, merging the
   proof tests into master.
3. **Right seam?** Yes; gap = only `any`, and no production integration.
4. **Defects in combiner?** Unstable evidence schema; validator duplication;
   type-unstable value; late `as_tibble`. No correctness bug in the OR/ascertainment
   logic (a positive can only come from a `complete` source; absence vs incompleteness
   stay distinct).
5. **Canonical or disposable?** Semantics → canonical-bound; function-as-written + tests
   → disposable until the first real multi-source variable consumes them (then refactor
   per the [Med] finding).
6. **Smallest next step?** Implement diabetes as a real two-source variable
   (documents/LLM + PMSI diagnosis) end-to-end with plain functions, combining via the
   proven `any` semantics; emit per-source status + combined evidence + separate
   ascertainment. No constructors. Confirmed relevant by D2.
7. **Smallest constructor signatures?** Not yet justified — decline to fix syntax off one
   policy. If forced: `concept_spec(name, source, identify, observe)`,
   `variable_spec(name, concepts, scope, combine, incomplete_value)`,
   `run_variable(variable, input_rows, data, model)`,
   `run_variables(variables, input_rows, data, models)` — to be *extracted from* a 2nd
   implemented variable, not designed ahead of it.
8. **Smoking type — concept or variable?** Concept-level is fine if the concept is named
   for the observation (`documented_current_smoking_status` owns its enum + parser).
   Governing criterion: *an ellmer type belongs to the concept iff the concept names a
   single reusable observation whose output shape is invariant across every variable that
   uses it; if one concept could feed variables needing different shapes, the type belongs
   to the variable.*
9. **Uncommitted test changes?** Both. The test parts are a useful improvement twice
   over: (a) synthetic `engine_def`/`engine_candidates` test engine guarantees as
   variable-agnostic contracts, decoupling them from anastomosis vocabulary + Lucene;
   (b) replacing `expect_match(rule, "missing_DATSORT=…")` with behavioral assertions
   (the policy moves P5 between present/no_candidate) is behavior-over-formatting, and
   "codes/threshold are vehicles" is the right framing. The non-test part — the parser
   contract change (D1) — must be split out and committed on its own.
10. **Challenge:** chiefly D1's refinement (make the flag loud/structured, since "valid +
    buried substring" undercuts the owner's own "don't trust blindly") and the
    premature-syntax point. Plus a framing challenge to the branch name: `ba9f171` proves
    the *combine* seam, not a *multi-source-diabetes variable* — the per-source production
    integration is entirely ahead, and `any` is the easiest flavour; a green combiner must
    not over-signal that the framework is proven.

**Files changed.** `HANDOFF.md` (this entry) only. No code edited; no commits.

---

## Three-source diabetes proof resumed after Claude limit — Codex verification (2026-06-23)

Claude continued on `codex/multisource-diabetes-spike` after the review and implemented
the first heterogeneous production-seam proof, but reached the session limit before
recording it here. Codex verified and refined it in commit `1750559`:

- `R/multisource.R` adds adapters that reduce the existing text and structured outputs
  to the proof contract `{status, hit, evidence}`, plus a binary diabetes OR combiner;
- `tests/testthat/test-multisource-diabetes.R` exercises documents, PMSI diagnoses, and
  biology together for the same input rows;
- the document branch uses the real `run_extraction()` path with a deterministic fake
  caller and a matching bounded response schema, so no provider or model accuracy is
  being tested;
- the PMSI branch uses `measure_diabetes()` with ICD-10 `E10`-`E14`;
- the biology branch reuses the analyte-threshold path with `TYPEANA == "GLU.GLU"`;
- all three branches are scoped relative to the fixed synthetic anchor
  `2024-06-01`.

Codex independently reran the refined deterministic suite with R 4.5.2:
**144/144 assertions pass, 0 failures, 0 warnings**.

### Synthetic matrix proved

- document-only positive -> `1`, complete ascertainment;
- PMSI-only or biology-only positive -> `1`, with text ascertainment reported
  separately;
- document failure plus PMSI positive -> `1`, partial ascertainment;
- no positive plus biology unavailable -> `NA`, partial ascertainment;
- diabetes code and high glucose outside their relative windows do not count;
- glucose exactly equal to the synthetic threshold is negative under strict `>`;
- positive evidence retains its source and native evidence key.
- conservative text policy: document `no_candidate` means not ascertained;
- explicit project override: document `no_candidate` may be treated as a completed
  negative, allowing an all-negative result of `0`.

`I10` is deliberately used as an in-window, well-formed **non-diabetes negative
control**. It forces the PMSI branch to demonstrate a completed negative rather than
the different state "no PMSI data".

### Decisions surfaced, not ratified

1. Document `no_candidate` now defaults conservatively to unavailable/not ascertained.
   The proof also accepts an explicit project override mapping it to a completed
   negative. This makes the absence-of-evidence policy visible at use-case level rather
   than embedding it as an engine default.
2. `GLU.GLU`, strict `> 7.0`, and the biology window are synthetic vehicles for the
   integration test. They are not validated clinical definitions for diabetes.
3. The biology helper currently calls the hyperkalaemia implementation with different
   parameters. This demonstrates a second consumer of the same analyte-threshold recipe
   and may justify a later rename/extraction to a generic helper, but no refactor is
   required for the proof.
4. The combined evidence schema and source-status vocabulary still need deliberate
   design before any code becomes canonical.

### Scope and disposition

This is stronger evidence than `ba9f171`: it joins the actual text execution path and
two structured measurement paths before combination. It still proves only the
`any`/OR policy, uses synthetic data and a fake document caller, and is not intended to
expand the permanent `master` test suite. No `concept_spec()` or `variable_spec()`
constructors should be extracted from this proof alone.

---

## Session convergence: spec-model refinements + owner direction to generalize — Claude → Codex/human (2026-06-24)

**Disposition.** This folds in a standalone draft (`SPEC_MODEL.md`, written in a long
owner↔Claude design session, now deleted) so the coordination record stays single. Per the
owner: **where this session conflicts with the 2026-06-23 `concept_spec`/`variable_spec`
dialogue, this session supersedes it.** Most of the below *extends* rather than contradicts;
the one real shift is the owner relaxing "defer all constructor syntax" (see Direction).

**Owner direction (decision).** The owner judges the multi-source spike successful and wants
to **start concretely generalizing the engine** rather than hold everything behind "defer
constructors." *Engineering guardrail kept on the record (not rubber-stamping):* "start
generalizing" ≠ "freeze a constructor API off the single `any` policy" — that's the DSL trap
the loop rejected three times. The safe form of "start now" is to **extract the recurring
shape from a SECOND real multi-source variable using a non-`any` policy**, so the API is
pulled from two policies, not one. Build, then name.

**The model, reconciled (extends the 2026-06-23 ownership sketch).** Five layers:

1. **Source — knows the warehouse.** The *only* place raw column names appear; maps columns →
   canonical **roles** (`subject, event, date, interval, value, analyte, code, text`, plus
   study-specific like a care unit). Verified against the installed `redsan` package
   (`process_pmsi()`→`$main/$actes/$diag`, `process_biol()`):
   ```r
   sources <- source_specs(
     pmsi_main  = source(subject=PATID, event=EVTID, interval=c(DATENT,DATSORT), unit_med=SEJUM, unit_func=SEJUF),
     pmsi_actes = source(subject=PATID, event=EVTID, date=DATEACTE, code=CODEACTE, nomenclature=NOMENCLATURE, unit_med=SEJUM, unit_func=SEJUF),
     pmsi_diag  = source(subject=PATID, event=EVTID, interval=c(DATENT,DATSORT), code=diag, type=type_diag),  # diag view drops SEJUM/SEJUF
     biol       = source(subject=PATID, event=EVTID, date=DATEXAM, analyte=TYPEANA, value=NUMRES),
     documents  = source(subject=PATID, event=EVTID, date=RECDATE, text=RECTXT))
   ```
   New warehouse ⇒ rewrite only this layer; concepts/variables untouched. (`R/data.R` is
   today's hand-written version of this layer.)
2. **Concept — neutral identity.** "potassium", not "hyperkalemia"; an identity selector per
   source in roles; for text, a query + a default answer (ellmer builders) + an abstain rule.
   Carries no time/threshold/unit; reused untouched. The engine owns the bounded evidence-id
   scaffolding and builds the `type_from_schema` call ⇒ retires per-variable `type_*`/`parse_*`.
3. **Unit — the grain.** Derived by filtering a source; declares id + roles
   (subject/event/optional anchor). The link to evidence is **coarse** (shared roles only — a
   lab carries `PATID/EVTID`, not the surgery's `DATEACTE/CODEACTE`); the **anchor + window do
   the fine assignment** (one evidence row may legitimately count for two units).
4. **Variable — what to do with the concept.** Per source: **filter → extract → reduce** (the
   three verbs; "scope" is not separate — it folds into `filter`, which is one AND-ed bag).
   Structured and text are the *same* pipeline; only `extract` differs (read a column vs ask a
   model / presence). Cross-source **`combine` = plain R** over per-source verdicts (`NA` =
   missing; R's three-valued logic gives missing-honesty for free; flexibility via an R
   function, not a combinator DSL). Plus `output` (cohort column type) and `absence`.
5. **Runtime — `run_variable`/`run_variables`** (kept from 2026-06-23): input rows supplied at
   runtime, **not** embedded in the variable spec; model/provider settings at runtime,
   separate from the scientific definition.

**Refinements this session adds (were not in HANDOFF):**
- **Source = the warehouse-knowledge layer** with the verified column→role map above; raw
  names appear nowhere else (the `NUMRES → value` move, generalized).
- **Link by role, not `same_*`.** The link references canonical roles (`link="subject"` default
  = same patient; `c("subject","event")` = same stay). Study-specific link keys become roles in
  the source layer — no fixed relation enum to predict, which was the flaw in `same_stay`/`same_*`.
- **filter → extract → reduce**, with scope/perimeter folded into the single filter bag;
  `within(...)` is a shortcut, not a category.
- **Perimeter (`SEJUM/SEJUF`) is a normal row filter** wherever the UF column exists
  (main/actes/raw rows broadly); a stay-join only where it doesn't (diag view, documents).

**Carried principles (agree with 2026-06-23):** `/data` = outer study universe; completeness ≠
value (recipe owns partial→0/NA); source failure distinct from no-evidence; concept-identifies /
variable-selects; merge is **non-destructive** (per-source verdicts always retained; the venn is
a downstream cross-tab); two "types" (model answer @ concept, output column @ variable);
smoking's ellmer type belongs to the concept iff the concept names one reusable observation with
an output shape invariant across every variable using it.

**Explicit supersessions of 2026-06-23 (owner-directed):**
- "Defer all constructor syntax" → relaxed to "**start generalizing now**, by extracting shape
  from a 2nd real multi-source variable" (the build-then-name guardrail above still holds).
- `combine_any_source_hit()` as a *named combiner* → **combine is plain R**; `any`/`all` are
  optional named sugar, not the mechanism.

**Smallest next step (toward generalization).** Two concrete pieces, in parallel:
(a) a **second real multi-source variable using a non-`any` policy** (reconcile/precedence, or
count-distinct + threshold — both documented as real in D0840), built with plain functions like
the diabetes proof, so the API can be *extracted* from two policies; (b) turn `R/data.R`'s
hand-written mapping into a declared **source layer** (columns → roles), the most clearly-settled
piece. Constructors get pulled from these, not designed ahead.

**Still open:** absence/closed-world semantics with multi-source `NA` (does `closed_world(0)`
coerce `FALSE | FALSE | NA`, or only when every source was present?); concept composition
(diabetes re-inlines glucose vs `use_concept(glucose)`); D1's citation flag as a structured,
filterable column rather than a buried `CAUTION` substring; reducer vocabulary vs plain
`group_by |> summarise`; donor↔recipient linkage absent from `pmsi_actes`; the `pmsi_diag` view
dropping `SEJUM/SEJUF`.

**Files changed.** `HANDOFF.md` (this entry); `SPEC_MODEL.md` deleted (folded here). No code
edited; no commit yet.

---

## Migration proposal: prototype → generic study-spec engine — Claude → Codex/human (2026-06-24)

**Status: PROPOSAL for Codex review.** The owner has approved this direction and the doc
disposition; it is **not yet executed**. Please pressure-test the keep/prune/new lines and
the slice order before we cut — challenge anything that risks losing banked correctness.

**Why now.** The D0840-shaped prototype did its job: it taught us the model (see the
2026-06-24 convergence entry — source/concept/unit/variable/runtime, filter→extract→reduce,
link-by-role, combine-as-plain-R, completeness≠value). It cannot gracefully *become* the
generic tool by in-place edits — D0840 is fused into the engine (redsan columns, hardcoded
paths, per-variable types/adapters, copy-pasted helpers throughout).

**End goal (owner).** A generic engine that ingests a **study spec file** (sources +
concepts + variables, as data) and runs every variable. D0840 becomes one disposable study
spec. `source_spec`/`concept_spec`/`variable_spec` are the *vocabulary* that file is written
in; the engine ships the vocabulary + the runner.

**Three tiers** (sharpened — the warehouse is fixed, so deployment constants are NOT study
config):
1. **Engine** — pure mechanism; never names a column, analyte, model, ICD prefix, or timezone.
2. **EDSAN deployment config (write once, ~never changes)** — the redsan source column→role
   maps, `Europe/Paris` (a constant — the warehouse won't move), the default model
   `gemma3:4b` (overridable), dataset paths. Stable across all the institution's studies.
3. **Study spec (varies per question)** — concepts + variables (+ which sources each uses).
"Make D0840 disappear" = tier 3 becomes swappable; tier 2 is written once; the engine is clean.

**This is a heavy PRUNE + a thin new runner on a KEPT core — not a rewrite from zero.**

- **Keep (engine core, already ~generic):** evidence materialization + grounding + validity
  gating; coverage/attempt/values/evidence contracts; failure handling (retry, fail-closed,
  partial capture, transient classification); retrieval (canonical corpus + subset-before-
  search + snippet materialization); structured-measurement primitives (interval overlap,
  point window, max-select, threshold); `normalize_source`; the grammar-enforcement gate.
- **EDSAN tier (relocate ~as-is):** the three source_specs + Paris constant + default model +
  paths → one `edsan` config module.
- **Prune (delete):** `R/types/smoking.R`, `R/types/anastomoses.R`, `R/adapter_smoking.R`,
  `R/adapter_anastomoses.R`, and the exploratory/per-variable `scripts/*` (KEEPING
  `check_grammar_enforcement.R` — that's the model gate). The D0840 production runners
  (`run_synthesis.R`, `run_structured.R`) are superseded by `run_variables()`.
- **New:** study-spec assembly + `run_variable()`/`run_variables()` (input rows + models
  supplied at runtime, not embedded); **one generic parser** driven by a concept's
  answer-schema + validity policy (retires the per-type parsers); a small **reducer registry**;
  the per-source `handle` (filter→extract→reduce) + link-by-role scope + plain-R combine.

**Durable lessons to harvest before pruning (must not be lost):** ellmer boundary +
builders-vs-`type_from_schema`; the grammar-enforcement gate; fail-closed / no auto-repair;
evidence-by-reference + substring grounding; bounded outputs (maxItems/maxLength);
provider-params silently dropped (verify); candidate-recall as a metric separate from
extraction accuracy; Europe/Paris clinical date; one canonical corpus + subset-before-search.
These move into the rewritten `DESIGN.md` (rationale) + code comments.

**Slice order (never a broken limbo — something runs end-to-end at every step):**
0. Rewrite **DESIGN.md** to the target (the three tiers + the vocabulary) — the north star
   the rest executes against. Banner the old `DESIGN.md`/`TECHNICAL_NOTES.md` as "superseded
   prototype — see HANDOFF" until rewritten.
1. Stand up the engine skeleton + EDSAN config tier; port `normalize_source`, retrieval, and
   the structured-measurement primitives across unchanged.
2. Rebuild **diabetes** end-to-end on the new spine (it is the existing multi-source proof:
   documents/LLM + PMSI + biology, combined via `any`), green on synthetic fixtures.
3. Port the remaining variables (smoking, anastomoses, hyperkalaemia) onto the spine,
   deleting each old shell piece (type/adapter/script) as its replacement lands.
4. Build a **second, non-`any` policy** variable (reconcile/precedence, or count-distinct +
   threshold). Only now is extracting constructor *syntax* justified — two policies, per the
   defer-syntax guardrail.
5. Harvest + retire `TECHNICAL_NOTES.md`; touch up `README.md`.

**Acceptance / what's preserved.** As each variable is rebuilt, its behavioral contracts
(grounding, fail-closed, completeness≠value, the recipe states, D1's keep-and-flag) must stay
green on the new spine. The net test count is EXPECTED to drop — pruning D0840-coupled tests
is the point; the variable-agnostic engine-contract tests (the `engine_def` direction) are
what persist.

**Risks / open.** (1) Losing correctness in the port — mitigated by the slice order + keeping
behavioral tests green per variable. (2) The generic parser must reproduce the per-type
parsers' grounding/abstention/hallucination-flag (D1) behavior — port their tests. (3)
absence/closed-world + multi-source `NA` still unsettled. (4) constructor *syntax* stays
deferred until slice 4. (5) donor↔recipient link + `pmsi_diag` `SEJUM/SEJUF` gap remain.

**Files (this entry):** `HANDOFF.md` only; no code. **Requesting Codex review** of the
keep/prune/new lines and the slice order before slice 0 begins.
