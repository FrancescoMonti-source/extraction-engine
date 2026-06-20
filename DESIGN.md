# extraction-engine — Design

> **Status:** Phase 0 step 1 (contract smoke test) **built and run** — see `scripts/`
> and the running log in `HANDOFF.md`. Design ratified across 4+ Claude↔Codex review
> rounds.
> **Name:** `extraction-engine` is a **placeholder** — rename later.
> **Lineage:** focused successor to `gptr`. Captured from an extended design
> conversation begun 2026-06-19. **This doc is the source of truth and is kept current
> with every ratified decision** — `HANDOFF.md` holds the rationale/history, but the
> *current* design lives here. The "Decisions & rationale" section is the point.

---

## 1. Problem & positioning

Turn messy clinical free text — **and** structured EHR sources (ICD-10, CCAM,
labs) — into tidy, validated, **audited** analytical variables for longitudinal
cohort studies in a clinical data warehouse (EDSaN). Text often must be read by
**local** models (privacy), which makes them **weak and unreliable**, so every
extracted value must be **auditable**: a human must see exactly what was read and
why the model answered as it did.

**The bet.** Do *not* compete with [ellmer](https://ellmer.tidyverse.org/) on LLM
transport / structured output (Posit owns that: multi-provider incl. Anthropic,
maintained, with JSON→R conversion). Build the layer ellmer and `mall` do **not**
center:

- per-subject **anchoring** and **windowing** of time
- **multi-source** dated-hit gathering (codes + labs + text)
- **construction-policy**-based collapse of hits into analytical values
- **derivation** of computed variables
- **validation** with per-field failure metadata
- **evidence / audit** trail per value
- **evaluation** against gold (the centerpiece)

**What it is NOT:** a general LLM client; a chat/agent library; a provider
abstraction. It guarantees the *shape* of an answer and *measures* its
correctness; it never *asserts* correctness.

**Why a new repo and not more gptr:** gptr's JSON-repair + validation engine is
hard-won and worth keeping, but gptr is positioned as a generalist LLM client and
loses there. This is the focused successor — fork in spirit, not a rewrite. Build
the *application* first; extract the *library* once the abstractions are proven
across ≥2 real fields. (We have prior art and ≥2 fields, so this is grounded, not
premature.)

---

## 2. Architecture — a three-layer engine + a plain-R derive stage

The **workflow** is four stages; the **engine** is only the first three. Derivation
is ordinary project R that runs *after* the engine — it reads no records, calls no
model, and is not an engine layer (Review #3).

```
ENGINE (three layers, the thing this project builds):
  Layer 0  ANCHOR     per-subject index date(s) from a rule     (build_first/last_dmo_index, generalized)
  Layer 1  EXTRACT    sources -> dated HITS                      (source adapters)
  Layer 2  CONSTRUCT  scoped hits -> timepoint values            (named construction policy)
  ─────────────────────────────────────────────────────────────────────────────────
  then, NOT an engine layer:
  DERIVE             constructed features -> computed columns    (plain R: deltas, changed, composites; no text)
```

**The narrow waist is the HIT.** Sources fan **in** to hits; construction policies
fan **out** of hits. Because they only meet at this one fixed contract, complexity
is **N + M, never N × M** — the single principle that bounds the design. (Proof:
D0740's `bind_comorbidity_hits()` already merges ICD + CCAM + text into one hit
table everything downstream treats identically.)

Three linked contracts, not one overloaded table (Review #1):

```
attempt = (attempt_id, spec/schema/prompt versions, provider, model,
           input_record_ids, timing, status/error, tokens, latency)   # one model run, incl. failures
hit     = (hit_id, subject_id, variable_id, value, unit, source,
           source_record_id, source_event_id?, recorded_at, effective_at?,
           evidence, attempt_id?)                                      # one source observation
value   = (subject_id, variable_id, timepoint_id, value, unit,
           selected_hit_ids, n_candidates, policy/version, .valid,
           .failure, review_status)                                   # one constructed decision
```

- `recorded_at` vs `effective_at`: a note *recorded* near the anchor can describe
  an event years earlier — keep both.
- Evidence is a **reference, not a copied quote**: the model returns an `evidence_id`
  (the id of the justifying snippet, e.g. `S02`) drawn from a dynamic enum, and the
  client materializes the text from its own snippet table — exact by construction, no
  hallucinated quotes possible. See §5 "Evidence by reference". Model-reported
  `confidence` is non-canonical raw metadata only.
- **Build incrementally, but a *minimal* attempt record starts in Phase 0**
  (Review #2): Phase 0 already measures attempt failures, latency, model, and
  prompt/schema version, so those fields are written from the first spike. What
  defers is the *rich* lineage/cost metadata (tokens, full input-record sets,
  retry chains) — not the attempt table itself.

---

## 3. The spec model — observed-task specs vs plain-R derivations

A variable is one of two things, and only one of them gets a spec (Review #1; sharpened
R#2 — not "two spec shapes," because a derived variable has *no* spec):

- an **observed task** — read from records, described by a spec (below);
- a **derived variable** — computed from already-produced columns, just ordinary R,
  no spec at all.

The four-axis model was only ever true of observed tasks.

### A. Observed task (read from records) — four axes

A thing the model or a code-lookup *finds* in text/codes. Four axes, all data:

1. **Anchor** — a per-subject index date from a rule. `t0/t1 = first/last DMO
   event` is just *one* instance. Rules are data that parameterize a **bounded
   resolver registry** (e.g. `resolver: nth_event, event_set, order, n,
   after: <ref>`) backed by named, tested resolver functions. A new clinical
   relation may need a new resolver fn (fine); recreating the pipeline per variable
   is the failure mode.
2. **Scope** (was "window") — a temporal interval **plus optional relational
   predicates**: `<= anchor`, `+/- N days`, `(a, b]`, `[anchor-5y, anchor]`, **and**
   `same_event`, `same_stay`, `after(ref)`. (`receveur_dialyse` needs
   "same surgical encounter OR within [-365d,+7d]" — a date interval alone can't
   say it.)
3. **Construction policy** (was "behaviour") — how to collapse windowed,
   multi-source hits. A *named, tested policy* that may include **source precedence
   and conflict handling**, not merely one scalar reducer.
4. **Sources** — where dated hits come from: ICD codes, CCAM acts, labs, text.

### B. Derived variable (computed) — inputs + plain R

A thing you *calculate* from already-produced variables — no text, no model, no
sources. **The engine does not touch these at all.** They are **ordinary
project-level R** in a `derive.R` step:

```r
features$poids_delta   <- features$poids_t1 - features$poids_t0
features$tabac_changed <- features$tabac_t0 != features$tabac_t1
```

No spec, no registry entry, no `type: derived` row, no `inputs:` list — that was a
second specification system duplicating `derive.R` (Review #2 caught it). A `rule:`
interpreter would reinvent R, badly; even a *documentation-only* registry entry is
machinery you don't need. If a data dictionary later wants to list derived columns
for lineage, generate it *from* `derive.R`, don't hand-maintain a parallel spec.

**Only observed/source-backed tasks get engine specs.** The spec is DATA that
drives the extraction layers; derivation is just R that runs after.

### Unified spec row (target shape)

`schema` is **JSON Schema as data** (ellmer consumes it via `type_from_schema()` —
no `type_*()` objects in the spec).

```r
tabac = list(
  sources    = list(llm_text = list(query  = "taba* OR fum* OR cigar* OR clope* OR sevrage",
                                     schema = list(type = "string",
                                                   enum = c("never","former","current","not_stated")),
                                     instruction = "...")),
  timepoints = list(t0 = anchor("first_dmo", scope = "+/-30d"),
                    t1 = anchor("last_dmo",  scope = "+/-30d")),
  policy     = "nearest",                                    # construction policy
  evidence   = TRUE,
  outputs    = c("tabac_t0", "tabac_t1")                     # tabac_changed is NOT here: derived later in plain R
)
```

A multi-source comorbidity carries one config slice per source as data:

```r
diabete = list(
  sources = list(
    pmsi_diag = list(icd10 = c("E10","E11")),
    pmsi_acte = list(ccam  = c("...")),
    llm_text  = list(query = "diab*", schema = list(type="string", enum=c("yes","no","not_stated")), instruction = "...")
  ),
  timepoints = list(t1 = anchor("last_dmo", scope = "<= anchor")),
  policy     = "any"
)
```

---

## 4. Bounded primitives

The fear was "how many behaviours / how much source-specific code." Both are
bounded by the narrow waist and are *additive*.

### A registry of named construction policies (Review #1)

The "~5 reducers" claim was too clean — it validated against D0740's simple
variables but missed D0840's reconciliation logic. The bounding *principle* holds
(a small, closed, tested set — **not** a DSL), but it's a **registry of named
construction policies**, each a pure function `(hits, params) -> value +
justifying hit ids`:

| policy | does | seen in |
|---|---|---|
| `any` | a positive hit exists in scope | accumulative history, events |
| `nearest` | value of the hit closest to the anchor | point-in-time status, measures |
| `first` / `last` | earliest / latest in scope | immutable, onset |
| `summarise(fn)` | min/max/mean/**count**/**count-distinct** + threshold | severity; "≥2 distinct days" (repeated acute dialysis) |
| `rank_select` | pick one hit per group by an ordered key list | **two real points on the same axis:** D0740 biology = a *single* recency key (latest exam on/before anchor, per analyte, `biol.R:279`); D0840 biology = a *5-key* chain `abs_diff_target → target_side_priority → source_priority → desc(DATEXAM) → desc(ELTID)` (`D0840.R:3390`). One named policy, parameterized by the key list — add keys per variable, no new code. |
| `reconcile` | source precedence + conflict → value or **review** | pre-emptive > coded > text; disagreement routes to review |
| `collect` | all values -> list | array-valued (surgical_history) |

Specs **select one named policy and supply parameters** — no `AND` / `NOT` /
ordering / dependency operators in the spec (Review #2: those reintroduce an
interpreted rule language with its own validation and failure semantics, the exact
thing we're avoiding). When a variable needs more than one policy can express
(`new_between` = positive in `(a,b]` but not in `<=a`; `history_plus_activity` =
two outputs), **compute it in plain R from the constructed values**, or — only once
the *same* composite proves reusable across variables — promote it to a new named
policy with its own tests. Never a generic combinator grammar; never preemptively.

### ~4 source adapters, written once

Adapter job: `raw source + variable's source-config -> tidy hits`. After the hit,
everything is source-agnostic. Two kinds:

- **Structured / coded** (deterministic lookup — cheap, exact, no LLM):
  - `pmsi_diag` — ICD-10 code-set membership, dated by stay (`extract_comorbidity_hits_from_pmsi_diag`)
  - `pmsi_acte` — CCAM procedure code-set, dated (`extract_comorbidity_hits_from_pmsi_actes`)
  - `biol` — lab analyte match (+ optional threshold), dated by exam (`extract_biology_measurements`)
- **Unstructured / text** (retrieval + grammar — expensive, probabilistic):
  - `llm_text` — the only source needing retrieval + grammar + schema (`resolve_*_llm_docs`)

Source-specific **logic** = adapter code (write once). Source-specific **config**
(code-sets, analyte names, query/schema) = spec **data**.

---

## 5. Cross-cutting decisions

- **Grammar-constrained decoding.** A JSON schema handed to Ollama's `format`
  (or via ellmer structured output) is compiled into a GBNF grammar that masks
  illegal tokens at each decode step (it *forbids*, never *boosts*; the model's
  preference still chooses among the survivors). **Guarantees JSON shape, never
  truth.** It also guarantees a string is *a* string, not a *short* or *honest* one
  (hence the evidence design below). Enforcement is server-side; the client just
  passes the schema.
- **Vet grammar enforcement per model; reject any model that fails the gate.** Masking
  is model-agnostic *in principle*, but some models (e.g. certain reasoning/"thinking"
  models) emit a free-text stream that isn't under the schema grammar and escapes to
  prose. The **durable rule is the gate, not a ban on a model *category***: before
  adopting any local model, run `scripts/check_grammar_enforcement.R` — a bare structured
  call, no system prompt, stochastic sampling — and **reject any model that escapes**.
  "Returns valid JSON behind a strong prompt" is **not** evidence of enforcement; it can
  be prompt-following that fails open on weak/long inputs. *(Which models were tested,
  which passed/failed, and the current default are **configuration**, recorded in
  `HANDOFF.md` — not architecture.)*
- **Fail closed, do not repair (Review #1).** Grammar kills *syntax* errors, but
  truncation / cancellation / server failure still produce partial objects (a probe
  with `max_tokens=2` gave `premature EOF` even under structured output). So
  *syntax-repair depreciates, but failure-handling does not*: validate against the
  schema → record an attempt-level failure → bounded explicit retry → **fail
  closed** if exhausted. **Never auto-repair a partial clinical object** — repair
  can invent the very field being audited. Missing extraction is visible;
  synthesized extraction is not. Keep gptr's *validation + failure-metadata*;
  retire its *repair* to a legacy/diagnostic adapter.
- **Evidence by reference (`evidence_id`), not copied text (Handoff #3).** Each value
  still carries the evidence behind it, but the model returns the **id of the
  justifying snippet** from a **dynamic enum of the supplied snippet ids + `none`**. The
  grammar then makes a fabricated or out-of-set id impossible, and the client
  materializes the sentence from its own table. This beats a copied quote on every axis:
  no fabrication, no unbounded output / overflow, no char-counting, no mid-word
  truncation, direct provenance to doc-id/date, and a clean grounding metric
  (`selected id == adjudicated id`). The reference key is a **per-snippet id, not a
  date** — one date can carry several snippets. Multi-span evidence → an **array of ids
  with a small `maxItems`**, never a reopened unbounded string. *Mechanics:* this
  requires the text source to be presented as a **numbered, dated snippet list**
  (Layer 1), not a concatenated blob. `evidence` lives on the `hit` (which carries the
  snippet id); a constructed `value` references its `selected_hit_ids`. The canonical
  contract is the three tables in §2 (attempt / hit / value), **not** a flat
  `(subject, date, variable, value, evidence, …)` long table (Review #2); a flat
  long-format *view* for review/eval is trivial to materialize.
  *(A schema `maxLength` on a free-text evidence string is also grammar-enforced end to
  end — tested: gemma3:4b capped at exactly N even when told to over-copy — but a
  truncated prefix can pass a substring check while dropping decisive context, so
  reference-by-id is preferred; `maxLength` is only a fallback for sources that cannot
  provide stable snippet ids.)*
- **R scopes and orders; the model selects evidence and classifies — one bundled call
  (Handoff #3).** R owns anchor resolution, scope filtering, ordering, numbering, and
  validation. The model receives the **numbered in-scope snippets** in **one bundled
  call per subject/timepoint** and returns `status + evidence_id` — it *selects which
  supplied snippet is the evidence*. R does **not** pre-pick "the latest snippet": the
  latest note can copy-forward stale text, contradict itself, or mix donor/recipient, so
  the temporal *scoping/ordering* belongs to R while *selecting the decisive snippet*
  belongs to the model. **Deterministic single-snippet preselection is a policy option,
  not a universal rule**; call granularity (bundled vs per-snippet-then-collapse) is
  decided **empirically** from the adjudicated set. Per-snippet classification + collapse
  is an *escalation path*, used only if bundled calls measurably mishandle dated
  contradictions / copy-forward / target-role.
- **Provider parameters must be verified to take effect (durable rule).** An
  abstraction layer can silently drop a param depending on the endpoint, so **verify
  every lever** — run twice and diff, or read the server log — never trust that setting
  it worked. *(Confirmed in Phase 0: ellmer drives Ollama via its OpenAI `/v1` endpoint,
  where generation params must go through `params()` and `api_args$options` is ignored —
  `temperature` and `num_ctx` were both silently dropped; `max_tokens` is the output cap,
  `num_ctx` the shared window. The specific incidents, values, and fixes live in
  `HANDOFF.md`.)*
- **Missing values.** `not_stated` (an enum sentinel) is a *generation-time
  device* giving a weak model a legal "I don't know" token so the grammar does not
  force a real category; it collapses to `NA` in the output. `required` (structural
  nullability) is the missing channel for *non-enum* types (numbers, free text)
  that cannot carry a sentinel. **Derive missing-handling from the type**, do not
  make it a per-variable field. They are not redundant; they are type-specific.
- **Retrieval is a replaceable baseline, not the foundation (Review #1).** Lexical
  (corpustools), sensitivity-first (over-retrieve, let the model + `not_stated`
  filter). KWIC snippets with full-doc fallback; **dedup copy-forward** is
  essential; per-variable retrieval is also *call*-reduction. But lexical misses
  typos/abbreviations, indirect evidence (a drug implying a condition), untermed
  concepts. **Mandatory guardrail: measure candidate recall *separately* from
  extraction accuracy** — on an adjudicated doc sample, did the evidence-bearing
  record enter the candidate set? Version the query with the prompt/schema; coded
  sources give a biased silver subset. Add a union retriever (semantic / full-doc)
  only if measured misses justify it.
- **Gold is usually ABSENT, and accrues by review.** The default pipeline runs
  with NO gold: extract → surface value+evidence+provenance → clinician reviews
  (agree / correct) → each adjudicated row becomes a gold label → eval becomes
  possible. **Review-capture is always-on; eval is a capability that switches on
  as gold accrues, never a precondition.** The engine must be fully useful
  gold-absent.
- **Eval, when gold exists.** Per-variable precision/recall, enum confusion,
  per-model, grammar-on vs off. **Absolute recall is unknowable** in a warehouse
  (no oracle) — report **relative** (query v2 vs v1) and **anchored** (coded
  silver standards / labelled samples) recall, never claim absolute.

---

## 6. Decisions & rationale (the precious section)

| Decision | Why | Alternative rejected |
|---|---|---|
| Four-stage workflow (three-layer engine + plain-R derive) + narrow-waist hit | Discovered from D0740's 7 near-identical feature blocks; makes sources & policies additive; derive stays outside the engine | Per-variable bespoke pipelines (the 7 copy-pasted blocks = accidental complexity); derive baked into the engine |
| Spec as data | Editable, versionable, reviewable, scales to ~50 variables | Bespoke code per variable |
| One call per extraction task (per subject/timepoint) | Weak models do better one-at-a-time; enables per-task retrieval + resumability | Nested multi-variable single call (degrades on weak models) |
| Engine = **ellmer** (ratified R#1); raw Ollama = escape hatch | `type_from_schema()` keeps specs JSON-Schema *data* while ellmer supplies providers / structured-output / conversion / parallelism | Our own provider layer; raw Ollama as a co-equal engine |
| Build app first, extract library later | Don't guess abstractions; we have prior art + ≥2 fields | Premature packaging |
| Focused successor, not gptr rewrite | The JSON-repair/validation engine is hard-won | From-scratch rewrite loses it |
| Evidence by reference: `evidence_id` dynamic enum, not copied text (Handoff #3) | Exact-by-construction, bounded output, clean grounding metric; per-snippet id handles multiple snippets per date | Copied quotes (fabrication/overflow); offsets (weak models can't count); date as key (ambiguous) |
| Three contracts: attempt / hit / value (R#1) | Failures, no-hit, conflicts, lineage become representable; build hits + value + a minimal attempt record first | One overloaded long table with nullable junk |
| Observed-task specs vs plain-R derivation (R#1, tightened R#2) | Don't run extraction on a subtraction; derived = plain R with **no spec/registry entry at all** (not "two spec shapes" — only observed tasks get a spec) | One spec shape; a `rule:` interpreter (reinvents R); even a doc-only registry entry (a second spec system) |
| Named construction-policy registry, not "5 reducers" (R#1) | D0840 needs reconcile / rank_select / count-distinct; closed tested set, not a DSL | Fixed 5-reducer list (too small); `aggregate(fn)` hiding arbitrary code |
| Fail closed, never auto-repair (R#1) | Repair can invent the audited field; missing is visible, synthesized is not | Auto-repairing partial clinical objects |
| Candidate recall measured separately (R#1) | An accurate model score can hide systematic retrieval false-negatives | Extraction accuracy as the only metric |
| Reject any model that fails the grammar-enforcement gate (Phase 0) | Valid JSON behind a prompt ≠ enforcement; verify with a bare-call gate. Tested thinking models failed — but the rule is the *gate*, not the category | Banning a model *category*; trusting any model that "returns JSON" |
| R scopes/orders; model selects `evidence_id` + classifies in one bundled call; granularity is empirical (Handoff #3) | R does temporal scoping/ordering; the model selects among in-scope snippets (the latest isn't always right — copy-forward, contradiction). Preselection is a policy option | R pre-picks one snippet (too rigid); LLM does the temporal reasoning |
| Verify provider params take effect; model choice is config, not architecture (Phase 0) | Abstraction layers silently drop params by endpoint (ellmer/Ollama `/v1` dropped `temperature` + `num_ctx`) | Trusting a lever unverified; baking a model name into the architecture |

---

## 7. Open questions

Resolved by Review #1: hit schema (→ three contracts), engine (→ ellmer),
anchor/window expression (→ bounded resolver registry). Resolved by Handoff #3:
evidence shape (→ `evidence_id` reference); array-valued evidence (→ array of snippet
ids with `maxItems`); who applies the temporal rule (→ deterministic R, not the LLM).
Remaining:

- **Where specs live:** R list (code) vs external YAML/CSV (clinician-editable).
  Specs are JSON-Schema-shaped *data* either way; D0740's most-refined artifacts
  were CSV tables — leans toward data; decide when a real catalogue is built.
- **Eval gold mapping:** in the spec vs a separate eval config (lean: separate).
- **Snippet construction:** re-derive snippets from source docs (corpustools KWIC, one
  per match with doc-id + date) vs split an existing concatenated blob — the real
  Layer-1 input wants the former; a blob-split is only a quick prototype.
- **Bundling:** document-level vs bundled calls is an empirical comparison, not an
  axiom (the granularity itself is decided: one extraction task per subject/timepoint).
- **Name.**

---

## 8. Phased build plan

- **Phase 0 — spike (do this first), two steps** (revised per Review #1).
  **Status (2026-06-20): step 1 built and run** (`scripts/phase0_smoke_test.R`).
  Validated the spec-as-data path (`type_from_schema()`), schema enforcement,
  deterministic runs, a minimal attempt log, and fail-closed failure capture.
  Outstanding: restructure the input into a **numbered, dated snippet list** and switch
  evidence to the bundled `status + evidence_id` call; add **synthetic fixtures** for the
  `not_stated`/negation path. Model choice, exact numbers, and incident history live in
  `HANDOFF.md` (configuration, not architecture).
  1. **Contract smoke test** — the harness above, plus 12–20 *synthetic* French
     fixtures (current / former / never / not-stated / negation / contradiction /
     truncated) for the negative-control cases the real pool lacks. Verify the path,
     schema enforcement, missingness, evidence grounding (`selected id == expected id`),
     failure capture. *No gold needed — validates the mechanism.*
  2. **Accuracy set** — a *frozen, independently-adjudicated* stratified `tabac`
     set. The pool (`tabac_eval_pool_1000.rds`, copied to `Datasets/`) is **confirmed
     unlabelled** — 450 rows, no gold column — so the human adjudicates a frozen
     stratified subset of it, labelling `gold_smoking_status`. Score deterministically:
     value confusion / macro-F1, abstention, evidence grounding, attempt failures,
     latency, by model. Grammar-off is secondary.

  Select and test **the model** here, and validate the **ellmer path** end to end
  (ellmer is already ratified — raw Ollama is only an escape hatch, not a decision
  to relitigate). **"Eyeball" is not an acceptance criterion** — adjudicated columns and scoring rules are frozen and imported as
  data. The general engine must still run fully **gold-absent** (the usual case),
  producing review-ready output from which gold accrues.

  > Review #1 corrections: `PARTAGE` is 4,254 *synthetic structured-abstract*
  > cases (diagnosis/procedure/admission/LOS), **not** a smoking target; and no
  > `tabac_eval_pool` lives in D0840 — the labelled pool, if any, is in
  > `gptr/manual-eval/`.
- **Phase 1 — the contracts + primitives.** The hit/value contracts, the ~4 source
  adapters, the construction-policy registry — generalized out of D0740's blocks.
  Lift the `comorbidity_catalog` pattern to all blocks.
- **Phase 2 — anchor / scope / construction-policy as first-class spec fields.** The
  unified spec row + the engine loop (`resolve_anchors → retrieve → gather →
  collapse → pivot`), with derivation as plain R after.
- **Phase 3 (later, optional) — the review *system* + eval harness.** Prioritized
  review queue, source-conflict surfacing, persistent/reused gold, eval
  (relative/anchored). This is the *elaboration*, explicitly **not** a Phase 0–1
  concern. Build pieces only when a real pain demands them. (Derivation is **not**
  in this list — it's ordinary project R that runs after the engine, in every phase.)
- **Phase 4 — extract the package** (DESCRIPTION/roxygen/`R CMD check`/CI) once
  proven across ≥2 fields (`tabac` + `atcd_chir`).

> **Review v1 is trivial and available from day one, in any phase.** Export the
> long output table to xlsx with blank `verdict` / `corrected_value` columns,
> fill them in by eye (the evidence quote is inline, so it's faster than gptr's
> end-step), import back as gold. *That is the whole review MVP.* Everything in
> Phase 3 is optional sugar — never build it preemptively. Treat this whole
> document as a map of optional destinations, not a checklist.

The engine loop the blocks generalize to:

```
resolve_anchors(subjects, anchor_spec)                       # build_first/last_dmo_index, generalized
for each observed-task spec:
  for each (anchor, scope) in spec$timepoints:
    candidates = retrieve(pool, anchor, scope, query, top_n)  # build_X_doc_candidates
    hits       = gather(candidates, sources, schema, prompt)  # resolve_X_llm_docs (+ pmsi/biol hits)
    value      = collapse(hits, policy)                       # filter/select_X_before_index
  feature = pivot(values over timepoints)                     # build_X_timepoint_feature_table + joins

# derivation is NOT an engine stage — it is ordinary R after the loop:
features$poids_delta <- features$poids_t1 - features$poids_t0   # the *_delta / *_changed / composites
```

---

## 9. Lessons from the three projects (the evolution)

- **Tesi-francesca** (first, least refined): ad-hoc scripts, copied function
  files, per-variable scripts; LEDD-over-time. Showed the need but no structure.
- **D0840** (transplant): **one `_gpt` output file per variable, re-run
  independently** — resumability discovered. A `data_dictionary.csv` appears.
  Many variables (tabac, saignement, transfusion, anastomose, donneur_technique,
  nephropathie, …).
- **D0740 / dmo** (most refined): anchors computed once and reused everywhere;
  **7 near-identical feature blocks** (the template to generalize); multi-source
  comorbidity (`pmsi_diag` + `pmsi_acte` + `corpustools`, bound then filtered
  `<= index`); caching + `enabled`/`recompute` flags (hand-rolled resumable
  pipeline); **`comorbidity_catalog`** = the declarative proto; `spec_table.csv`
  + `construct_rules.csv` = **specs-as-data** + the `temporal_model x memory_rule`
  taxonomy; provider was OpenAI `gpt-5.4-nano` (not dogmatically local — the engine
  must stay provider-agnostic).
- The two-dimensional insight (**timepoints × behaviour**) refined into the four
  axes — now named **anchor × scope × construction-policy × sources** — and these
  describe *observed tasks* only; derived columns are plain R, outside the axes.

---

## Appendix: key mechanics (for catching up on first principles)

**Grammar-constrained decoding, end to end.** At each step a language model
outputs not a word but a *probability distribution over its whole vocabulary*. A
separate *sampling* step draws one token. Constrained decoding inserts itself in
that gap: a *grammar* (a state machine compiled from the JSON schema) knows, given
where you are in the structure, which tokens are legal next, and **zeroes out
every illegal token before sampling** (forbid, never boost), then renormalizes.
This guarantees the output conforms to the schema (valid JSON, right keys, allowed
enum) but **cannot** guarantee the value is *correct* — among the legal survivors,
the model's own (possibly wrong) preference still chooses. You give the server a
schema (the rulebook); the server is the bouncer; your client code never sees a
masked token.

**Two caveats this design leans on.** (1) The mask bounds *structure*, not *length* or
*truth*: an unbounded string field can still grow without limit (why evidence is a
bounded `evidence_id` reference, not free text — §5). (2) The bouncer only works if the
model's tokens actually pass through it. Some models (e.g. certain reasoning/"thinking"
models) emit a side stream that is *not* under the grammar and can leak as prose,
breaking the JSON — so grammar enforcement must be **vetted per model**
(`scripts/check_grammar_enforcement.R`): reject any model that escapes, whatever its
category (§5).
