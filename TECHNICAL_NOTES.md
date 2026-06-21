# extraction-engine — Technical notes

This document holds implementation detail, experimental findings, and the rationale
behind the shorter owner-facing [`DESIGN.md`](DESIGN.md). It is useful when building
or debugging the engine; it is not required to understand the product.

For the chronological discussion and raw experiment log, see [`HANDOFF.md`](HANDOFF.md).

## 1. Boundary with ellmer

ellmer owns:

- provider clients and authentication;
- structured-output calls;
- JSON-to-R conversion;
- parallel request machinery;
- common request and token plumbing.

This project owns:

- clinical variable definitions;
- anchor and scope resolution;
- retrieval and source adapters;
- prompts and JSON Schemas;
- construction policies;
- attempts, evidence, and provenance;
- review and evaluation.

The design keeps retrieval configuration and the model's output type separate:
the model never sees the corpustools query, and the output type is built in R with
ellmer's **type builders** (`type_object()` / `type_enum()` / `type_array()`) by
default. Raw JSON Schema is reserved for tested constraints unavailable through the
builders (see "Schema construction" below). The eventual author-facing
variable-definition format is deliberately deferred until the workflow has been
exercised on real variables.

Raw Ollama is an escape hatch for a measured capability gap, not a parallel engine
to maintain from the beginning.

### Schema construction: builders by default, `type_from_schema()` as escape hatch

We build output types with ellmer's `type_*()` builders **by default**, and fall back
to raw JSON Schema via `type_from_schema()` only for a tested constraint the builders
cannot express. Two findings explain why builders are the default, both verified in
ellmer 0.4.1:

1. **It does not validate the schema — only the JSON.** `type_from_schema()` runs
   `jsonlite::fromJSON()` (so a malformed *string* fails loudly), then stores the
   parsed list in an opaque `TypeJsonSchema` and sends it to the provider verbatim
   (`as_json` returns `x@json` untouched). Anything that is valid JSON but a broken
   *schema* — `{"type":"banana"}`, an `"enam"` typo that silently drops an `enum`
   constraint, an object with no `properties` — passes through with no error and fails
   late (wrong values) or only at a strict provider. There is a JSON-syntax net but no
   schema-semantics net.

2. **It bypasses ellmer's typed JSON→R conversion.** Conversion is done by
   `convert_from_type(x, type)`, which dispatches on the **S7 class of the type
   object** (`TypeArray` / `TypeObject` / `TypeBasic` / `TypeEnum`). The tibble
   conversion fires only for `TypeArray` whose `items` is a `TypeObject`. A
   `TypeJsonSchema` matches none of these classes and hits the final `else { x }`, so
   it returns the **raw parsed structure unchanged** (e.g. an array-of-objects comes
   back as a list of named lists, *not* a tibble). The builder path
   (`type_array(type_object(...))`) is what drives typed columns and the tibble.

Builders are also favoured by the contract itself: `evidence_refs =
type_array(type_enum(candidate_refs))` carries a **dynamic enum** whose legal references
depend on the evidence presented for that task, so the type is rebuilt per call —
natural with builders, clumsy as templated JSON.
Builders also fail loudly on a typo at construction time. (A per-task dynamic enum
means the type is task-specific, so it cannot be shared across prompts in one
`parallel_chat_structured()` call — see §4 on batching; the trade-off is separate
task-specific calls vs. a fixed short-alias vocabulary with unused aliases rejected in R.)

**The escape hatch is a real capability gap, not just portable storage.** The builders
expose only `description` / `required` (`type_string`) and `items` / `description` /
`required` (`type_array`) — there is **no `maxLength`, no `maxItems`** (passing them
errors), and the emitted JSON carries no size keyword. We have **measured** that a raw
`maxLength` *is* enforced through the Ollama schema→GBNF path (Handoff #3), so a bounded
`decision_note` or a small-`maxItems` `evidence_refs` is expressible **only** via
`type_from_schema()`. So the rule is: **builders by default** (readable, valid by
construction, typed conversion); **`type_from_schema()` as a narrow escape hatch** when a
required, tested JSON-Schema constraint is unavailable through the builders. Schemas as
external/portable data remains a separate, deferred question.

An output type belongs to an **extraction task**, not necessarily to one final cohort
column. Smoking may return a peri-operative status, several evidence references, and a
decision note. An anastomosis task may return several related durations, techniques,
and locations. Dialysis text extraction produces observations that R later reconciles
with CCAM and pre-emptive status. There is therefore no universal output object; each
task gets one explicit, readable contract.

## 2. Operational data contracts

The current text workflow uses four linked tables rather than one overloaded result
table. They are operational views; future structured-source adapters may expose
additional observation tables when their construction policies need them.

### Coverage

One row per expected extraction task, including tasks that never reach a model:

```text
task_id
subject_id
anchor_date
n_eligible_documents
n_candidates
processing_state
retrieval_version
```

`processing_state` distinguishes at least candidate-bearing, `no_candidate`, retrieval
failure, and intentionally unprocessed tasks. Coverage is the canonical task census.
It prevents a missing joined value from ambiguously meaning “no evidence,” “call
failed,” or “task forgotten.”

### Attempts

One row per model execution, including failures:

```text
attempt_id
task_id
provider
model
schema_version
prompt_version
started_at
latency_ms
status
error
```

Token counts, retry chains, and complete input lineage can be added when useful.

### Values

One row per captured extractor response:

```text
task_id
variable_id
value
unit
evidence_refs
decision_note
validity_state
review_status
attempt_id
```

`evidence_refs` is a list-column. Capture and validity classification are separate:
raw responses remain diagnosable, while invalid or review-required rows cannot silently
become cohort values.

### Evidence

One row per source reference cited by a value:

```text
task_id
evidence_ref
source
source_record_id
source_event_id
recorded_at
effective_at
hit_text
context_before
context_after
```

`recorded_at` and `effective_at` remain distinct because a recent note can describe a
remote historical event. The physician judges whether the materialized evidence
clinically supports the value; R checks only mechanical provenance and validity.

A flat review table is a view produced by joining values to evidence and coverage. It is
not the canonical storage contract.

## 3. Evidence by reference

The model does not generate an evidence quote. Where a source already has stable
coordinates, use them directly. For corpustools sentence retrieval the reference is:

```text
ELTID::sentence
```

Example:

```text
104::42 | 2025-02-20 | Ancien fumeur, sevré depuis 2010.
287::7  | 2025-03-04 | Tabac : sevré.
```

The hit sentence is citable. Configurable neighbouring sentences may be shown as
context, but they are not independently citable unless they are themselves hits.
Synthetic short aliases remain an optional model-compatibility optimization, not the
durable source identity.

For `smoking_status_periop`, these sentences were selected from documents recorded in
`[anchor − 365 days, anchor + 7 days]` around surgery. The output type contains a dynamic
evidence enum and a task-specific status enum:

```json
{
  "smoking_status_periop": "sevre",
  "evidence_refs": ["104::42", "287::7"],
  "decision_note": "Both peri-operative notes describe smoking cessation."
}
```

The allowed evidence values are the supplied references. Client code resolves each
reference to the stored source sentence and document. The decision note is a concise explanation of how
the model handled the supplied evidence; it is not itself evidence.

The status enum for this task is `actif` / `sevre` / `non_fumeur` / `indetermine`,
matching D0840's `tabac_statut` so outputs use the same vocabulary as the legacy task.
D0840 currently has no adjudicated smoking gold.
`actif` = an in-scope record describes current smoking; `sevre` = ex-smoker or cessation;
`non_fumeur` transcribes a documented non-smoker label (D0840 deliberately lumps
"non-fumeur", "jamais fumé", and "absence de tabagisme" here — it is not upgraded to the
lifetime claim "never smoked"); `indetermine` = the supplied evidence is contradictory or
insufficient. `no_candidate` is a separate workflow state produced by R before any model
call and is not part of the enum. Splitting `indetermine` into distinct `uncertain`
(conflicting) vs `not_stated` (silent) states, or adding a stronger lifetime `never`, are
deferred refinements that would each require reviewed labels encoding the distinction.

This avoids:

- fabricated or paraphrased quotations;
- unbounded evidence strings and output overflow;
- character-offset counting;
- mid-word truncation;
- ambiguity when several evidence units share a date.

For genuinely multi-span evidence, return an array of supplied references with a small
`maxItems`. A free-text evidence field with `maxLength` is only a fallback for a
source that cannot provide stable references.

## 4. Text retrieval and call granularity

The current default is one bundled call per extraction task, subject, and timepoint:

1. A project adapter supplies generic tasks (`task_id`, `PATID`, optional
   `anchor_date`, plus project metadata).
2. R computes the union of documents eligible for those tasks, creates a temporary
   metadata subset of the persisted canonical corpus with `copy = TRUE`, and runs the
   variable's retrieval query once.
3. R joins hits back to each task's exact patient/date eligibility, reconstructs the hit
   sentence plus configured neighbouring sentences, and deduplicates literal
   copy-forward evidence.
4. **If no candidates remain, coverage records `no_candidate`; no value row or model
   call is created.** Joining values to the complete task/cohort table later produces
   `NA`, never a clinical status or `not_stated`.
5. Otherwise one model call receives the in-scope evidence list, **with the anchor date
   as a context header** so it can weigh recency relative to the anchor when evidence
   conflict. R remains the gatekeeper for scope and eligibility — the model never
   recomputes the window.
6. The model returns its task-specific fields, including the value,
   `evidence_refs`, and (when useful) a `decision_note`.
7. R resolves the references and materializes the original evidence for physician
   review.

**Dynamic enums and batching.** Because the legal evidence references come from one
task's supplied candidates, the output type is task-specific. The initial
implementation therefore makes separate structured calls with separately built types.
`parallel_chat_structured()` cannot apply different types to different prompts in one
batch. A fixed short-alias vocabulary plus an R check for unused references remains a later
optimization only if measured throughput justifies weakening the grammar-level
constraint.

**Copy-forward handling.** Clinical notes frequently paste a prior statement
forward unchanged, so the same sentence reappears under many later dates. Dedup here is
an **efficiency** step (smaller prompt, no anchoring on a stale pasted line), not a
correctness mechanism. Dedup runs within each task after scoping and uses
`tolower(str_squish(hit_text))`. The canonical occurrence is the smallest absolute
distance from the anchor, then earliest record date, lexicographically smallest source
record id, then smallest sentence number. Excluded references and dates remain attached
for audit. For tasks without an anchor, the task must provide an alternative explicit
ordering policy. Exact-normalized matching catches literal copy-forward; semantic
restatement remains separate unless a measured need justifies more aggressive matching.

This keeps the call count bounded. Per-evidence-unit classification followed by
deterministic collapse is an escalation path if evaluation shows that bundled calls
mishandle contradictions, copy-forward, or target roles.

**Cross-field coupling (a measured question, not a settled fact).** A bundled call places
every field (`value`, `evidence_refs`, `decision_note`) into **one schema
generated left-to-right in one pass**, so the fields are statistically coupled — through
the shared schema and through the model priming on its own emitted tokens. This much is
established and demonstrable: a "space out the letters" directive in one field's
description carried into a *neighbouring* field's value, so descriptions are advisory text
in a shared prompt, not sandboxed per field.

What is *not* established, and must stay hypothesis until measured:

- that reordering fields cleanly separates "global-instruction interpretation" from
  autoregressive momentum — both can act at once, and a single stochastic run shows little;
- that declaring `evidence_refs` first makes the model "choose evidence before deciding" —
  this is **conceptually backwards**, not merely unproven: the *supporting* ids are defined
  relative to the value, so you cannot select what justifies an answer you have not yet
  formed. Evidence selection is posterior to, or co-determined with, the decision, never
  prior to it. Emitting the ids first only conditions later tokens; **serialization order
  is not reasoning order**, and the decision may already be latent before any token is
  emitted. (The reasoning-first pattern that *does* help is CoT — emit a rationale such as
  `decision_note` before the value — which is distinct from pre-selecting citations.)
- that value/evidence coupling validates correctness — it likely improves citation
  *relevance*, but value-vs-evidence agreement is **circular**, not an independent check.

**Confound to control.** ellmer's `Chat` is a mutable, stateful object; reused across
calls it carries prior turns
([Chat reference](https://ellmer.tidyverse.org/reference/Chat.html)). Every experimental
run must construct a **fresh chat**, or earlier turns silently become part of the prompt
and run-to-run comparisons are contaminated.

A disciplined probe, before drawing any conclusion: fresh chat per run; fixed model and
parameters; test **both field orders**; test **with and without** the planted instruction;
**repeat each condition**; and include **separate per-field calls as the true-isolation
control**.

**Design posture given all this.** Keep bundled
`value + evidence_refs + decision_note` as the default when the task benefits from all
three — a coupled answer, citation set, and explanation are operationally useful — but
treat the coupling honestly:

- every separately judged claim carries **its own** `evidence_refs`, never one shared
  evidence field for unrelated claims;
- evidence is **provenance, not verification**; internal value↔evidence agreement proves
  nothing on its own;
- R resolves ids and may assert mechanical consistency, but does not judge whether the
  evidence clinically supports the answer;
- physician review and adjudicated evaluation determine whether the cited references and
  decision note appropriately support the value;
- if changing field order changes the **clinical answer**, the task is **unstable**: fix
  or split it, do not select the convenient order. (A minor shift in *which* supporting
  reference is cited is tolerable; a flipped value is a defect.)

So the bleed finding supports bundling — not because "leakage is good," but because
coupled answers and citations are useful *provided we treat them as coupled, not as
independent checks*. Per-evidence-unit classification followed by deterministic collapse remains
the escalation path if measured bleed proves harmful.

Deterministic single-evidence preselection is also a policy option, not a universal
rule. A latest note can contain stale or contradictory content.

## 5. Anchors, scopes, and construction policies

The generic engine consumes tasks; it does not construct project events. A project
adapter maps its native data into a stable engine-facing table:

```text
task_id
PATID
anchor_date
... project metadata
```

`anchor_date` is optional. D0840's adapter may derive tasks from `DATEACTE` and retain
donor/recipient role; another project may use consultation, admission, examination, or
study timepoints. Source-column names and role logic stay outside the retrieval core.

Anchor rules are data that select a named resolver, for example first, last, or nth
event. The resolver returns the anchor date plus the event and record identifiers
used to establish it. **An anchor is optional:** whole-history ("ever") variables have
no anchor and scope the entire record, typically with the `any` policy.

A scope can combine temporal and relational constraints:

- `all` (the entire patient history, for "ever" variables);
- `<= anchor`;
- `+/- 30 days`;
- `(anchor_a, anchor_b]`;
- `same_event`;
- `same_stay`;
- `same_event OR within [-365d, +7d]`.

**The declared source scope bounds which records may answer the question; it does not
erase history explicitly summarized inside those records.** For
`smoking_status_periop`, a `[anchor − 365 days, anchor + 7 days]` source scope means only
documents recorded in the year before surgery through the first post-operative week are
eligible. An eligible note saying “ex-fumeur, sevré en 2010” supports `sevre` directly:
the note is an in-scope assessment that contains historical information. We do not combine
a current-status task with a whole-history `ever_smoked` task to manufacture the status.

The variable dictionary must state at least:

```text
variable:     smoking_status_periop   (≙ D0840 tabac_statut)
anchor:       surgery date
source scope: recorded_at in [anchor - 365 days, anchor + 7 days]
meaning:      smoking status documented around surgery
values:       actif / sevre / non_fumeur / indetermine
absence:      open world
no candidate: no_candidate (R-side, no model call); never infer non_fumeur
```

If no eligible candidate exists, record `no_candidate` and make no model call. If
eligible supplied material is contradictory or does not establish a status, return
`indetermine` (D0840 folds both cases into this one value). `non_fumeur` requires an
explicit documented non-smoker statement and is never inferred from silence. Two
refinements are deliberately deferred until reviewed labels can encode them: splitting
`indetermine` into distinct `uncertain` (conflicting) vs `not_stated` (silent) states, and
adding a stronger lifetime `never` (which would require explicit “jamais fumé” evidence). A
question such as “ever smoked anywhere in the available record” would be a separate
whole-history variable.

### Two text-extraction modes

The earlier blanket rule—“the model never returns current/former/never; R always derives
the category”—was too broad. Use one of two modes according to the variable's meaning:

1. **Documented-status transcription.** An eligible clinical record already states the
   category. The model returns the task's enum directly and cites the record. The source
   scope filters where that documented assessment may come from; the statement itself
   may summarize older history. `smoking_status_periop` uses this mode.
2. **Derived synthesis.** No single documented status answers the question. The engine
   extracts independently meaningful observations from their appropriate scopes, and R
   combines them with an explicit rule. This remains appropriate for genuine lifetime
   reconstruction or cross-source composites.

Neither mode permits inference from silence. The first transcribes a documented
assessment; the second combines explicit observations.

### Absence policy

`no_candidate` describes retrieval and scoping: no eligible candidate reached the
extractor. It is not a universal clinical value. Every task must separately declare what
may be concluded when no positive evidence is found.

Absence policies may differ by source. No qualifying ICD-10 code in a complete,
well-defined extract can support a stronger conclusion than no lexical text hit, which
may simply be a retrieval miss. Preserve the source-level reason and coverage state;
never pool unlike absences into one undocumented negative.

Use three broad policies:

1. **Open world (default).** Absence of documentation is unknown. Keep the analytical
   value missing or explicitly report `no_documented_evidence`; do not return a clinical
   negative.
2. **Explicit negative required.** A negative value is allowed only when an eligible
   source explicitly states it. Smoking uses this pattern: `non_fumeur` requires a
   documented non-smoker statement. Silence remains `no_candidate` or `indetermine`,
   depending on whether any relevant candidate reached the model.
3. **Closed world by construction.** Absence may become negative only when the task
   defines sufficient source coverage and a defensible ascertainment rule. The rule and
   coverage requirements must be versioned and preserved with the result. A retrieval
   or source-access failure remains missing even for an otherwise closed-world task.

Diabetes illustrates why this is necessary. Clinical notes rarely say “not diabetic.”
A text or code search with no candidate means only “no diabetes evidence was retrieved,”
not `diabetes = no`. A diabetes variable may produce:

```text
yes                     explicit qualifying evidence exists
no_documented_evidence  required sources were available, but no qualifying evidence exists
missing                 source coverage was insufficient or retrieval failed
```

Calling `no_documented_evidence` simply `no` requires a deliberate, documented
closed-world decision. Even then, retain the underlying candidate and coverage state so
the analytical negative remains auditable.

Source adapters turn raw records into source-backed observations. Construction policies
turn scoped observations into values. Initial policy families grounded in D0740/D0840
are:

- `identity` for a single valid source result;
- `any`;
- `nearest`, `first`, and `last`;
- `summarise` with count or count-distinct thresholds;
- `rank_select` with ordered tie-break keys;
- `reconcile` for source precedence and conflicts;
- `collect`.

Policies are named and tested R functions. The spec selects a policy and supplies
parameters. There is no generic boolean or derivation DSL.

Examples from the existing projects:

- D0740 biology selects the latest examination on or before an anchor.
- D0840 biology ranks by target distance, preferred side, analyte priority, date,
  and record id.
- D0840 dialysis combines 90-day and 365-day scopes, count-distinct thresholds,
  source precedence, and conflict review.

## 6. Derived columns

Derived variables remain ordinary project-level R:

```r
features$poids_delta <- features$poids_t1 - features$poids_t0
features$tabac_changed <- features$tabac_t0 != features$tabac_t1
```

There is no derived-variable spec, registry entry, or rule interpreter. If lineage
documentation is later needed, it should be generated from or kept next to the R
code rather than maintained as a second executable description.

Do not introduce derivation merely to split one clinical question across mismatched
horizons. `smoking_status_periop` is an observed categorical value extracted directly
from eligible in-scope records. Ordinary R derivation remains appropriate for true
computed variables such as deltas, change indicators, or composites over independently
meaningful inputs.

## 7. Structured decoding and failure handling

A JSON Schema constrains legal output tokens. It guarantees structure, not clinical
truth. Unbounded string fields can still grow, and a model can still choose the wrong
legal enum.

Every candidate model must pass a grammar-enforcement gate using a bare structured
call without a strong JSON-following prompt. Reject any model that escapes the
schema. The rule is based on observed behaviour, not a permanent ban on a category
of models.

The runtime path is:

1. call structured extraction;
2. validate the returned object;
3. record success or failure in the attempt table;
4. retry under a small explicit policy when appropriate;
5. fail closed when retries are exhausted.

Partial clinical JSON is never repaired automatically because repair can invent the
field being audited. Capture and consumption are separate: preserve the raw response
and its validity state, but prevent invalid rows from becoming cohort values.

Evidence requirements may depend on the returned value. For the smoking task,
`actif`, `sevre`, and `non_fumeur` require at least one valid evidence reference;
`indetermine` may legitimately return an empty array. An empty `decision_note` is valid
when there is nothing useful to explain. Unknown references remain structurally invalid.

## 8. Provider-parameter verification

Provider abstractions can silently drop parameters. A parameter is not considered
active merely because it was supplied.

For the current ellmer/Ollama OpenAI-compatible path:

- generation controls such as temperature, seed, and output cap belong in
  `ellmer::params()`;
- values passed through native-style `api_args$options` may be ignored;
- context size must be verified from the server or configured outside that request
  path when necessary.

General rule: verify determinism by running identical requests twice and comparing
outputs; verify runtime settings through server telemetry or logs.

Current model-specific results and incident history belong in `HANDOFF.md`, not in
the durable architecture.

## 9. Canonical text corpus, retrieval, and evaluation

### Canonical corpus

Build one corpustools `tCorpus` per document collection, not one corpus per variable or
query. The canonical construction currently uses:

```r
corpustools::create_tcorpus(
  documents,
  text_columns = "RECTXT",
  doc_column = "ELTID",
  split_sentences = TRUE,
  remember_spaces = FALSE
)
```

No UDPipe model is used. Sentence boundaries come from corpustools' basic tokenizer.
`ELTID` must remain unique in the document collection; fail clearly if upstream
manipulation breaks that invariant.

The corpus is persisted with `saveRDS()` and reloaded for later variables. On D0840,
65,397 non-empty documents produced 44.6 million tokens and 6.1 million sentences:
build 115.7 seconds, save 65 MB, load 1.3 seconds. Document/token counts, full metadata,
and the pinned-query hit set were identical after reload. Eleven of the 65,408 source
rows were excluded because their text was empty after trimming; this is explicit input
cleaning, not unexplained corpus loss.

Persisted corpora are package/runtime artifacts. Revalidate serialization and hit
stability when upgrading R or corpustools.

### Subset before search

For one variable:

1. calculate each task's eligible document ids in ordinary R;
2. take their union;
3. create a temporary corpus with
   `canonical_tc$subset(subset_meta = doc_id %in% eligible_ids, copy = TRUE)`;
4. run the declared retrieval method once;
5. join hits back to each task's exact patient and temporal eligibility.

`copy = TRUE` is mandatory: the canonical corpus must never be mutated.

This order is measured, not assumed. On D0840, the peri-operative windows selected
13,287/65,397 documents. Median warm timings were 97.1 seconds for full-corpus search
versus 11.5 seconds for subset-copy plus search and join, with identical 1,856 eligible
references. Temporary metadata subsetting is therefore the default execution path.

### Sentence evidence and context

Sentence-level search returns native `ELTID + sentence` coordinates. Reconstruct only
the hit sentences and their requested neighbours from the temporary subset's tokens;
do not materialize every sentence in hit documents.

A deterministic normalized untokenizer supplies readable text without claiming exact
source whitespace. For example:

```text
non - fumeur , 20 PA .  ->  non-fumeur, 20 PA.
```

On D0840, reconstructing only hit sentences ±1 produced 5,218 sentences in 0.9 seconds.
Reconstructing every sentence in hit documents produced 1.68 million sentences and took
212.5 seconds. Exact-space reconstruction remains an optional fallback only if
physician review shows normalized text is inadequate.

Context strategy is configuration, not universal architecture. Sentence ±1 is the
current clinical-text default. Whole-document or other strategies may be selected by a
task; fixed-token KWIC is not the default because it cuts sentences and has been slow in
prior use.

### Retrieval method and evaluation

A variable chooses its retrieval method—such as a Lucene query or a regex. The normal
pipeline does not automatically compare both. Comparison tooling may be used during
development, but does not belong in the core execution path.

Lexical retrieval may miss abbreviations, spelling variants, indirect evidence, or
evidence lost by sentence parsing. Copy-forward also complicates the interpretation of
document dates.

Evaluate retrieval separately from extraction:

- candidate recall: did the evidence-bearing record enter the candidate set?
- extraction accuracy: given candidates, was the value correct?
- evidence grounding: did the model select the adjudicated source reference?
- abstention: how often retrieval/scoping returns `no_candidate`, with a hand-audited
  sample to distinguish true lack of documented evidence from a recall miss. A
  `no_candidate` is interpreted only through the task's absence policy and is never
  silently reported as `non_fumeur` or `diabetes = no`. This is where compound recall
  failure—a query miss and a scope miss—hides, so it is the highest-value thing to audit
  by hand.
- operational reliability: failures, latency, and retries.

Gold is usually absent at first. Review-ready output is still useful:

1. export values with materialized evidence;
2. record agreement or a corrected value;
3. preserve reviewed rows as gold;
4. enable evaluation as labels accrue.

That is the current D0840 situation: the available smoking pool contains inputs, and
`tabac_gpt` / `test tabac.xlsx` contain prior model outputs, not adjudicated truth.
Posterior physician review creates reviewed labels. Because the reviewer sees the
suggested answer and evidence, agreement on that same run is descriptive and
model-assisted; it must not be reported as an independent accuracy estimate. A later
independent estimate requires fresh cases or adjudication performed without exposing
the tested model's prediction.

Absolute retrieval recall is generally unknowable without an oracle. Report recall
on labelled samples or coded silver standards. Query-overlap counts without labels are
difference measurements, not recall, precision, or accuracy.

## 10. Established findings and next variables

The smoking rounds and retrieval experiments established:

- ellmer's **type builders** are the default schema path: they validate by construction
  and drive typed JSON→R conversion (tibbles), whereas `type_from_schema()` neither
  validates the schema nor converts the result. `type_from_schema()` is kept as a narrow
  escape hatch for tested constraints the builders cannot express (`maxLength`,
  `maxItems`) (§1);
- structured calls can be made deterministic when parameters reach the provider;
- the attempt log captures real parse and server failures without aborting the run;
- model grammar enforcement must be tested rather than assumed;
- generated evidence text is the wrong contract;
- native corpus coordinates are preferable to synthetic evidence aliases when available;
- one canonical corpus can be persisted and reused across variables;
- metadata subsetting before search is substantially faster than full-corpus search on
  the current corpus;
- reconstructing only hit sentences and requested neighbours avoids enormous sentence
  tables;
- exact source whitespace is not required for the default review/model context;
- coverage (`no_candidate`) and clinical values are separate concepts.

The next independent implementation rounds are:

1. transplant anastomoses — one operative context producing several related fields,
   field-specific evidence, and partial missingness;
2. biology timepoints — deterministic selection from structured results around anchors.

Claude and Codex implement each independently before mutual review. Dialysis follows as
the multi-source reconciliation stress test. Shared abstractions are extracted only
after repetition appears across these real tasks.

## 11. D0840 development corpus

### Purpose and inventory

D0840 is a development corpus, not a model-fine-tuning dataset. It is used to develop
and compare extraction workflows: retrieval, scoping, prompts, output contracts,
deterministic policies, provenance, review exports, and evaluation.

It does not currently contain adjudicated gold. Existing cached outputs are useful
baselines and debugging material, not truth labels.

The existing project contains 134 final output columns, but those columns arise from a
much smaller number of reusable task shapes:

- 58 columns use the same biology timepoint-selection machinery;
- 31 columns are labelled as LLM-produced in the data dictionary;
- the implementation contains roughly ten `gpt_column()` task families;
- several final variables are constructed by combining LLM observations with PMSI or
  other deterministic sources.

The important unit is therefore the **extraction task**, not the final wide-table
column. One task may emit several related observations, and one final variable may
combine several tasks or sources.

### Representative task set

| D0840 task | What it teaches |
|---|---|
| Smoking status around surgery (`[anchor − 365d, +7d]`) | Persisted-corpus retrieval, window-bounded source selection, target-role filtering, explicit status categories, contradictions, `evidence_refs`, and a useful `decision_note`. |
| Transplant anastomoses | One context producing several related durations, techniques, and locations; partial missingness; cross-field coupling. |
| Dialysis before transplant | Multi-source construction: pre-emptive status, CCAM counts and thresholds, text observations, source precedence, and disagreement review. |
| Biology timepoints | Deterministic anchor-relative selection with tolerances and ordered tie-breakers; proves the engine is not an LLM-only system. |
| Delayed graft function | Explicit positive and negative text rules, risk-only mentions, conflicting values, and routing to review. |
| Surgical antecedents | Whole-history scope, several clinical categories in one task, repeated mentions, exclusions, and multi-item evidence. |

The duplicate-implementation order is smoking → anastomoses → biology. Dialysis then
tests multi-source reconciliation. Delayed graft function and surgical antecedents test
whether the emerging abstractions survive different conflict and scope patterns. Only
repetition demonstrated across working tasks should become shared configuration or
package code.

### Development, validation, and held-out discipline

Split at the **patient or transplant-pair level**, never at the snippet or document
level. Otherwise records from the same clinical case can leak across sets and make
performance look better than it is. If a patient has several linked episodes, keep
those episodes in the same split unless the evaluation question explicitly concerns
generalisation across episodes.

- **Development set:** visible during implementation. Use it to inspect failures,
  improve retrieval and prompts, refine output types, and write synthetic regression
  fixtures. Posterior physician corrections may become frozen regression labels.
- **Validation set:** frozen while one round of alternatives is compared. Use it to
  choose models, prompts, bundling strategy, thresholds, and other design options.
  Repeatedly consulting it eventually turns it into development data; when that
  happens, freeze a new validation set.
- **Held-out set:** untouched until the task contract and decision rules are fixed.
  Use it for the final estimate reported for that version. Do not alter the approach
  in response to held-out errors without declaring a new development cycle and
  reserving a new held-out set. For a defensible accuracy estimate, adjudicate these
  cases without showing the tested model's prediction, or use an independently reviewed
  set.

Stratify each split where feasible so rare but important cases are represented:
positive, explicit negative, not stated/no candidate, uncertain or contradictory,
multi-document, long-context, and known retrieval traps. Synthetic fixtures complement
these sets but do not replace held-out real cases.

Keep all clinical text, split assignments, adjudications, and row-level model outputs
local and gitignored. The repository may contain code, synthetic fixtures, aggregate
metrics, and documented conclusions. Persist split membership and task/prompt/model
versions locally so later comparisons use the same cases.
