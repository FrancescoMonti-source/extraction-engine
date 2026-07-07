# Extraction Engine — Design Contract

## 1. Purpose and scope

This project is an HDW-aware, protocol-agnostic extraction framework for building study analytical variables from a stable hospital data warehouse structure.

It is a framework where researchers define study-specific analytical variables by selecting concepts, signal channels, output grains, anchors, windows, extraction methods, reducers, transformations, output types, and audit requirements. The engine executes those definitions against known HDW sources and returns auditable analytical variables.

Researchers remain responsible for scientific validity, protocol design, and operational definitions. The engine is responsible for explicit execution, mechanical consistency, reproducibility, and provenance.

The engine owns execution and traceability. The researcher owns interpretation.

At the LLM boundary, the engine does not promise that the model output is accurate. It promises that a deterministic pipeline selected candidates, called the model under a controlled schema, accepted only grounded/valid parts, routed failures and ungrounded claims to review, and preserved evidence, status, and provenance.

Out of scope: full protocol design, scientific justification, cohort governance, clinical trial management, physician workflow management, and global study lifecycle management. A higher research platform may later use this engine, but the engine itself only builds auditable analytical variables from stable HDW sources using explicit study-specific definitions.

Status: this document is the target design contract, and the migration it once tracked is complete: the transitional surfaces it used to tolerate (`binary_output()` / `number_output()`, public `decision` / `decision_state`, role-tagged audit rows) have been removed from the code. Capabilities that remain declared-but-unbuilt are deferred in §16, each gated on a concrete consumer. Keep chronological shipped-progress notes in `HANDOFF.md` (or commit messages), not by weakening this contract.

------------------------------------------------------------------------

## 2. Single-view execution model

The engine is easiest to understand as four layers.

``` text
SOURCE LAYER
  raw HDW tables
    -> interpreted by source_spec
    -> exposed as canonical roles

CONCEPT LAYER
  concept_spec
    -> declares named channel defaults for a concept

VARIABLE LAYER
  variable_spec
    -> activates selected concept channels
    -> inherits or replaces channel defaults locally
    -> defines grain, anchor, window, output, combine, and audit behavior

RUNTIME LAYER
  run_variable(variable_spec, runtime)
    -> binds sources, loads data, executes channels, combines results,
       and returns values + audit/provenance
```

Core inheritance rule:

``` text
concept_spec supplies named channel defaults.
variable_spec activates selected channels.
a bare string activates a concept channel as-is; use_channel() is only for overrides.
any field supplied in use_channel() replaces the inherited field for that variable only.
unlisted concept channels are not used.
```

There is no selector-refinement semantics for now. A supplied selector replaces the inherited selector locally; it does not mutate the concept.

The general rule is:

> Channels observe, combiners calculate, researchers interpret.

### The pipeline reading (ratified 2026-07-04)

A `variable_spec` is a declarative recipe for a small, reproducible data-science pipeline. The reference mental model is ordinary dplyr:

``` r
lab_results %>%
  filter(EVTID %in% filtered_docs$EVTID, hb < threshold) %>%   # channels + combine
  group_by(EVTID) %>%                                          # output_one_row_per
  summarise(mean_hb = mean(hb))                                # output payload
```

Mapped onto the spec axes:

``` text
channel            = a FILTERED ROW SET of one source (selector + predicates + window).
                     Its rows ARE its hits (spine keys = membership) and CARRY its
                     values (payload columns). One row set, not two faces.
combine_channels   = set algebra on identity-spine keys at a stated level
                     (& = semi-join, ! = anti-join, | = union)
                     -> the SURVIVING row set.
output             = consumes the surviving rows:
                     bin_output()  membership per output-grain group (any row -> 1)
                     num_output()  group_by(output_one_row_per) + summarise(reduce)
                                   over the payload channel's surviving rows.
```

What the spec buys over writing that dplyr by hand: reproducibility, anchors and windows, observed-coverage semantics, provenance, and review routing around the same relational verbs.

------------------------------------------------------------------------

## 3. Design objects and responsibilities

| Object | Responsibility |
|------------------------------------|------------------------------------|
| `source_spec` | Maps one raw HDW source to canonical roles. |
| `concept_spec` | Declares possible signal channels for a clinical/research concept. |
| `channel` | One source-specific route that resurfaces candidate signals without clinical interpretation. |
| `variable_spec` | Concrete executable definition of one protocol-specific analytical variable. |
| `variable_template` | Reusable concept-specific analytical pattern for a recurring variable family. |
| `operators/helpers` | Generic computational primitives used inside specs/templates. |
| `runtime` | Supplies actual data, model/provider settings, execution parameters, and environment. |

Core distinction:

``` text
concept_spec defines possible signal channels.
variable_spec defines the analytical variable requested by the protocol.
```

Or:

``` text
concept_spec answers:  "Where can signals related to this concept be found?"
variable_spec answers: "How should those signals be transformed into this protocol's analytical variable?"
```

------------------------------------------------------------------------

## 4. Source layer: `source_spec`

A `source_spec` maps a raw or prepared HDW source to canonical engine roles.

The package provides default source specifications for the known REDSaN/HDW structure. The source registry is hand-declared (`EE_SOURCES`): each entry defines its module/table, identifier columns, point-versus-interval time semantics, query date keys, batch keys, and payload roles. `redsan` normalizes the raw warehouse into these shapes (e.g. `process_pmsi()`, `process_biol()`) but does not itself expose a source-registry API, so the specs are declared here, not derived. Users may override default mappings when their dataset uses different column names or when they provide custom prepared views.

A source specification should use canonical role names. Raw column names remain source-specific; role names should not.

Common roles (not exhaustive):

``` text
subject_id
event_id
source_item_id
source_row_id
point_date
event_start
event_end
code
analyte
value_num
value_str
unit
text
document_type
subject_sex
subject_age
```

Time roles describe temporal *structure*, not clinical meaning. A point-dated record (a CCAM act, a lab exam, a record entry) occupies a single instant and carries `point_date`; an interval entity (a stay/encounter — the "event", keyed by `event_id`) has two distinguishable endpoints and carries `event_start`/`event_end`. A source is one shape or the other (`source_time_kind`). The role names the structural slot, so the concept-specific column (`DATEACTE`, `DATEXAM`) is mapped to a generic role in the source layer and never leaks into a `variable_spec`.

`source_spec` also carries source metadata that is not a payload role:

``` text
module
table
identifiers
kind                <- channel kind this source serves: code / act / lab / text
source_time_kind
source_time_start
source_time_end
query_date_keys
default_batch_key
normalizer
```

`kind` (ratified 2026-07-04) declares which channel type a source serves (`pmsi_diag` → code, `pmsi_actes` → act, `biology` → lab, `documents` → text). It exists so typed channel constructors can resolve an omitted `source =` against the registry — see §5.

Every HDW source row carries the same canonical provenance spine:

``` text
subject_id     = PATID
event_id       = EVTID
source_item_id = source-specific item/document/row identifier
```

`PATID` and `EVTID` are invariant across HDW tables. The third role is also part of the spine, but its raw column differs by source and must be mapped through `source_spec`:

``` text
doceds documents       -> ELTID
PMSI main/actes/diag   -> ELTID
biology results        -> ELTID, plus BIOL_ID as result-level traceability
```

The older mental shortcut "document id" should be read as this generic `source_item_id` role, not as a text-only concept. Biology's `BIOL_ID`, repeated diagnoses, repeated acts, or split text passages may still require auxiliary row coordinates when needed for uniqueness, debugging, or source-specific audit, but the canonical HDW linkage/provenance triplet is always present.

For deterministic structured sources, `source_item_id` is mainly useful for optional debugging/audit. The trust in the result comes from the resolved deterministic rule and reproducible execution, not from LLM-style evidence citation.

For LLM text extraction, candidate `evidence_id`s are generated only for the snippets shown to the model. These citation IDs map back to the source item, usually a document `ELTID`.

Identifier spine: for default REDSaN/HDW sources, patient-level and stay/event-level linkage can rely on `PATID`, `EVTID`, and the mapped `source_item_id` being present; no defensive missing-id semantics are needed for those sources. A custom non-HDW source may still need an explicit `source_spec` caveat if it cannot satisfy the same role contract. These identifiers are not the same thing as LLM `evidence_id`s.

The spine is not linkage bookkeeping; it is the **combination substrate** (ratified 2026-07-04). Rows from different tables never coexist on one row — text hits, coded rows, and lab results meet *only* through the containment hierarchy `PATID ⊃ EVTID ⊃ source_item_id`. Rolling a hit up to any coarser grain is free because every row carries all three keys, and `combine_channels` at any level (§10) is pure set algebra on those keys. Consequences: preserve the triplet end-to-end in prepared views — dropping `EVTID` or `source_item_id` in an intermediate step silently amputates combine levels; and a source that cannot supply the triplet cannot participate in level algebra at all.

Example default source specifications:

``` r
pmsi_diag_source <- source_spec(
  name = "pmsi_diag",
  roles = list(
    subject_id     = "PATID",
    event_id       = "EVTID",
    source_item_id = "ELTID",
    code           = "code",
    event_start    = "DATENT",
    event_end      = "DATSORT",
    subject_sex    = "PATSEX",
    subject_age    = "PATAGE"
  )
)

ccam_act_source <- source_spec(
  name = "ccam_acts",
  roles = list(
    subject_id     = "PATID",
    event_id       = "EVTID",
    source_item_id = "ELTID",
    code           = "CODEACTE",
    point_date     = "DATEACTE",
    event_start    = "DATENT",
    event_end      = "DATSORT",
    subject_sex    = "PATSEX",
    subject_age    = "PATAGE"
  )
)

biology_source <- source_spec(
  name = "biology",
  roles = list(
    subject_id     = "PATID",
    event_id       = "EVTID",
    source_item_id = "ELTID",
    source_result_id = "BIOL_ID",
    analyte        = "TYPEANA",
    value_num      = "NUMRES",
    value_str      = "STRRES",
    unit           = "UNIT",
    point_date     = "DATEXAM",
    subject_sex    = "PATSEX",
    subject_age    = "PATAGE"
  )
)

documents_source <- source_spec(
  name = "documents",
  roles = list(
    subject_id     = "PATID",
    event_id       = "EVTID",
    source_item_id = "ELTID",
    text           = "RECTXT",
    document_type  = "RECTYPE",
    point_date     = "RECDATE",
    subject_sex    = "PATSEX",
    subject_age    = "PATAGE"
  )
)
```

Some roles may come from joined metadata tables rather than the source’s main long table. For example, PMSI diagnosis and CCAM act sources may need `event_start`, `event_end`, `subject_sex`, or `subject_age` from `pmsi$main`.

The engine can handle this in either of two equivalent ways:

``` text
1. the REDSaN adapter builds prepared source views before execution;
2. the user supplies already-prepared tables and maps their columns through source_spec().
```

The design contract is that by the time a channel runs, the source exposes the canonical roles required by that channel.

Study-facing code should not need raw HDW column names. Selectors target canonical roles; source specs bind those roles to actual columns.

------------------------------------------------------------------------

## 5. Concept layer: `concept_spec` and channels

A `concept_spec` is a reusable concept-level signal catalog. It is not a final diagnosis, phenotype, or analytical variable.

A concept channel declares a reusable source route and its defaults. Typical channel types are:

| Channel type | Implied intermediate signal | Typical source | Typical downstream use |
|------------------|------------------|------------------|------------------|
| `code_channel()` | coded row / code hit | PMSI diagnoses | membership hit, optional matched code rows |
| `act_channel()` | act row / act hit | CCAM acts | membership hit, optional matched act rows |
| `lab_channel()` | measurement | biology | membership hit, numeric/string value, reducers |
| `text_channel()` | text candidate | documents | Lucene hit, regex extraction, LLM extraction |
| `doc_channel()` | document existence | documents (docs index) | membership hit, document date (`date_output`) |

The channel constructor implies the emitted signal shape. Users do not normally declare `emits` or `produces`.

`doc_channel()` (landed 2026-07-07) is the simplest channel kind: the document's **existence** is the hit, selected on docs-index **metadata** via `doc_meta(RECTYPE = "CR-ANES", SEJUM = "ANES")` — exact any-of filters per column, conjoined across columns, no content read, no Lucene, no LLM. Its hit rows are docs-index rows, so they carry the identity spine and their own clock (RECDATE) like any structured row set. Consumer: date of the pre-op anesthesia consult (a document of a given type attributed to unité médicale ANES; `SEJUM` is the unité-médicale column, owner-named 2026-07-07 and declared in `DOCS_SOURCE` — role-less, since the engine never interprets it).

Typed constructors stay because their signatures are the honest home for type-specific parameters (a text channel's extraction definition, a lab channel's value predicate); most nonsense combinations are unwritable at authoring time. They are definers: they may appear in a `concept_spec` or inline in a variable's channel list (§6), and wherever they appear they bind location. Activations never do.

**`source` is optional on typed constructors (ratified 2026-07-04): resolution is unique-or-error, never a default.** Each registered source declares the channel `kind` it serves (§4). `lab_channel(selector = ...)` with `source` omitted resolves to the sole registered lab-kind source; the day a second lab-kind source registers (e.g. microbiology), omission becomes a build-time error naming the candidates — every affected spec is forced loud rather than silently reinterpreted. This is the same philosophy as `index_event()` match resolution (§7). Explicit `source =` stays writable throughout, and is required for sources outside the registry. The generic `channel(source =, type =)` remains the escape hatch for custom sources.

Example:

``` r
diabetes <- concept_spec(
  name = "diabetes",

  channels = list(
    pmsi_diag_e10_e14 = code_channel(        # source resolves -> "pmsi_diag"
      selector = icd10("^E1[0-4]")
    ),

    text_diabetes_mentions = text_channel(   # source resolves -> "documents"
      selector = lucene_query("diabete OR diabetique OR insulinotherapie OR insuline"),

      default_method = llm_after_lucene(
        candidates = \(d) head(
          dplyr::arrange(d, dplyr::desc(n_query_hits), dplyr::desc(document_date)),
          20
        ),

        prompt = "
          Determine whether the candidate text documents that the patient
          has diabetes.

          Count as documented:
          - known diabetes
          - type 1 diabetes
          - type 2 diabetes
          - insulin-treated diabetes
          - antidiabetic treatment clearly indicating diabetes

          Do not count as documented:
          - family history only
          - diabetes explicitly ruled out
          - simple hyperglycaemia without documented diabetes
          - hypothetical, screening, or differential diagnosis mentions
        ",

        type = ellmer::type_object(
          response = ellmer::type_enum(
            values = c("documented", "not_documented", "uncertain"),
            description = "
              documented: the text documents diabetes.
              not_documented: the text does not document diabetes.
              uncertain: the text is ambiguous or insufficient.
            "
          )
        ),

        positive_hit_when = "documented",
        require_evidence = TRUE,
        require_rationale = TRUE
      )
    ),

    glucose_measurements = lab_channel(      # source resolves -> "biology"
      selector = analyte("GLU.GLU")
    ),

    hba1c_measurements = lab_channel(
      selector = analyte("HBA1C")
    ),

    antidiabetic_prescriptions = code_channel(
      source = "prescriptions",              # outside the default registry: explicit
      selector = drug_class("antidiabetic")
    )
  )
)
```

This object says diabetes-related information may appear through these channels. It does not say whether a patient has diabetes.

Concept channels may define declared defaults, including selectors, candidate-selection rules, processing methods, prompts, ellmer structured-output types, and response-to-hit mappings. Defaults are acceptable because they make recurring analytical patterns reusable. They are not hidden assumptions: they must be inspectable, locally replaceable, and preserved in provenance.

### Selectors

Selector constructors such as `icd10()`, `ccam()`, `analyte()`, and `lucene_query()` are not meant to know raw table names or raw column names.

``` text
source = "pmsi_diag"
  tells the engine which source_spec / data source to use.

source_spec("pmsi_diag")
  tells the engine which raw column corresponds to that canonical role.

selector = icd10("^E1[0-4]")
  tells the engine which kind of selector is requested and which canonical role it targets.
```

This keeps the abstraction stable:

``` text
source_spec maps raw columns.
selector targets canonical roles.
channel combines source + selector.
variable activates channel.
runtime executes.
```

A selector object may be simple internally; its value is that it can be inspected, validated, serialized, audited, and applied to the appropriate source through canonical roles.

## 6. Variable layer: `variable_spec`, activation, and replacement

A `variable_spec` is the final executable analytical definition for one protocol-specific variable.

It answers:

> In this study, at this output grain, using these channels, in this time window or event scope, with these extraction/reduction/transformation/combination rules, produce this output variable.

It declares:

``` text
name
concept
output_one_row_per
anchor
time window or event scope
selected channels
per-channel activation options
retrieval/extraction method
transforms
combine_channels expression + combine_at_level
output type (including the payload pick for value outputs)
absence/audit policy
audit requirements
```

Only channels listed in `channels` are activated. If a concept has three possible channels and the variable activates only two, the third is ignored.

The channels list admits three entry forms (ratified 2026-07-04; landed 2026-07-05):

``` text
"channel_name"                          plain activation: inherit everything
channel_name = use_channel(...)         activation with local replacements
channel_name = lab_channel(...) etc.    INLINE DEFINITION of a variable-local channel
```

A bare string activates the concept channel as-is — empty `use_channel()` calls are noise and not required. An inline typed definer declares a channel that exists only for this variable (promote it into the concept the day a second variable wants it); its name must not collide with a concept channel name — §14.3-style override through `use_channel()` is the only deviation path for inherited channels, and full redefinition-by-shadowing is rejected.

``` r
diabete_pre_anchor <- variable_spec(
  name = "diabete_pre_anchor",
  concept = diabetes,

  output_one_row_per = "PATID",
  anchor = "inclusion_date",
  window = c(-365, 0),

  channels = c("pmsi_diag_e10_e14", "text_diabetes_mentions"),
  # lab channel not invoked

  output = bin_output(),
  combine_channels = "pmsi_diag_e10_e14 | text_diabetes_mentions"
)
```

A `use_channel()` activation inherits the concept channel defaults unless it supplies a replacement.

``` r
pmsi_diag_e10_e14 = use_channel()
```

means:

``` text
inherit the concept-defined source
inherit the concept-defined selector
inherit the concept-defined method, if any
inherit the concept-defined candidate-selection rule, if any
inherit the concept-defined prompt/type/hit-mapping defaults, if any
```

A local replacement affects only that variable:

``` r
diabete_type2_pre_anchor <- variable_spec(
  name = "diabete_type2_pre_anchor",
  concept = diabetes,

  output_one_row_per = "PATID",
  anchor = "inclusion_date",
  window = c(-365, 0),

  channels = list(
    text_diabetes_mentions = use_channel(
      selector = lucene_query("diabete type 2 OR DNID OR insuline"),

      method = llm_after_lucene(
        candidates = \(d) head(dplyr::arrange(d, dplyr::desc(document_date)), 50),

        prompt = "
          Determine whether the candidate text documents type 2 diabetes.
          Do not count type 1 diabetes, gestational diabetes, family history,
          isolated hyperglycaemia, or screening mentions.
        ",

        type = ellmer::type_object(
          response = ellmer::type_enum(
            values = c("type2_documented", "not_documented", "uncertain"),
            description = "
              type2_documented: the text documents diabetes type 2.
              not_documented: the text does not document diabetes type 2.
              uncertain: the text is ambiguous or contradictory.
            "
          )
        ),

        positive_hit_when = "type2_documented",
        require_evidence = TRUE,
        require_rationale = TRUE
      )
    )
  ),

  output = bin_output()
)
```

This does not mutate the `diabetes` concept. It only changes the activated text channel for this variable.

The minimal activation grammar is:

``` r
use_channel(
  selector = NULL,   # optional local replacement
  method = NULL,     # optional execution/extraction method
  transform = NULL   # optional value transformation
)
```

Two parameters are deliberately absent (ratified 2026-07-04):

- **`source` — never.** An activation is a reference plus deltas; letting it re-declare where a channel lives would give the same channel two competing definitions that drift, and would dissolve the concept layer's define-once reuse. Location belongs to definers only (typed constructors, wherever they appear).
- **`reducer` — moved to the output.** The reducer is the variable's question ("mean Hb"), not a channel property; it lives on `num_output(values_from =, reduce =)` (§8), which also names the payload channel explicitly.

Method-specific parameters live inside the method. For example, prompt, structured-output type, candidate-selection rule, and response-to-hit mapping belong inside `llm_after_lucene()`, not as global `use_channel()` parameters.

## 7. Grain, anchors, windows, and linkage

`output_one_row_per` — the unit of analysis — defines the task universe and output grain: what one output row represents.

Examples:

``` text
patient
stay
surgery
transplant
consultation
pregnancy
donor-recipient pair
timepoint
```

The grain axis is first-class because many errors come from measuring the right signal at the wrong grain.

For example, `output_one_row_per = "PATID"` means one output row per patient in the supplied task universe. It does not imply access to the patient's complete real-world history. It means “across all patient-level data supplied to this run,” further restricted by anchor/window.

``` text
output_one_row_per = PATID
window = c(-365, 0)

meaning:
  one row per patient in the supplied task universe
  consider only evidence present in the supplied data
  restrict evidence to the 365 days before the anchor
```

Channels expose linkage affordances; the `variable_spec` decides which grain, anchor, and window to use. The engine checks whether selected channels can be mechanically linked to the requested grain/window.

### The cohort: where the row universe comes from (settled 2026-07-05)

The engine runs **downstream of a human-validated cohort** (the 99% operational path): candidates are screened and reviewed one by one *before* the engine, and that validated list is the row universe every variable answers about. It is laid down **with the data** — `sources$cohort`, a frame (grain-key columns, optionally `anchor_date` and future subject attributes like `sexe`) or simply a bare vector of PATIDs — and `run_variable(spec, sources = ...)` derives the universe from it. An explicit `cohort =` argument narrows past it (e.g. an inclusion variable's 1-rows). The validation loop itself (screening, one-by-one review) is cohort *governance* — the layer above, out of engine scope.

Each output row is keyed by **`grain_id`** — the identity of one grain unit (patient `C1`, stay `C1::V1`, index event `P1::X2`), derived from the grain keys when the cohort does not supply it (owner-named 2026-07-05). Every published view — `values`, `evidence`, `membership`, `channel_status`, `combine_keys` — keys its rows by `grain_id`, so they join and filter on one column. The engine's *internals* keep `task_id` (there it names extraction tasks, its original text-pipeline meaning); public inputs that key rows (the cohort, pre-retrieved text fixtures) may speak either, normalized on intake. The orchestrator running every variable of a study over the one declared cohort is `run_protocol()`.

The universe is **declared, never inferred from data rows**. The settling case: a validated patient with no rows in any loaded source must appear in the output as `NA` with partial coverage — *"he shouldn't vanish, he should just have NA everywhere."* A data-derived denominator loses him silently, makes `!A` complements and ascertained-negative-vs-silence meaningless, and turns per-frame pre-filtering into a permanent correctness invariant (with a declared cohort, pre-filtering the frames is unnecessary: scoped joins never touch non-members' rows). `cohort_from_sources(sources)` exists as the **explicit** union-of-frames escape for exploration — a visible one-liner, never a silent default.

``` text
lab channel:
  native grain = lab result
  linkable by subject_id
  has measurement date
  may have event_id

code channel:
  native grain = coded diagnosis row
  linkable by subject_id and stay_id/event_id
  has code date or stay interval

act channel:
  native grain = act row
  linkable by subject_id and stay_id/event_id
  has act date

text channel:
  native grain = document / passage / assertion
  linkable by subject_id, event_id, source_item_id
  has document date
```

Some variables are event-scoped rather than date-windowed. For example, operative-report anastomoses may be linked by subject + surgical event and declare `window = NULL`. The runner should not force a misleading placeholder date window onto event-scoped variables.

### Windows are plain day offsets (ratified 2026-07-04)

A dated window is two numbers relative to the anchor, in days, negative = before:

``` r
window = c(-365, 0)     # the year before the anchor
window = c(0, 180)      # six months after
window = c(-3650, 7)    # ten-year lookback plus a grace week
window = c(-Inf, 0)     # all recorded history before the anchor
```

There is no window constructor: `days_after()` / `before_anchor()` wrapped exactly two integers and are retired (the wrapper razor, invariant 33). `-Inf`/`Inf` are legal bounds, which is what makes "antécédent = whole recorded history" expressible. Event-scoped variables keep `window = NULL`.

Two epistemology flags researchers must set knowingly (they are rules, not defects):

- Each channel windows on **its own time role**: text on document date, acts on act date, coded stays on the stay interval. "Mentioned in-window" is not "happened in-window" — a post-anchor letter describing a pre-anchor surgery falls outside a lookback window.
- `c(0, n)` from an act-derived anchor puts the **index stay itself in-window**; start at 1, or gate it out, if the index stay must not score.

### Derived anchors: `index_event()` (shipped 2026-07-02; `select_event` ratified 2026-07-04)

An anchor is either a task column (`anchor = "T0"`, one date supplied per task row) or derived from the data:

``` r
anchor = index_event("pmsi_actes", ccam(SPINAL_SURGERY_ACTS), at = "DATEACTE")
```

Per subject, find the rows in `source` matching `selector`, and anchor at the `at` date **column** — the source's own spelling (`"DATEACTE"`, `"DATENT"`, `"DATSORT"`); omitted, it defaults to the source's windowing clock. (Owner ruling 2026-07-07: `at` is not interpreted by the engine, so role vocabulary there was pure indirection — raw column names are self-documenting, and the registry's roles stay internal where the engine does interpret them, e.g. windowing. Portability of specs across HDWs is not a goal: redsan already absorbs HDW changes.) Resolution is a **pass** that runs before windowing and injects per-subject anchor dates into the task frame; it is not an inter-channel dependency graph.

Match-multiplicity control is a plain closure over the matched rows (the wrapper razor — no `candidate_selection()`-style wrapper); the closure sees the date under the same column name:

``` r
select_event = \(d) dplyr::slice_min(d, DATEACTE, n = 1)   # earliest
select_event = \(d) dplyr::slice_max(d, DATEACTE, n = 1)   # latest
select_event = \(d) dplyr::arrange(d, DATEACTE)[2, ]       # exactly the 2nd
select_event = identity                                    # all events
# omitted -> single match or build-time ERROR (fail-closed default)
```

**Accepting a multi-row selection is accepting more than one output row per patient** (ratified 2026-07-04, one entailed decision): the anchor pass emits one task per selected event, each with its own anchor date and the index event's spine identity in provenance, and `output_one_row_per` must then name the event-grain key. The existing output-grain guard enforces the match — `select_event = identity` with `output_one_row_per = "PATID"` fails loudly. Flag for researchers: consecutive events with overlapping forward windows can score the same downstream stay more than once; correct per-event semantics, double-counting if naively summed.

A subject with **no** matching event is an error, not an NA: derive the task list from an upstream inclusion variable (a bin variable over the same selector — cohort inclusion is engine scope), so anchor resolution only ever runs on subjects that have the event.

### Grain is `output_one_row_per`; combine evaluates at `combine_at_level`

The variable's `output_one_row_per` picks the task universe. That is what makes the same expression mean different things at different grains:

``` text
combine_channels = "text_diabet & glucose"
```

At patient grain, this means:

``` text
patients with a diabetes text hit and a glucose result within the supplied patient-level task universe/window
```

At stay grain, it means:

``` text
stays with a diabetes text hit and a glucose result during the same stay-level task universe/window
```

The evaluation grain of the expression is `combine_at_level`, which **defaults to `output_one_row_per`** — the two readings above are the default case, and every pre-2026-07-04 spec keeps its meaning. Declaring it decouples the two grains (ratified 2026-07-04):

``` text
combine_at_level   = "EVTID"    the expression is evaluated per stay
output_one_row_per = "PATID"    one row per patient
```

means: qualify stays where the expression holds, then **exists-lift** to the output grain — the patient scores 1 if at least one of their stays qualifies. This is the difference between same-stay co-occurrence and the weaker cross-encounter conjunction (a text hit in stay 1 plus a lab hit in stay 3 satisfies patient-level `&`, but no stay-level `&`). See §10 for the row-set semantics and §14.8 for the worked example.

Wired 2026-07-05. Three execution facts follow from the observed-set posture (§10): the key universe at a sub-output level is the **union of keys observed by the referenced channels** — the engine has no roster of unobserved stays, so `!A` is complement within the observed keys, and an expression satisfiable only on an unobserved key scores 0. A channel's keys are read off its **hit evidence rows** (a structured hit's matched rows, a text hit's cited documents via `docs_index`) — level placement is never re-derived, and a hit whose evidence cannot be placed at the level fails closed (loud error, not a silent drop). The task-level membership/overlap audit is unchanged; the per-key verdicts are the run's `combine_keys` view (one row per observed task × key pair with per-channel key hits and the expression verdict). A payload output behind a sub-level gate is scoped to the qualifying keys (§8, §14.9), so `values_from` rows from non-qualifying stays never reach `reduce`.

Event/stay-grain eligibility is resolved by grain-aware scoping (`grain_keys`): the text path resolves event-scoped eligibility for event-linked document variables, and the structured code/act and lab executors scope each task to its own stay when `output_one_row_per = "EVTID"`. The extension was additive, as expected, because `EVTID` is invariant across HDW rows — it was executor wiring, not missing identifiers.

**Scoping rule** (settled with `select_event`, 2026-07-05): a declared **window is the scope** — rows gather per subject inside each task's anchored window, and a per-event task's `EVTID` is the task's *identity*, never a row filter (a forward complication lives in a *later* stay than its index surgery). With **no window, the grain unit is the scope** (the windowless stay-grain "during this stay" consumers). Every pre-existing consumer already sat on one side of this line — windowed variables were all subject-scoped, grain-unit variables all windowless — so the rule changed nothing shipped.

------------------------------------------------------------------------

## 8. Channel hits, outputs, and lab semantics

A channel activation is the variable-specific use of a concept channel. It may replace inherited fields, choose an extraction method, or define audit requirements.

A channel's `hit` means:

> its selector or extraction definition matched at least one in-scope signal for the current task.

This meaning is uniform across code, act, text, lab, medication, and other structured sources.

Per task, a channel hit is:

``` text
TRUE   = observed hit; the selected definition matched at least one in-scope signal
FALSE  = evaluated and no hit; the source was evaluable but no signal matched
NA     = unavailable / unevaluable; the source or channel could not be evaluated
```

`FALSE` and `NA` remain distinct in audit. `FALSE` is an observed non-hit; `NA` is unevaluability or non-decisive extraction.

### Lab channels

An unthresholded lab channel hits for every task that has at least one in-scope measurement.

``` text
glucose_measurements without threshold = "has at least one glucose measurement"
```

It does not mean abnormal glucose, diabetes, or hyperglycaemia.

A threshold is currently represented by replacing the selector with a thresholded selector:

``` r
glucose_measurements = use_channel(
  selector = analyte_value("GLU.GLU", gt = 11, unit = "mmol/L")
)
```

This means:

``` text
has at least one in-scope glucose measurement above 11 mmol/L
```

A lab channel is **one filtered row set, consumed two ways** (refined 2026-07-04; supersedes the older "two faces" wording): its rows are simultaneously the membership hits (spine keys, usable in `bin_output()` and `combine_channels` expressions) and the value carriers (payload columns, usable by `num_output(values_from =, reduce =)` / `cat_output(levels, values_from =, reduce =)`). Which values enter a reduction is therefore controlled by how the channel is *defined* — an unthresholded channel carries every in-scope measurement, a predicate-filtered channel carries only the rows meeting its rule — not by a separate value face. `analyte_value` takes `gt` and/or `lt` (strict bounds; at least one).

**Aggregate membership predicates** (the SQL `HAVING` shape; owner-requested 2026-07-05, landed the same day): a channel filter usually tests each row alone, but some protocols decide membership by a **group aggregate** — "anaemic stay = the stay's *mean* Hb < 10". This is still a grouped row *filter*, never an output reduction: qualifying groups keep their ORIGINAL source rows (hits, evidence, provenance all point at real rows; no synthetic aggregate rows), and everything downstream — level algebra, exists-lift, payload — consumes them unchanged. It lives on the channel definition as two plain params (no wrapper):

``` r
hb_anemic_stay = lab_channel(
  source   = "biology",
  selector = analyte("HGB"),
  group_at_level  = "EVTID",                  # the spine key whose groups are tested
  keep_group_when = \(v) mean(v) < 10         # plain closure: group values -> one TRUE/FALSE
)
```

The closure sees the group's target values *within the task's scope* (window rows only — a stay straddling the window edge is aggregated over its in-window rows: researcher-rule flag, not a defect). A closure breaking its contract (not exactly one `TRUE`/`FALSE`) is a hard error, same rule as a payload `reduce`. A task with measurements but no qualifying group is an ascertained negative (`hit = FALSE`, complete coverage), distinct from having no measurements at all. Reduction-as-*value* stays output-only; this is the one shape where a reduction participates in *membership*. Wired for every **structured** channel (owner ruling 2026-07-05: "it will be needed 100%"): lab groups over measurements, code/act over the group's **codes** — so frequency criteria are plain `length()` rules ("≥2 acts in one stay" = `keep_group_when = \(codes) length(codes) >= 2`). A **text** channel with a group predicate is rejected loudly: a text hit is an LLM answer grounded on cited rows, so a group rule that empties the citations would have to overturn the answer (ascertained absent? unevaluable?) — that fork is deliberately undecided until a consumer forces it.

### Output shapes and inference

Target output shapes:

``` text
bin_output() produces observed membership:
  hit == TRUE  -> value = 1
  hit == FALSE -> value = 0
  hit == NA    -> value = 0, with incomplete/partial coverage preserved in audit
num_output(values_from =, reduce =)
                 numeric value: the named payload channel's rows, grouped at
                 output_one_row_per, summarised by the plain function `reduce`
cat_output(levels, values_from =, reduce =)
                 categorical value over a fixed level set: the same payload read
                 as num_output; the reduced result must be one of `levels`.
                 Without a payload spec, the level comes from a text channel's
                 accepted extraction instead (documented status)
date_output(values_from =, reduce =)
                 date value: a hit row's payload value is its CLOCK -- the same
                 date column the engine windowed the row on (doc RECDATE, lab
                 DATEXAM, a code/act row's own start date) -- and `reduce` picks
                 which survives (min = first occurrence, max = last). The reduce
                 must return a Date (or NA): a silent coercion would be exactly
                 the min()-over-code-strings failure this shape exists to prevent.
                 (Landed 2026-07-07; consumer: date of the pre-op anesthesia
                 consult. An `at =` override naming a non-default clock column,
                 e.g. DATSORT, is designed but waits for its consumer. Text
                 channels as date payload are owner-allowed -- a document date is
                 the researcher's call, guarded by provenance not prohibition --
                 and also wait for their consumer.)
str_output()     unconstrained string
struct_output()  fixed-schema multi-field record; one task -> one record
```

The reducer is a plain R function `values -> scalar` (numeric for `num_output`, e.g. `\(x) max(x, na.rm = TRUE)`; one of `levels` for `cat_output`, e.g. a code-family priority rule), not a tagged operator, and it lives on the output — not on the activation — because it is the variable's question, not a channel property. `values_from` names the payload channel; with several channels in play the pick is real, non-derivable information (it is dplyr's choice of primary table, SQL's `SELECT avg(hb) FROM lab SEMI JOIN docs`).

**The payload invariant (ratified 2026-07-04): the output payload is always drawn from the post-combine row set. "Raw" has no spelling.** Three cases:

``` text
payload channel in the combine expression      -> its surviving rows
payload channel NOT in the expression          -> still scoped to the combine's
                                                  qualifying keys (the expression
                                                  decides who DEFINES the keys;
                                                  every channel is CONSTRAINED
                                                  by them)
no combine (single channel)                    -> the channel's own filtered rows
```

An unconstrained payload alongside a gate would silently mix gated and ungated semantics in one variable, so it is deliberately inexpressible: that demand is two variables and a downstream join.

The value type is inferred from the selected channel where possible:

``` text
lab measurement with numeric values -> num_output()
structured code/act                -> str_output()
text channel                        -> shape and category levels from ellmer type or other method
```

Explicit `output =` is mainly an override, especially `bin_output()` when the researcher wants membership instead of a structured channel's inferred value.

### Dispatch and validity

`combine_channels` is set algebra over channel row sets at `combine_at_level` (§10): it produces the **surviving row set, never a value**. What becomes the value is the output's decision — `bin_output()` lifts membership (`0/1`); every other output type reads the survivors' values and must therefore declare its payload: `values_from =` (whose rows) + `reduce =` (the rule collapsing them). Hits are binary; the values behind them are free. A single-channel variable has no combine: its survivors are the channel's own filtered rows, `values_from` defaults to that channel, and a text channel keeps its extraction assembly (documented status / task fields) in place of a payload spec.

Two payload edge rules: a `reduce` return that breaks its own contract (non-numeric for `num`, outside `levels` for `cat`, not exactly one value) is a **hard error**, not a review state — a deterministic closure violating its declared rule is a bug, unlike an ungrounded LLM answer. An **empty surviving payload** (e.g. a task gated in through the other side of an `|` expression) yields `NA` without calling `reduce`. The values frame records `n_payload_rows` (post-combine rows actually reduced); pre-combine matched counts already ride channel coverage.

Validity matrix (num payload ratified 2026-07-04; cat payload ratified 2026-07-05, dialysis-modality consumer):

``` text
channels  combine_channels  output                                   valid?
>=1       expression        bin_output()                              yes  membership of surviving rows -> 0/1
>=2       expression        num/cat_output(values_from =, reduce =)   yes  gate + payload over surviving rows
1         NULL              bin_output()                              yes  value = that channel's hit
1         NULL              num/cat_output(reduce =)                  yes  payload over the channel's own rows
                                                                           (values_from defaults to the channel)
1         NULL              cat/struct_output() over a text channel   yes  extraction assembly (documented
                                                                           status / task fields)
>=2       NULL              any                                       no   no reconcile rule
1         expression        any                                       no   use NULL
any       expression        non-bin output without a payload spec     no   a gate yields rows, not a value
any       expression        str/struct_output()                       no   payload rule holds, but unshaped;
                                                                           revisit with a consumer
any       any               missing and not inferable                 no   cannot validate shape
```

------------------------------------------------------------------------

## 9. Text retrieval and LLM extraction

For text channels, candidate retrieval, candidate selection, and extraction are separate concerns.

A text channel may define:

``` text
source
Lucene-like query
candidate-selection rule
default method
prompt
ellmer structured-output type
response-to-hit mapping
candidate ids and candidate shape
```

### Candidate selection

A naked `top_n` is not sufficiently explicit because it does not say how candidates are ranked. Text extraction methods should declare candidate generation, ordering, and limiting.

The engine first produces a standardized candidate table, then applies a declared selection rule.

Standard candidate columns may include:

``` text
task_id
evidence_id
subject_id
event_id
source_item_id
document_date
document_type
text
match_text
match_count
n_query_hits
query_label
```

The selection rule is a plain function over the standardized candidate table (the wrapper razor, invariant 33 — no `candidate_selection()` wrapper object):

``` r
candidates = \(d) head(
  dplyr::arrange(d, dplyr::desc(n_query_hits), dplyr::desc(document_date)),
  20
)
```

This means:

``` text
1. run the Lucene-like query
2. build the standardized candidate table
3. apply the declared selection function
4. pass the surviving candidates to the extraction method
```

Ordering and limiting are still declared — they are simply declared in the researcher's own vocabulary (dplyr/base R) instead of a bespoke object, and the function is deparsed into provenance. No implicit Lucene score is assumed unless the backend actually provides one or the engine explicitly defines one.

### Text LLM methods and ellmer structured extraction

The engine does not define a parallel LLM schema system. Text LLM methods rely on ellmer structured extraction.

A text LLM method declares a prompt and an ellmer structured-output `type`. At execution time, the engine renders the final prompt with selected candidates and calls:

``` r
chat$chat_structured(
  prompt = rendered_prompt,
  type = compiled_type
)
```

Ellmer owns:

``` text
provider/model call
structured-output formalization
type validation/conversion
structured response parsing
```

The extraction engine owns:

``` text
candidate generation and selection
prompt rendering with candidate IDs
evidence-ID generation and validation
response-to-hit mapping
channel status and audit/provenance
```

Example method declaration:

``` r
llm_after_lucene(
  candidates = \(d) head(
    dplyr::arrange(d, dplyr::desc(n_query_hits), dplyr::desc(document_date)),
    20
  ),

  prompt = "
    Determine whether the candidate text documents that the patient has diabetes.

    Count as documented:
    - known diabetes
    - type 1 diabetes
    - type 2 diabetes
    - insulin-treated diabetes
    - antidiabetic treatment clearly indicating diabetes

    Do not count as documented:
    - family history only
    - diabetes explicitly ruled out
    - simple hyperglycaemia without documented diabetes
    - hypothetical, screening, or differential diagnosis mentions
  ",

  type = ellmer::type_object(
    response = ellmer::type_enum(
      values = c("documented", "not_documented", "uncertain"),
      description = "
        documented: the text documents diabetes.
        not_documented: the text does not document diabetes.
        uncertain: the text is ambiguous or insufficient.
      "
    )
  ),

  positive_hit_when = "documented",
  require_evidence = TRUE,
  require_rationale = TRUE
)
```

`type` is the ellmer structured-output type for the analytical response. If `require_evidence` or `require_rationale` is `TRUE`, the engine adds the standard audit fields to the compiled type and prompt before calling `chat$chat_structured()`.

Evidence IDs and rationale are therefore standard engine fields. They are not normally declared by the user in every `type` object.

`positive_hit_when` is a response-state literal, not an R expression. Use:

``` r
positive_hit_when = "documented"
```

Do not use expression-style predicates here. This keeps the mapping serializable, inspectable, and easy to preserve in provenance. If later variables need multi-field predicates, add that as a deliberate method-level extension rather than by quietly accepting arbitrary expressions.

For binary hit extraction, the LLM response is mapped to the channel hit as follows:

``` text
response satisfying positive_hit_when -> hit = TRUE
explicit negative response            -> hit = FALSE
uncertain response                    -> hit = NA
invalid output                        -> hit = NA
```

For the standard ternary pattern:

``` text
documented      -> hit = TRUE
not_documented  -> hit = FALSE
uncertain       -> hit = NA
invalid         -> hit = NA
```

The original model response is preserved separately from the derived hit:

``` text
hit
  TRUE / FALSE / NA

llm_response
  documented / not_documented / uncertain / invalid
```

This keeps the boolean layer simple while preserving the model's actual answer for audit and review.

A concept channel may provide a default text LLM method, including its candidate-selection rule, prompt, ellmer type, and response-to-hit mapping. A `variable_spec` may replace that method at activation time. Defaults must be inspectable before execution and frozen into provenance after execution.

### Evidence-ID behavior

Evidence IDs are LLM-citation identifiers for candidate text snippets. They are not general source identity fields.

For the default HDW model, each `evidence_id` is the candidate label shown to the model and maps back to `source_item_id`, `subject_id`, `event_id`, date, and text. If a source item is split into multiple passages, the evidence ID may be a deterministic label derived from the source item.

Parser behavior for cited evidence IDs:

``` text
real evidence id + fabricated evidence id
  -> keep value, keep real evidence, surface citation_warning

only fabricated evidence id
  -> invalid / needs_review
```

This rule should be shared across text parsers rather than re-derived per concept.

Current migration note: `citation_warning` exists at the LLM extraction boundary and should be preserved in channel-level artifacts. Do not let fabricated evidence IDs materialize as evidence rows. Hoist warning fields into generic value/review envelopes only when a real consumer needs them; until then they are audit detail, not a reason to change boolean hit-set values.

### Engine promise at the LLM boundary

The LLM call is the only non-deterministic node in the pipeline. Everything else — retrieval/eligibility, structured code/lab measures, combine operators, absence handling, and audit envelope — is deterministic.

The engine does not promise:

``` text
the LLM output is accurate
```

It promises that around that one call, the deterministic pipeline:

``` text
1. selected candidates                         retrieval + eligibility
2. called ellmer structured extraction         prompt + compiled type
3. accepted only grounded/valid parts          field-level acceptance
4. routed failures/ungrounded claims to review needs_review, citation_warning
5. preserved evidence/status/provenance        audit envelope
```

Accuracy or gold-label scoring of model answers is out of scope for the engine's guarantees. A run where the model extracts little, abstains, or makes an ungrounded claim that is routed to review is the pipeline working as promised. Validation targets the mechanism, not the model's clinical correctness.

## 10. Combining channels: set algebra on the spine

The public combine surface is a bare string expression over activated channel names, plus an evaluation level:

``` r
combine_channels = "(transplant_act | transplant_status) & !dialysis_signal"
combine_at_level = "EVTID"   # optional; defaults to output_one_row_per
```

(Ratified 2026-07-04: the parameter is named `combine_channels`, the expression stays a flat string — no constructor wraps it — and `combine_at_level` decouples the evaluation grain from the output grain, §7. A single-channel variable has no combine: its filtered rows already are the surviving set, and combine exists only when two or more row sets need algebra.)

Under the pipeline model (§2), each channel is a filtered row set carrying the identity spine, and the expression is relational algebra on spine keys at the stated level: `&` = semi-join, `!` = anti-join, `|` = union. The result is the **surviving row set**; the output kind decides what happens to it — `bin_output()` takes membership per output-grain group, `num_output(values_from =, reduce =)` summarises the payload channel's surviving rows (§8).

For boolean variables this specializes to set algebra over explicit hit sets, not clinical ontology and not Kleene truth logic. A hit set is the set of keys at `combine_at_level` matched by one channel activation under the current `variable_spec` (at the default level those keys are the task ids).

``` text
A | B  = union(A, B)
A & B  = intersect(A, B)
!A     = complement of A relative to the current task universe
```

`!dialysis_signal` means “not in the observed `dialysis_signal` hit set within the current task universe.” It does not mean “clinically no dialysis.” It subtracts one explicit observed result set from another; it does not negate a disease.

### Grammar

``` text
allowed:  activated channel-name symbols, |, &, !, parentheses
rejected: function calls, arithmetic, comparison operators, literals/constants,
          unknown symbols, activated-but-unused channels, malformed expressions
```

Referenced channel names must be exactly the activated channels of the variable. Unknown symbols and activated-but-unused channels are build-time errors.

### Observed set algebra

A task is a member of a channel's hit set iff `hit == TRUE`. Both `FALSE` and `NA` are non-members for the purpose of the final observed set operation. The final boolean value is therefore always determined:

``` text
A & !B, with A = TRUE and B = NA

A's observed set contains the task.
B's observed set does not contain the task.
A minus B still contains the task.

value = 1
channel_coverage = partial
```

The uncertainty about B belongs in audit, not in the boolean value. A strict epistemic mode that propagates `NA` into the decision may exist later, but only behind an explicit opt-in flag.

### Public boolean envelope

For boolean hit-algebra variables:

``` text
value             0 / 1
channel_coverage  complete / partial / failed
```

Coverage meanings:

``` text
complete = every selected channel was evaluable as TRUE/FALSE
partial  = at least one selected channel was unavailable/unevaluable (NA)
failed   = at least one selected channel errored
```

The public surface does not need `decision` or `decision_state`: observed set algebra is always determined, and included/excluded is a presentation recoding of `value` for cohort selection, not the generic engine output.

A historical trap: the older `decision_state` / `ascertainment` vocabulary conflated two questions: whether the final observed set operation was determined, and whether every selected channel was evaluable. In this contract the first is always determined for observed boolean algebra; the second belongs only in `channel_coverage` and the membership/audit tables.

A closed-world clinical label such as “patients with the act and no dialysis” is only honest if the `variable_spec` explicitly declares the selected exclusion definition sufficient for that interpretation. Otherwise the result is “patients with the act and no dialysis hit, coverage permitting.”

### Downstream contract

`value` carries only the declared algebra's result. `channel_coverage` carries evaluability and is part of variable provenance.

An analyst computing `mean(value)` includes `0`s from coverage-incomplete tasks by design. Summaries that must exclude incompletely ascertained tasks filter on `channel_coverage`.

### Overlap audit

The audit is not reduced to in/out. Alongside `values`, the engine emits:

``` text
membership long-form:
  grain_id
  channel
  hit = TRUE/FALSE/NA preserved
  processing_state
  optional matched rows / LLM evidence IDs for hits

overlap summary:
  per-channel state columns with NA preserved
  pattern
  count
  pattern-determined value
  channel_coverage
```

No public `role`/`polarity` column is needed. A channel observes only its own hit; its logical position lives in `combine_rule`.

Implementation boundary while the API remains experimental: `R/hitset.R` should stay the pure boolean core (parser, grammar check, observed-membership evaluator, overlap summarizer). `R/run_variable.R` attaches channel status, selected evidence, source contribution, and provenance. Expression polarity may be derived internally to lower sugar such as `hit_set_difference()`, but it should not become a public channel property.

The overlap summary should be directly consumable by ggupset / UpSetR. The useful scientific object is how source hit sets overlap or fail to overlap, not only the final flag.

### Sugar

`any_positive()` is syntax sugar for an OR expression over activated channels. `hit_set_difference(include = a, exclude = b)` is syntax sugar for `a & !b`, with OR-within-role unions for multiple channels. Both lower to the same string-expression machinery. There is one boolean mental model.

------------------------------------------------------------------------

## 11. Absence, silence, coverage, and audit

Absence semantics must not be collapsed silently.

The engine should preserve statuses such as:

``` text
source_missing
source_available
no_rows_in_window
no_candidate
candidate_found
positive_signal
negative_signal_if_extracted
extractor_failed
invalid_output
partial_failure
```

For boolean variables, `no_candidate` means no observed hit and therefore non-membership in the observed set. It does not become a missing boolean value. Unevaluability is represented through `channel_coverage` and the membership/audit tables.

Silence from one channel must never be interpreted as contradiction with another channel unless the variable definition explicitly requests such logic.

Example:

``` text
ICD10/CCAM dialysis signal present
documents no_candidate
```

The engine should report:

``` text
final value from the researcher-selected rule
positive source(s): ICD10/CCAM channel
silent source(s): documents
matched rows: coded row(s)
channel status: documents no_candidate
```

It should not invent labels such as “uncorroborated,” “weak yes,” or “possible dialysis” unless those labels are explicitly part of the `variable_spec`.

The engine's responsibility is to expose:

``` text
which channels were activated
which channels produced matched rows or LLM evidence IDs
which channels produced no candidate
which channels were unavailable
which matched rows or LLM evidence IDs support positive outputs
which rule produced the final value
```

Clinical interpretation of those source contributions belongs downstream.

Per-channel `processing_state` should be normalized as:

``` text
evaluated
no_candidate
no_input_rows
not_called
invalid
execution_error
```

Executor-specific raw states may be kept internally when needed to derive `hit = FALSE` versus `hit = NA`.

------------------------------------------------------------------------

## 12. Resolution, inspection, and provenance

Declared defaults must be easy to inspect, easy to replace, and preserved in provenance.

The engine should support inspection at two levels:

``` r
inspect(concepts$diabetes$text_diabetes_mentions)
```

to view the concept channel default, and:

``` r
resolve_variable_spec(diabete_pre_anchor)
```

to view the fully resolved executable definition after inheritance and local replacements.

Example resolved view:

``` text
variable: diabete_pre_anchor
concept: diabetes
output_one_row_per: PATID
anchor: inclusion_date
window: c(-365, 0) days around anchor

activated channels:

1. pmsi_diag_e10_e14
   channel type: code_channel
   source: pmsi_diag
   raw source roles:
     subject_id     = PATID
     event_id       = EVTID
     source_item_id = ELTID
     code           = code
     event_start    = DATENT
     event_end      = DATSORT
   selector:
     icd10("^E1[0-4]")
   method:
     structured_hit
   contribution:
     hit TRUE/FALSE/NA
     optional matched rows: source_item_id, code, event_start, event_end

2. text_diabetes_mentions
   channel type: text_channel
   source: documents
   raw source roles:
     subject_id     = PATID
     event_id       = EVTID
     source_item_id = ELTID
     text           = RECTXT
     document_type  = RECTYPE
     point_date     = RECDATE
   selector:
     lucene_query("diabete OR diabetique OR insulinotherapie OR insuline")
   method:
     llm_after_lucene
       candidates:
         \(d) head(arrange(d, desc(n_query_hits), desc(document_date)), 20)
       prompt:
         Determine whether the candidate text documents diabetes...
       type:
         ellmer::type_object(response = ellmer::type_enum(...))
       positive_hit_when:
          "documented"
       require_evidence = TRUE
       require_rationale = TRUE
   contribution:
     hit TRUE/FALSE/NA
     llm_response
     evidence_ids
     rationale
     citation warnings if applicable

final output:
  bin_output()

combine_channels:
  pmsi_diag_e10_e14 | text_diabetes_mentions
combine_at_level:
  PATID (default = output_one_row_per)
```

Every produced dataset should be traceable to:

``` text
source_spec version or resolved source mapping
concept_spec version or resolved concept definition
variable_template version if used
variable_spec version or resolved variable definition
code commit
source export date
runtime settings
model/provider
rendered prompt
ellmer structured-output type
retrieval query
candidate-selection rule
execution timestamp
```

Versioning is operationally annoying but scientifically valuable. It is part of the engine's execution and traceability responsibility.

### The produced-dataset provenance object (ratified 2026-07-03)

`run_variable()` output carries `provenance`, a serializable `ee_provenance` record of what actually executed (invariant 27 made concrete):

- **identity** — variable, concept, template (if used);
- **the resolved definition** — `output_one_row_per`, anchor (task column or `index_event` snapshot), window (relative days), combine expression, output shape, and per activated channel: type, source, the resolved source-role mapping, and the **resolved selector with its origin** (activation override vs concept default). It is assembled from `resolve_variable_spec()`, so the audit trail and the executor read the same resolution — a trail recording the concept baseline while the executor ran a local override would be a silent audit lie;
- **execution facts** — model name and execution timestamp.

Per-attempt LLM provenance (provider, seed, prompt/schema/query hashes) already rides on `channel_results[[channel]]$attempts` and is not duplicated. Still deferred until the engine can actually know them (§16 discipline): code commit, source export date, runtime settings beyond the model name, and template versioning.

### Testing philosophy

The test suite should protect semantic contracts, not incidental implementation structure.

A contract test should describe observable behavior that must remain true even if internal operators, filenames, wrappers, or object layouts change. For example: a channel hit means selector membership at the declared grain; combine evaluates hit-set algebra over activated channels; output declares the final value shape; channel_coverage carries evaluability.

A regression test may protect a bug fix tied to a current implementation detail, but it should be labeled as such and should not be mistaken for a design invariant.

A migration test may temporarily protect old spellings or transitional compatibility, but it should be easy to delete when the migration ends.

Before locking a validity matrix or public API rule, test it against at least one code channel, one text channel, one thresholded lab channel, one unthresholded lab channel, one patient-grain variable, and one event/stay-grain variable. This prevents the implementation from optimizing around a narrow current use case and freezing a local maximum.

### The protected test floor (ratified 2026-06-30; extended 2026-07-03)

After pruning ~400 tests down to a handful, the suite was re-derived from a single gate: in this phase a test earns its place only if the failure it catches is (a) **silent**, (b) on a deterministic invariant we have actually **decided**, and (c) **invisible to the real validation** — real-model-on-real-data runs reviewed by a physician. The LLM node carries the clinical risk and is human-reviewed by design, so tests cannot adjudicate its answers; loud failures self-surface on the next real run. The suite is therefore a set of tripwires on decided silent regressions plus a refactoring safety net — it is not the validation story.

The **protected floor** (do not delete without re-opening this decision):

- `hitset-expr #1` — observed hit-set algebra: `A & !B` with `B` unavailable resolves to included / value 1 / coverage partial (deliberate, non-Kleene; a regression silently flips cohort membership).
- `hitset-expr #2` — combine grammar is fail-closed: function calls, non-activated channels, and activated-but-unused channels are rejected.
- `diabetes #4` — the `run_variable()` spine is concept-agnostic: each channel's own selector drives a neutral executor (a hard-wired selector would silently mis-measure every new concept).
- `smoking #3` — D1 citation keep-and-flag: a value grounded by ≥1 real id is kept and flagged when the model also cites an invented id; an only-invented citation is rejected.
- `anastomoses #2` — field-level acceptance: a valid field survives an invalid sibling and routes to review (the §9 accept-only-grounded promise made concrete).

Extended 2026-07-03 (owner-ratified): five invariants decided and shipped after the original ratification pass the same gate, so their tests join the floor:

- `event-stay-grain #1` / `lab-stay-grain #1` — grain-key scoping, both executor branches: candidates are scoped to the task's own `EVTID`, not just the subject. A PATID-only join silently inflates every stay-grain value with the subject's other stays.
- `channel-override #1` — the activation selector drives the executor (§14.3): a silent fallback to the concept baseline would make every locally-overridden variable measure the wrong definition.
- `index-event #2` — anchor resolution is fail-closed: multiple matching index events per subject ERROR. Silently resolving to an arbitrary event would shift every window and flip cohort membership invisibly.
- `lab-threshold #1` — the thresholded-analyte tri-state (§8): above-cutoff hit, measured-below (value 0, coverage complete), no measurement (value 0, coverage partial). A silent flip feeds wrong availability into the observed hit-set algebra.
- `whole-history #2` — no-window subject eligibility reaches a document any date window would exclude: a window default silently reintroduced removes candidates before anyone can review them.
- `provenance #1` — the produced-dataset provenance object records the **resolved** definition (invariant 27): the selector recorded for each channel is the one that executed (an activation override, not the concept baseline). The values are computed correctly either way, so a lying trail is invisible to physician review of the output.

Everything outside the floor is cuttable without ceremony. The coverage matrix above is a **design-freezing discipline applied once, when a validity-matrix or public-API rule is locked** — not a standing requirement that each shape keep a permanent test. The provenance floor candidate closed 2026-07-03: the produced-dataset provenance object was ratified (§12 above) and `provenance #1` joined the floor with it.

The original five-test core was ratified by the owner with Claude and Codex independently concurring; the 2026-07-03 extension was owner-ratified after a fresh-eyes review found the floor under-inclusive relative to invariants decided since 2026-06-30. Deliberately not promoted: the `output-grain-guard` test (the guard failing is only harmful jointly with a second bug, so the failure is not silent on its own) and everything structural/loud (envelope shape, spec constructors).

## 13. Variable templates

A `variable_template` is a reusable concept-specific analytical pattern for a recurring variable family.

At the current design stage, templates can be simple documented snippets that researchers copy and explicitly adapt into a `variable_spec`. Once a pattern is stable and repeatedly reused, it may be promoted to an executable builder that returns a `variable_spec`.

``` text
worked example / snippet
  -> repeated protocol pattern
  -> formal variable_template
  -> optional executable builder
```

A template may encode a default operationalization, but it does not define the concept globally. Using a template is a protocol choice.

Valid templates are concept-specific:

``` text
diabetes_baseline_status_template
diabetes_glycaemic_control_template
diabetes_perioperative_hyperglycaemia_template
smoking_status_around_anchor_template
active_smoking_binary_template
dialysis_status_before_anchor_template
incident_dialysis_after_anchor_template
recipient_anastomoses_template
```

Generic patterns are operators/helpers, not templates:

``` text
closest_before_anchor()
llm_after_lucene()
any_positive()
threshold_binary()
collect_fields()
```

Within-channel reduction is not an operator: it is a plain function on the payload
channel's rows, supplied on the output, e.g. num_output(values_from = "glucose_measurements",
reduce = \(x) max(x, na.rm = TRUE)).

Example snippet-style template:

``` r
# Template snippet: baseline documented diabetes status before anchor
# Copy this into the study protocol and edit explicitly.

diabete_pre_anchor <- variable_spec(
  name = "diabete_pre_anchor",
  concept = diabetes,

  output_one_row_per = "PATID",
  anchor = "inclusion_date",
  window = c(-365, 0),

  channels = c("pmsi_diag_e10_e14", "text_diabetes_mentions"),

  output = bin_output(),
  combine_channels = "pmsi_diag_e10_e14 | text_diabetes_mentions"
)
```

------------------------------------------------------------------------

## 14. Minimal examples

### 14.1 Stable concept library

``` r
diabetes <- concept_spec(
  name = "diabetes",

  channels = list(
    pmsi_diag_e10_e14 = code_channel(        # source resolves -> "pmsi_diag"
      selector = icd10("^E1[0-4]")
    ),

    text_diabetes_mentions = text_channel(   # source resolves -> "documents"
      selector = lucene_query("diabete OR diabetique OR insulinotherapie OR insuline"),

      default_method = llm_after_lucene(
        candidates = \(d) head(
          dplyr::arrange(d, dplyr::desc(n_query_hits), dplyr::desc(document_date)),
          20
        ),

        prompt = "Determine whether the candidate text documents diabetes.",

        type = ellmer::type_object(
          response = ellmer::type_enum(
            values = c("documented", "not_documented", "uncertain"),
            description = "
              documented: the text documents diabetes.
              not_documented: the text does not document diabetes.
              uncertain: the text is ambiguous or insufficient.
            "
          )
        ),

        positive_hit_when = "documented",
        require_evidence = TRUE,
        require_rationale = TRUE
      )
    ),

    glucose_measurements = lab_channel(      # source resolves -> "biology"
      selector = analyte("GLU.GLU")
    )
  )
)
```

### 14.2 Multi-channel binary variable

``` r
diabete_pre_greffe <- variable_spec(
  name = "diabete_pre_greffe",
  concept = diabetes,

  output_one_row_per = "PATID",
  anchor = transplant_date(),
  window = c(-3650, 0),

  channels = c("pmsi_diag_e10_e14", "text_diabetes_mentions"),

  output = bin_output(), # Because output = bin_output(), the LLM response is collapsed into observed hit membership using positive_hit_when. To keep the LLM response itself as the analytical value, use cat_output() or struct_output() instead.
  combine_channels = "pmsi_diag_e10_e14 | text_diabetes_mentions"
)
```

This variable asks whether either activated channel has an observed diabetes hit before transplant. It does not use glucose measurements because the protocol did not activate that channel.

### 14.3 Local override of concept defaults

``` r
diabete_type2_pre_greffe <- variable_spec(
  name = "diabete_type2_pre_greffe",
  concept = diabetes,

  output_one_row_per = "PATID",
  anchor = transplant_date(),
  window = c(-3650, 0),

  channels = list(
    text_diabetes_mentions = use_channel(
      selector = lucene_query("diabete type 2 OR DNID OR antidiabetique"),

      method = llm_after_lucene(
        candidates = \(d) head(dplyr::arrange(d, dplyr::desc(document_date)), 50),

        prompt = "Determine whether the candidate text documents type 2 diabetes.",

        type = ellmer::type_object(
          response = ellmer::type_enum(
            values = c("type2_documented", "not_documented", "uncertain"),
            description = "
              type2_documented: the text documents type 2 diabetes.
              not_documented: the text does not document type 2 diabetes.
              uncertain: the text is ambiguous or insufficient.
            "
          )
        ),

        positive_hit_when = "type2_documented",
        require_evidence = TRUE,
        require_rationale = TRUE
      )
    )
  ),

  output = bin_output()
)
```

### 14.4 Single-channel numeric reduction

``` r
perioperative_max_glucose <- variable_spec(
  name = "perioperative_max_glucose",
  concept = diabetes,

  output_one_row_per = "PATID",
  anchor = surgery_date(),
  window = c(0, 2),

  channels = c("glucose_measurements"),

  output = num_output(
    values_from = "glucose_measurements",
    reduce = \(x) max(x, na.rm = TRUE)
  )
)
```

This variable summarises the lab channel's rows numerically; with a single channel and no combine, the payload is the channel's own filtered rows.

### 14.5 Single-channel membership variable

``` r
has_glucose_measurement <- variable_spec(
  name = "has_glucose_measurement",
  concept = diabetes,

  output_one_row_per = "PATID",

  channels = c("glucose_measurements"),

  output = bin_output()
)
```

This variable asks only whether at least one in-scope glucose measurement exists.

### 14.6 Thresholded lab membership variable

``` r
has_hyperglycaemia <- variable_spec(
  name = "has_hyperglycaemia",
  concept = diabetes,

  output_one_row_per = "PATID",

  channels = list(
    glucose_measurements = use_channel(
      selector = analyte_value("GLU.GLU", gt = 11, unit = "mmol/L")
    )
  ),

  output = bin_output()
)
```

This variable asks whether at least one in-scope glucose result above the threshold exists.

### 14.7 History variable with a task-column anchor (antécédent de cholécystectomie)

Validated as a target-surface stress test 2026-07-04. Deliberately the common case: no level machinery, whole-history lookback, researcher-precomputed anchor.

``` r
cholecystectomy <- concept_spec(
  name = "cholecystectomy",
  channels = list(
    text_mentions = text_channel(          # source resolves -> "documents"
      selector  = lucene_query('cholecystectomie OR "ablation de la vesicule"'),
      default_method = llm_after_lucene(
        prompt = "Identify only an explicitly documented cholecystectomy in the
                  supplied snippets. Do not infer absence from silence.",
        type = ellmer::type_object(
          response = ellmer::type_enum(
            values = c("documented", "not_documented", "uncertain")
          )
        ),
        positive_hit_when = "documented",
        require_evidence = TRUE
      )
    ),
    ccam_act = act_channel(                # source resolves -> "pmsi_actes"
      selector = ccam("HMFC004")           # placeholder act code
    )
  )
)

atcd_cholecystectomie <- variable_spec(
  name    = "atcd_cholecystectomie",
  concept = cholecystectomy,

  channels = c("text_mentions", "ccam_act"),

  anchor = "T0",                # researcher-precomputed inclusion date, one per task row
  window = c(-Inf, 0),          # all recorded history before T0

  combine_channels   = "text_mentions | ccam_act",
  output_one_row_per = "PATID",
  output  = bin_output()
)
```

Reminder from §7: the text channel windows on document date — this measures "mentioned before T0" (safe for a lookback: pre-T0 documents can only describe pre-T0 surgery), not "happened before T0."

### 14.8 Act-anchored forward complication with same-stay combine (SSI post spinal surgery)

Validated as a target-surface stress test 2026-07-04. This is the canonical consumer of `combine_at_level` (wired 2026-07-05 via this shape's probe — the trap patient with the text hit in one stay and the act in another scores 0) and `select_event` (wired later the same day via its own probe — first-surgery clock vs one-clock-per-surgery, §7).

``` r
ssi <- concept_spec(
  name = "surgical_site_infection",
  channels = list(
    text_ssi = text_channel(
      selector  = lucene_query('"infection du site" OR ISO OR abces OR "reprise pour sepsis"'),
      default_method = llm_after_lucene(
        prompt = "Identify only an explicitly documented surgical site infection
                  in the supplied snippets. Do not infer absence from silence.",
        type = ellmer::type_object(
          response = ellmer::type_enum(
            values = c("documented", "not_documented", "uncertain")
          )
        ),
        positive_hit_when = "documented",
        require_evidence = TRUE
      )
    ),
    cim10_ssi    = code_channel(selector = icd10("^T81\\.4")),   # placeholder codes
    act_revision = act_channel(
      selector = ccam(c("ACT_LAVAGE", "ACT_DRAINAGE", "ACT_REPRISE"))  # placeholders
    )
  )
)

ssi_6mo_post_spinal <- variable_spec(
  name    = "ssi_6mo_post_spinal_surgery",
  concept = ssi,

  channels = c("text_ssi", "cim10_ssi", "act_revision"),

  anchor = index_event("pmsi_actes", ccam(SPINAL_SURGERY_ACTS),  # placeholder set
                       at = "DATEACTE",
                       select_event = \(d) dplyr::slice_min(d, DATEACTE, n = 1)),
  window = c(0, 180),

  combine_channels   = "text_ssi & (cim10_ssi | act_revision)",  # researcher's rule;
                       # strict variant "text_ssi & cim10_ssi & act_revision" is a
                       # one-line swap — which is right is a methods decision, not
                       # the engine's
  combine_at_level   = "EVTID",     # co-occurrence within the SAME stay
  output_one_row_per = "PATID",     # 1 if any qualifying stay in the window
  output  = bin_output()
)
```

Task list posture: subjects come from an upstream inclusion variable over `SPINAL_SURGERY_ACTS`, so anchor no-match stays a loud error (§7). "Who scored" per row is the membership/UpSet audit (§10); the LLM's justification is its grounded evidence (§9).

### 14.9 Gated numeric payload (mean haemoglobin in anaemic stays)

The canonical `values_from` example — the reference dplyr pipeline from §2, as one spec.

``` r
anemia <- concept_spec(
  name = "anemia",
  channels = list(
    text_anemia = text_channel(
      selector = lucene_query("anemie OR anemique")
      # default_method as in 14.7-14.8, omitted here for brevity
    ),
    hb_low = lab_channel(
      selector = analyte_value("HGB", lt = 12, unit = "g/dL")  # the concept's lab
    ),                                                          # definition of anaemia
    hb_all = lab_channel(
      selector = analyte("HGB")                                 # every Hb measurement
    )
  )
)

mean_hb_anemic_stays <- variable_spec(
  name    = "mean_hb_anemic_stays",
  concept = anemia,

  channels = c("text_anemia", "hb_low", "hb_all"),

  anchor = "T0",
  window = c(-365, 0),

  combine_channels   = "text_anemia & hb_low",
  combine_at_level   = "EVTID",
  output_one_row_per = "EVTID",    # or "PATID": pooled over all qualifying rows
  output = num_output(
    values_from = "hb_all",        # not in the expression -> still key-scoped (§8):
    reduce      = mean             # ALL Hb values within qualifying stays
  )
)
```

Swap `values_from = "hb_low"` to average only the sub-threshold values instead: which values enter the mean is controlled by which channel is the payload, never by an unconstrained escape from the gate.

## 15. Design invariants

Future agents should not violate these principles.

1.  The engine does not inherently care about clinical truth. The engine owns execution and traceability. The researcher owns interpretation.
2.  `source_spec` knows source structure; it does not know the study protocol.
3.  Users must be able to provide source mappings when their dataset column names differ from defaults.
4.  `concept_spec` is a reusable signal-channel catalog, not a clinical truth object.
5.  A channel resurfaces source-specific signals. It does not interpret their clinical meaning.
6.  A channel definition lives in `concept_spec`; a channel activation lives in `variable_spec`.
7.  Concept channel defaults may exist, including text LLM method defaults, but they must be declared, inspectable, replaceable, and preserved in provenance.
8.  `use_channel()` inherits by default; supplied fields replace inherited fields locally. There is no separate refinement semantics for now.
9.  No concept channel is used unless a `variable_spec` or template explicitly activates it.
10. `variable_spec` is the concrete executable protocol-specific analytical variable definition.
11. `variable_template` is concept-specific; generic computational pieces are operators/helpers.
12. `output_one_row_per` defines the output grain and task universe. `combine_channels` evaluates at `combine_at_level`, which defaults to that grain; qualifying keys exists-lift to output rows.
13. A channel `hit` means the selected definition matched at least one in-scope signal.
14. An unthresholded lab channel hits when a measurement exists; thresholded lab membership is represented by a thresholded selector.
15. Boolean combine is observed hit-set algebra over explicit hit sets, not clinical ontology and not Kleene logic.
16. `!A` means complement within the task universe, not clinical negation.
17. Boolean hit-algebra variables return `value = 0/1`; channel unevaluability belongs in `channel_coverage` and audit, not in a missing boolean value.
18. Text candidate selection must declare both ordering and limiting. No implicit Lucene score is assumed unless a backend provides one or the engine defines one.
19. The engine does not implement a parallel LLM schema system. Text LLM methods rely on ellmer structured extraction through `chat$chat_structured()`.
20. For LLM binary extraction, `positive_hit_when` is a response-state literal declaring which response becomes `hit = TRUE`; explicit negative maps to `FALSE`; uncertain and invalid map to `NA`.
21. Evidence IDs and rationale are standard engine fields triggered by `require_evidence` and `require_rationale`, not normally exposed in every ellmer `type` object.
22. Evidence IDs are LLM candidate citation labels, not general source identity fields. Structured deterministic channels may expose matched rows for audit/debugging but do not need LLM-style evidence citations.
23. Silence from one channel is not contradiction with another channel unless the variable explicitly defines such logic.
24. Source contribution must remain visible: activated channels, positive hits, silent channels, unavailable channels, optional matched rows, evidence IDs for LLM candidates, and the rule used.
25. LLM extraction must be evidence-grounded, schema-controlled through ellmer, and auditable.
26. The engine does not guarantee LLM accuracy; it guarantees controlled and reviewable execution around the LLM call.
27. Provenance is part of the output contract, not optional documentation.
28. For single-channel bin_output(), the final value is still observed membership 0/1. Channel hit NA becomes value 0 with incomplete coverage/audit status, not a missing value.
29. Tests should protect semantic contracts, not incidental implementation structure. Regression tests and migration tests are useful, but they must not freeze temporary wrappers, object layouts, or current code paths as architectural truth.
30. A channel is a filtered row set carrying the identity spine; its rows are simultaneously membership hits and value carriers. Cross-source, cross-channel combination happens only through spine keys (`PATID ⊃ EVTID ⊃ source_item_id`).
31. `combine_channels` is set algebra at `combine_at_level` producing the surviving row set; the output kind decides what is done with those rows. A single-channel variable has no combine.
32. Output payloads are always drawn from the post-combine row set; "raw" has no spelling. An unconstrained payload alongside a gate is two variables, never one.
33. A spec constructor earns its place only if it encodes semantics the engine must interpret (dispatch keys, role/selector bindings). Anything the researcher could write as plain R data, a plain function, or plain ellmer stays plain (the wrapper razor).
34. Definers bind location; activations never do. Typed channel constructors may appear in a `concept_spec` or inline in a variable's channel list under non-colliding names; `use_channel()` carries no `source`, and an omitted `source` on a definer resolves against the registry unique-or-error, never by default.
35. Accepting a multi-row `select_event` is accepting per-event output rows: anchor multiplicity sets task multiplicity, `output_one_row_per` must name the event-grain key, and the output-grain guard enforces the match.

## 16. Deferred capabilities (gated on consumer)

These are declared parts of the target contract that are **reserved, not built**. Each is gated on a concrete downstream consumer; building it before that consumer exists is speculative and forbidden by invariant discipline. This section replaces the retired `MIGRATION.md` shipped-vs-target tracker — the migration it tracked is complete, and what remained was either done bookkeeping (dropped) or the forward-looking deferrals below.

1. **`.lab_source_binding()` — role-resolved lab columns.** The lab executor (`measure_analyte_values`) still names biology columns directly (`DATEXAM` / `analyte` / `value` / `value_raw` / `BIOL_ID`) because biology is a single source, so nothing forces role-resolution (contrast the code/act path, which is role-driven precisely because it has two coded sources with different physical code columns). *Consumer:* a second biology source — e.g. microbiology results. When it lands, the response is role-resolution parity with the code path, not any `redsan` auto-seeding (no such API exists; the source registry stays hand-declared).

2. **`llm_after_lucene(...)` declarative signature.** The text method is a declarative tag today; its method-specific knobs (`prompt`, `type`, `candidates`, `positive_hit_when`) live in the `extractor` bundle that dispatch consumes, while `inspect()` surfaces the tag. The target folds those knobs *into* the `llm_after_lucene(candidates = ..., prompt = ..., type = ..., positive_hit_when = ...)` signature, where `candidates` is a plain function over the standardized candidate table (§9; the previously reserved `llm_candidate_selection()` wrapper was dropped by the wrapper razor, 2026-07-04). *Consumer:* text retrieval running in-engine (today the text source is pre-retrieved, so a selection knob would be set-but-not-read). An unread knob is not carried in the meantime.

3. **`positive_hit_when` response-to-hit literal.** Response-to-hit mapping is currently the binary parser's `documented` → `present` → hit. The target exposes an explicit literal declaring which response state becomes `hit = TRUE` (see invariant 20). *Consumer:* a variable needing a mapping the parser does not already bake in.

4. **Broadened `inspect()` / `resolve_variable_spec()`.** A minimal experimental form exists for concept, channel, and variable specs. The target exposes inherited channel defaults and the final executable view. *Consumer:* later slices that reveal missing fields; broaden only then.

5. **Public execution surface (temporary adapters).** The runner reuses `measure_*()` / `run_extraction()` as temporary adapters — they are generic over their parameters but are not the intended public execution architecture. *Consumer:* a deliberate design of the public execution surface; until then the adapters stand.

6. **Role-named output columns.** The source layer resolves *inputs* from canonical roles, but emitted frames still use the historical runner column names (the target role vocabulary is exposed through source metadata, not yet on output frames); internal output `$kind` likewise keeps the binary/number/categorical/fields vocabulary. *Consumer:* a downstream reader that needs role-named output columns.

### Ratified surface pending wiring (2026-07-04 batch)

The pipeline-model surface above (§2, §5–§8, §10) is ratified contract; most spellings landed 2026-07-05. Still pending, each with its gate:

``` text
source-kind registry resolution     a channel omitting source= resolves it from a
  (channel without source=)         registry kind (e.g. the one documents source);
                                    needs a content-kind facet on source_spec --
                                    gate: a consumer that cannot name its source
lab value predicates with subject
  context (sex/age thresholds)      consumer: 14.9's hb_low channel; the predicate
                                    is a plain closure — how subject attributes
                                    reach it (task columns vs demographics join)
                                    is decided at build time
```

`num_output(values_from =, reduce =)` / `cat_output(levels, values_from =, reduce =)` and the pre/post payload counts landed 2026-07-05 (dialysis-modality consumer). `combine_at_level` + exists-lift + key-scoped payload landed later the same day (consumers 14.8/14.9 as probes; §7 records the execution semantics), together with `analyte_value(lt =)` (14.9's fixed-threshold hb_low; the subject-context predicate above remains open). The aggregate membership predicate (former item 7, the HAVING shape) landed the same day — §8 records the `group_at_level` + `keep_group_when` spelling and its fail-closed rules. The spec-layer renames landed the same day: `combine_channels` (old name rejected loudly), `window = c(from, to)` (ctors deleted; `c(-Inf, 0)` = unbounded lookback), and the three channel entry forms of §5 including variable-local inline definitions (collisions with concept names rejected; `required_roles` / `native_grain` were already optional declaration metadata, and a channel without `linkage` takes the subject path). `index_event(select_event =)` + per-event task emission landed the same day (§7 records the emission and scoping rules; the anchor pass runs before the grain guard so `identity` under patient-grain output fails loudly).

When a piece lands, note it in `HANDOFF.md` and delete its line here; do not fork the contract text.
