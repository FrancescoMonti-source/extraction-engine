# extraction-engine — Design

> **Status:** design seed. No code yet.
> **Name:** `extraction-engine` is a **placeholder** — rename later.
> **Lineage:** focused successor to `gptr`. Captured from an extended design
> conversation on 2026-06-19. This doc carries the *rationale*, not just the
> conclusions — the "Decisions & rationale" section is the point.

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
- **behaviour**-based collapse of hits into analytical values
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

## 2. Architecture — four layers + the narrow waist

```
Layer 0  ANCHOR     per-subject index date(s) from a rule        (build_first/last_dmo_index, generalized)
Layer 1  EXTRACT    sources -> dated HITS                         (source adapters)
Layer 2  CONSTRUCT  windowed hits -> timepoint values             (behaviour / reducer)
Layer 3  DERIVE     constructed features -> computed columns       (deltas, changed, composites; no text)
```

**The narrow waist is the HIT:**

```
hit = (subject_id, date, value, source, evidence)
```

Sources fan **in** to hits (adapters). Behaviours fan **out** of hits (reducers).
Because they only meet at this one fixed contract, complexity is **N + M, never
N × M.** This is the single principle that bounds the whole design. (Proof it
already works: D0740's `bind_comorbidity_hits()` merges ICD + CCAM + text into one
hit table that everything downstream treats identically.)

---

## 3. The spec model — four dimensions, as data

A variable is defined by **four orthogonal dimensions**, all expressed as data:

1. **Anchor** — a per-subject index date from a rule. `t0/t1 = first/last DMO
   event` is just *one* instance. Generalize: first/last/nth of any event, a fixed
   date, or relative to another anchor. *Different use case = different anchors,
   same engine.*
2. **Window** — relative to an anchor: `<= anchor` (history), `+/- N days`
   (point-in-time), `(anchor_a, anchor_b]` (between), `[anchor - 5y, anchor]`
   (last 5y). (D0740 already has two shapes: `max_days_from_index` symmetric;
   `filter_*_before_index` directional.)
3. **Behaviour** — how to collapse windowed, multi-source hits into a value
   (the `memory_rule`).
4. **Sources** — where dated hits come from: ICD codes, CCAM acts, labs, text.

`anchor x window` = the "timepoint" dimension (where & how wide); `behaviour` =
how to collapse; `sources` = where from. **The spec is DATA**, not code: one row
defines a variable; the engine runs all four layers from it.

### Unified spec row (target shape)

```r
tabac = list(
  sources     = list(llm_text = list(query  = "taba* OR fum* OR cigar* OR clope* OR sevrage",
                                      schema = type_enum(c("never","former","current","not_stated")),
                                      instruction = "...")),
  timepoints  = list(t0 = anchor("first_dmo", window = "+/-30d"),
                     t1 = anchor("last_dmo",  window = "+/-30d")),
  behaviour   = "point_in_time_status",
  evidence    = TRUE,
  outputs     = c("tabac_t0", "tabac_t1", "tabac_changed")   # changed = derived (Layer 3)
)
```

A multi-source comorbidity carries one config slice per source as data:

```r
diabete = list(
  sources = list(
    pmsi_diag = list(icd10 = c("E10","E11")),
    pmsi_acte = list(ccam  = c("...")),
    llm_text  = list(query = "diab*", schema = type_enum(c("yes","no","not_stated")), instruction = "...")
  ),
  timepoints = list(t1 = anchor("last_dmo", window = "<= anchor")),
  behaviour  = "any_positive"
)
```

---

## 4. Bounded primitives

The fear was "how many behaviours / how much source-specific code." Both are
bounded by the narrow waist and are *additive*.

### ~5 reducers (behaviours), written once

| reducer | covers (clinical memory_rules) |
|---|---|
| `any` (positive hit exists in window) | accumulative_history, event_history, event_during_followup |
| `nearest` (value of hit closest to anchor) | point_in_time_status, current_state, repeated_measure |
| `first` / `last` | immutable, onset descriptors |
| `aggregate(fn)` (min/max/mean of numeric) | severity, cumulative counts |
| `collect` (all values -> list) | array-valued vars (e.g. surgical_history) |

A behaviour is a pure function `(hits, params) -> value + justifying hit`. The
"weird" clinical rules are **compositions in the spec, not new code**:
- `new_between_t0_t1` = `any` in `(t0,t1]` AND NOT `any` in `<= t0`
- `history_plus_activity` = two outputs: `any(<=anchor)` + `nearest(+/-Nd)`
- `derived` = not a reducer; it is Layer 3.

These five were **discovered empirically** across three projects — the set is
small and slowly-growing, not open-ended.

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
  truth.** Enforcement is server-side; the client just passes the schema.
  Consequence: JSON-repair is a *depreciating* asset (grammar handles syntax);
  eval/review is *appreciating* (only it catches valid-but-wrong).
- **Per-variable evidence.** Each value carries its own verbatim quote
  (`{value, evidence}`), because the text justifying `pack_years` differs from the
  text justifying `smoking_status`. Output is a **long** table:
  `(subject, date, variable, value, evidence, .valid, .failure)` — the canonical
  contract every stage reads/writes. Evidence is nullable.
- **Missing values.** `not_stated` (an enum sentinel) is a *generation-time
  device* giving a weak model a legal "I don't know" token so the grammar does not
  force a real category; it collapses to `NA` in the output. `required` (structural
  nullability) is the missing channel for *non-enum* types (numbers, free text)
  that cannot carry a sentinel. **Derive missing-handling from the type**, do not
  make it a per-variable field. They are not redundant; they are type-specific.
- **Retrieval is optional, sensitivity-first.** Lexical (corpustools), tuned for
  recall over precision (over-retrieve, let the model + `not_stated` filter).
  KWIC snippets with full-doc fallback; **dedup copy-forward** is essential.
  Per-variable retrieval is also *call*-reduction (only fire where the query hits).
  Recall is the silent killer; the query is a versioned artifact.
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
| Four-layer architecture + narrow-waist hit | Discovered from D0740's 7 near-identical feature blocks; makes sources & behaviours additive | Per-variable bespoke pipelines (the 7 copy-pasted blocks = accidental complexity) |
| Spec as data | Editable, versionable, reviewable, scales to ~50 variables | Bespoke code per variable |
| One call per variable | Weak models do better one-at-a-time; enables per-variable retrieval + resumability | Nested multi-variable single call (degrades on weak models) |
| Engine = ellmer **(OPEN: vs raw Ollama)** | Inherits providers + structured output + JSON→R, maintenance-free | Building our own provider layer = the complexity we are shedding |
| Build app first, extract library later | Don't guess abstractions; we have prior art + ≥2 fields | Premature packaging |
| Focused successor, not gptr rewrite | The JSON-repair/validation engine is hard-won | From-scratch rewrite loses it |
| Per-variable evidence (nested) | Clinical review needs the quote behind *each* value | One shared evidence / flat schema |

---

## 7. Open questions

- **Hit schema completeness:** is `(subject, date, value, source, evidence)`
  enough, or do real hits need `record_id`, `confidence`, `event_id`?
- **Engine:** ellmer (type objects → specs are *code*) vs raw Ollama (JSON-schema
  → specs are *data*; our spec is already JSON-schema-shaped). Decide at the spike.
- **Where specs live:** R list (code) vs external YAML/CSV (clinician-editable
  data). D0740's most-refined artifacts were CSV tables — leans toward data.
- **Eval gold mapping:** in the spec vs a separate eval config (lean: separate).
- **Array-valued variables:** evidence per item vs per list.
- **Anchor/window DSL:** how to express anchor rules and windows cleanly as data.
- **Name.**

---

## 8. Phased build plan

- **Phase 0 — spike (do this first).** One variable (`tabac`) end-to-end on the
  labelled `tabac_eval_pool` (D0840): extract with grammar → validate → score vs
  gold. **Skip** retrieval, anchoring, temporal. Goal: *is grammar-constrained
  mistral/gemma3 accurate enough?* Decide ellmer-vs-raw here. Measure grammar
  on vs off. If accuracy fails, nothing downstream matters. Note: this leans on
  D0840's `tabac_eval_pool` precisely because it is the *exception* that already
  has gold — a one-off luxury that lets us validate accuracy early. The general
  engine must still run fully **gold-absent** (the usual case), producing
  review-ready output from which gold accrues.
- **Phase 1 — the contract + primitives.** The hit schema, the ~4 source
  adapters, the ~5 reducers — generalized out of D0740's blocks. Lift the
  `comorbidity_catalog` pattern to all blocks.
- **Phase 2 — anchor/window/behaviour as first-class spec fields.** The unified
  spec row + the engine loop (`resolve_anchors → retrieve → gather → collapse →
  pivot → derive`).
- **Phase 3 (later, optional) — the review *system* + eval harness.** Prioritized
  review queue, source-conflict surfacing, persistent/reused gold, eval
  (relative/anchored), derive layer. This is the *elaboration*, explicitly **not**
  a Phase 0–1 concern. Build pieces only when a real pain demands them.
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
for each variable spec:
  for each (anchor, window) in spec$timepoints:
    candidates = retrieve(pool, anchor, window, query, top_n) # build_X_doc_candidates
    hits       = gather(candidates, sources, schema, prompt)  # resolve_X_llm_docs (+ pmsi/biol hits)
    value      = collapse(hits, behaviour)                    # filter/select_X_before_index
  feature = pivot(values over timepoints)                     # build_X_timepoint_feature_table + joins
derived = derive(features, rules)                             # the *_delta / *_changed / composites
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
- The two-dimensional insight (**timepoints x behaviour**) refined into the
  four dimensions: **anchor x window x behaviour x sources**.

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
