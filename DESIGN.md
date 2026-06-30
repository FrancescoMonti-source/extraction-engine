# Extraction Engine — Design Contract

## 1. Purpose and scope

This project is an HDW-aware, protocol-agnostic extraction framework for building study analytical variables from a stable hospital data warehouse structure.

It is a framework where researchers define study-specific analytical variables by selecting concepts, signal channels, units, anchors, windows, extraction methods, reducers, transformations, output types, and audit requirements. The engine executes those definitions against known HDW sources and returns auditable analytical variables.

Researchers remain responsible for scientific validity, protocol design, and operational definitions. The engine is responsible for explicit execution, mechanical consistency, reproducibility, and provenance.

The engine owns execution and traceability. The researcher owns interpretation.

At the LLM boundary, the engine does not promise that the model output is accurate. It promises that a deterministic pipeline selected candidates, called the model under a controlled schema, accepted only grounded/valid parts, routed failures and ungrounded claims to review, and preserved evidence, status, and provenance.

Out of scope: full protocol design, scientific justification, cohort governance, clinical trial management, physician workflow management, and global study lifecycle management. A higher research platform may later use this engine, but the engine itself only builds auditable analytical variables from stable HDW sources using explicit study-specific definitions.

Status: this document is the target design contract. It states the destination vocabulary even where the current experimental code still carries migration-era names or envelopes. Transitional shipped surfaces such as `binary_output()` / `number_output()`, public `decision` / `decision_state`, and role-tagged audit rows should be treated as migration gaps unless a later design decision revalidates them. Keep shipped-vs-target progress in `MIGRATION.md` or `HANDOFF.md`, not by weakening this contract.

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
    -> defines unit, anchor, window, output, combine, and audit behavior

RUNTIME LAYER
  run_variable(variable_spec, runtime)
    -> binds sources, loads data, executes channels, combines results,
       and returns values + audit/provenance
```

Core inheritance rule:

``` text
concept_spec supplies named channel defaults.
variable_spec activates selected channels.
use_channel() inherits by default.
any field supplied in use_channel() replaces the inherited field for that variable only.
unlisted concept channels are not used.
```

There is no selector-refinement semantics for now. A supplied selector replaces the inherited selector locally; it does not mutate the concept.

The general rule is:

> Channels observe, combiners calculate, researchers interpret.

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

The package may provide default source specifications for the known REDSaN/HDW structure. The operational source registry is `redsan::edsan_sources()`: it defines known modules/tables, identifier columns, point-versus-interval time semantics, query date keys, batch keys, and normalizers. Users may override default mappings when their dataset uses different column names or when they provide custom prepared views.

A source specification should use canonical role names. Raw column names remain source-specific; role names should not.

Common roles (not exhaustive):

``` text
subject_id
event_id
source_item_id
source_row_id
date
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

`source_spec` also carries source metadata that is not a payload role:

``` text
module
table
identifiers
source_time_kind
source_time_start
source_time_end
query_date_keys
default_batch_key
normalizer
```

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

Identifier spine: for default REDSaN/HDW sources, patient-level and stay/event-level linkage can rely on `PATID`, `EVTID`, and the mapped `source_item_id` being present; no defensive missing-id semantics are needed for those sources. Preserve the triplet in prepared views because it supports linkage and provenance. A custom non-HDW source may still need an explicit `source_spec` caveat if it cannot satisfy the same role contract. These identifiers are not the same thing as LLM `evidence_id`s.

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
    date           = "DATEACTE",
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
    date           = "DATEXAM",
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
    date           = "RECDATE",
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

The channel constructor implies the emitted signal shape. Users do not normally declare `emits` or `produces`.

Example:

``` r
diabetes <- concept_spec(
  name = "diabetes",

  channels = list(
    pmsi_diag_e10_e14 = code_channel(
      source = "pmsi_diag",
      selector = icd10("^E1[0-4]")
    ),

    text_diabetes_mentions = text_channel(
      source = "documents",
      selector = lucene_query("diabete OR diabetique OR insulinotherapie OR insuline"),

      default_method = llm_after_lucene(
        candidates = candidate_selection(
          arrange = arrange(desc(n_query_hits), desc(document_date)),
          limit = 20
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

    glucose_measurements = lab_channel(
      source = "biology",
      selector = analyte("GLU.GLU")
    ),

    hba1c_measurements = lab_channel(
      source = "biology",
      selector = analyte("HBA1C")
    ),

    antidiabetic_prescriptions = code_channel(
      source = "prescriptions",
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

> In this study, for this unit, using these channels, in this time window or event scope, with these extraction/reduction/transformation/combination rules, produce this output variable.

It declares:

``` text
name
concept
unit
anchor
time window or event scope
selected channels
per-channel activation options
retrieval/extraction method
reducers
transforms
combination rule
output type
absence/audit policy
audit requirements
```

Only channels listed in `channels` are activated. If a concept has three possible channels and the variable activates only two, the third is ignored.

``` r
diabete_pre_anchor <- variable_spec(
  name = "diabete_pre_anchor",
  concept = diabetes,

  unit = "PATID",
  anchor = "inclusion_date",
  window = period(anchor - 365, anchor),

  channels = list(
    pmsi_diag_e10_e14 = use_channel(),
    text_diabetes_mentions = use_channel()
    # lab_channel not invoked
  ),

  output = bin_output(),
  combine = "pmsi_diag_e10_e14 | text_diabetes_mentions"
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

  unit = "PATID",
  anchor = "inclusion_date",
  window = period(anchor - 365, anchor),

  channels = list(
    text_diabetes_mentions = use_channel(
      selector = lucene_query("diabete type 2 OR DNID OR insuline"),

      method = llm_after_lucene(
        candidates = candidate_selection(
          arrange = arrange(desc(document_date)),
          limit = 50
        ),

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
  source = NULL,     # optional local replacement, if allowed
  selector = NULL,   # optional local replacement
  method = NULL,     # optional execution/extraction method
  reducer = NULL,    # optional structured-value reducer
  transform = NULL   # optional value transformation
)
```

Method-specific parameters live inside the method. For example, prompt, structured-output type, candidate-selection rule, and response-to-hit mapping belong inside `llm_after_lucene()`, not as global `use_channel()` parameters.

## 7. Units, anchors, windows, and linkage

The unit defines the task universe and output grain: what one output row represents.

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

The unit is first-class because many errors come from measuring the right signal at the wrong grain.

For example, `unit = "PATID"` means one output row per patient in the supplied task universe. It does not imply access to the patient's complete real-world history. It means “across all patient-level data supplied to this run,” further restricted by anchor/window.

``` text
unit = PATID
window = anchor - 365 -> anchor

meaning:
  one row per patient in the supplied task universe
  consider only evidence present in the supplied data
  restrict evidence to the 365 days before the anchor
```

Channels expose linkage affordances; the `variable_spec` decides which unit, anchor, and window to use. The engine checks whether selected channels can be mechanically linked to the requested unit/window.

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

### Grain is the `unit`; `combine` is grain-agnostic

The variable's `unit` picks the task universe. That is what makes the same expression mean different things at different grains:

``` text
combine = "text_diabet & glucose"
```

At patient grain, this means:

``` text
patients with a diabetes text hit and a glucose result within the supplied patient-level task universe/window
```

At stay grain, it means:

``` text
stays with a diabetes text hit and a glucose result during the same stay-level task universe/window
```

`combine` never takes a grain parameter. It is set algebra over the current task universe, and the `unit` sets that universe.

Current migration gap: event/stay-grain eligibility is not uniformly implemented across all executors yet. The text path can already resolve event-scoped eligibility for event-linked document variables; structured code and lab executors still need explicit event/stay linkage support. That extension should be additive because `EVTID` is invariant across HDW rows — the gap is executor wiring, not missing identifiers.

------------------------------------------------------------------------

## 8. Channel hits, outputs, and lab semantics

A channel activation is the variable-specific use of a concept channel. It may replace inherited fields, choose an extraction method, set a reducer, request an output shape, or define audit requirements.

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

A lab channel has two faces:

``` text
membership face: hit TRUE/FALSE/NA, usable in bin_output() and combine expressions
value face: measurement values from matched rows, usable by num_output() and reducers such as max_value()
```

Thus a structured lab channel can support either membership output or numeric output depending on the variable activation.

### Output shapes and inference

Target output shapes:

``` text
bin_output() produces observed membership:
  hit == TRUE  -> value = 1
  hit == FALSE -> value = 0
  hit == NA    -> value = 0, with incomplete/partial coverage preserved in audit
num_output()     numeric value
str_output()     unconstrained string
cat_output()     categorical value
struct_output()  fixed-schema multi-field record; one task -> one record
```

The value type is inferred from the selected channel where possible:

``` text
lab measurement with numeric values -> num_output()
structured code/act                -> str_output()
text channel                        -> shape and category levels from ellmer type or other method
```

Explicit `output =` is mainly an override, especially `bin_output()` when the researcher wants membership instead of a structured channel's inferred value.

### Dispatch and validity

`combine` means hit algebra over channel hit sets and produces `0/1`. Single-channel non-boolean shaping is output assembly with `combine = NULL`, dispatched by output shape.

Validity matrix:

``` text
channels  combine      output                       valid?
>=1       expression   bin_output()                 yes   hit algebra -> 0/1
1         NULL         bin_output()                 yes   value = that channel's hit
1         NULL         num/str/cat/struct_output()  yes   single-channel output assembly
>=2       NULL         any                          no    no reconcile rule
any       expression   non-binary output            no    hit algebra only makes 0/1
1         expression   any                          no    use NULL
any       any          missing and not inferable     no    cannot validate shape
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

Candidate selection can use an `arrange`-like rule over standardized candidate columns:

``` r
candidate_selection(
  arrange = arrange(desc(n_query_hits), desc(document_date)),
  limit = 20
)
```

This means:

``` text
1. run the Lucene-like query
2. build the candidate table
3. order candidates by the declared arrange rule
4. keep the first `limit` candidates
5. pass selected candidates to the extraction method
```

No implicit Lucene score is assumed unless the backend actually provides one or the engine explicitly defines one.

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
  candidates = candidate_selection(
    arrange = arrange(desc(n_query_hits), desc(document_date)),
    limit = 20
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

## 10. Boolean hit-set algebra

The public boolean-combine surface is a bare string expression over activated channel names:

``` r
combine = "(transplant_act | transplant_status) & !dialysis_signal"
```

Boolean logic is set algebra over explicit hit sets, not clinical ontology and not Kleene truth logic. A hit set is the set of task ids matched by one channel activation under the current `variable_spec`.

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
  task_id
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
unit: PATID
anchor: inclusion_date
window: anchor - 365 -> anchor

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
     date           = RECDATE
   selector:
     lucene_query("diabete OR diabetique OR insulinotherapie OR insuline")
   method:
     llm_after_lucene
       candidates:
         arrange = desc(n_query_hits), desc(document_date)
         limit = 20
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

combine:
  pmsi_diag_e10_e14 | text_diabetes_mentions
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

### Testing philosophy

The test suite should protect semantic contracts, not incidental implementation structure.

A contract test should describe observable behavior that must remain true even if internal operators, filenames, wrappers, or object layouts change. For example: a channel hit means selector membership at the declared unit/grain; combine evaluates hit-set algebra over activated channels; output declares the final value shape; channel_coverage carries evaluability.

A regression test may protect a bug fix tied to a current implementation detail, but it should be labeled as such and should not be mistaken for a design invariant.

A migration test may temporarily protect old spellings or transitional compatibility, but it should be easy to delete when the migration ends.

Before locking a validity matrix or public API rule, test it against at least one code channel, one text channel, one thresholded lab channel, one unthresholded lab channel, one patient-grain variable, and one event/stay-grain variable. This prevents the implementation from optimizing around a narrow current use case and freezing a local maximum.

### The protected test floor (ratified 2026-06-30)

After pruning ~400 tests down to a handful, the suite was re-derived from a single gate: in this phase a test earns its place only if the failure it catches is (a) **silent**, (b) on a deterministic invariant we have actually **decided**, and (c) **invisible to the real validation** — real-model-on-real-data runs reviewed by a physician. The LLM node carries the clinical risk and is human-reviewed by design, so tests cannot adjudicate its answers; loud failures self-surface on the next real run. The suite is therefore a set of tripwires on decided silent regressions plus a refactoring safety net — it is not the validation story.

The **protected floor** (do not delete without re-opening this decision):

- `hitset-expr #1` — observed hit-set algebra: `A & !B` with `B` unavailable resolves to included / value 1 / coverage partial (deliberate, non-Kleene; a regression silently flips cohort membership).
- `hitset-expr #2` — combine grammar is fail-closed: function calls, non-activated channels, and activated-but-unused channels are rejected.
- `diabetes #4` — the `run_variable()` spine is concept-agnostic: each channel's own selector drives a neutral executor (a hard-wired selector would silently mis-measure every new concept).
- `smoking #3` — D1 citation keep-and-flag: a value grounded by ≥1 real id is kept and flagged when the model also cites an invented id; an only-invented citation is rejected.
- `anastomoses #2` — field-level acceptance: a valid field survives an invalid sibling and routes to review (the §9 accept-only-grounded promise made concrete).

Everything outside the floor is cuttable without ceremony. The coverage matrix above is a **design-freezing discipline applied once, when a validity-matrix or public-API rule is locked** — not a standing requirement that each shape keep a permanent test; by that reading the declined thresholded-lab test is not a gap. Provenance / source-traceability is the one open floor *candidate*: it becomes a floor test only once a concrete produced-dataset provenance object is ratified; until then evidence refs, `selected_channels`, and the source-role mapping cover the pieces that exist.

Ratified by the owner with Claude and Codex independently concurring on this five-test core.

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
max_value()
closest_before_anchor()
llm_after_lucene()
any_positive()
threshold_binary()
collect_fields()
```

Example snippet-style template:

``` r
# Template snippet: baseline documented diabetes status before anchor
# Copy this into the study protocol and edit explicitly.

diabete_pre_anchor <- variable_spec(
  name = "diabete_pre_anchor",
  concept = diabetes,

  unit = "PATID",
  anchor = "inclusion_date",
  window = period(anchor - 365, anchor),

  channels = list(
    pmsi_diag_e10_e14 = use_channel(),
    text_diabetes_mentions = use_channel()
  ),

  output = bin_output(),
  combine = "pmsi_diag_e10_e14 | text_diabetes_mentions"
)
```

------------------------------------------------------------------------

## 14. Minimal examples

### 14.1 Stable concept library

``` r
diabetes <- concept_spec(
  name = "diabetes",

  channels = list(
    pmsi_diag_e10_e14 = code_channel(
      source = "pmsi_diag",
      selector = icd10("^E1[0-4]")
    ),

    text_diabetes_mentions = text_channel(
      source = "documents",
      selector = lucene_query("diabete OR diabetique OR insulinotherapie OR insuline"),

      default_method = llm_after_lucene(
        candidates = candidate_selection(
          arrange = arrange(desc(n_query_hits), desc(document_date)),
          limit = 20
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

    glucose_measurements = lab_channel(
      source = "biology",
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

  unit = transplant_unit(),
  anchor = transplant_date(),
  window = before_anchor(days = 3650),

  channels = list(
    pmsi_diag_e10_e14 = use_channel(),
    text_diabetes_mentions = use_channel()
  ),

  output = bin_output(), # Because output = bin_output(), the LLM response is collapsed into observed hit membership using positive_hit_when. To keep the LLM response itself as the analytical value, use cat_output() or struct_output() instead.
  combine = "pmsi_diag_e10_e14 | text_diabetes_mentions"
)
```

This variable asks whether either activated channel has an observed diabetes hit before transplant. It does not use glucose measurements because the protocol did not activate that channel.

### 14.3 Local override of concept defaults

``` r
diabete_type2_pre_greffe <- variable_spec(
  name = "diabete_type2_pre_greffe",
  concept = diabetes,

  unit = transplant_unit(),
  anchor = transplant_date(),
  window = before_anchor(days = 3650),

  channels = list(
    text_diabetes_mentions = use_channel(
      selector = lucene_query("diabete type 2 OR DNID OR antidiabetique"),

      method = llm_after_lucene(
        candidates = candidate_selection(
          arrange = arrange(desc(document_date)),
          limit = 50
        ),

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

  unit = surgery_unit(),
  anchor = surgery_date(),
  window = days_after(0, 2),

  channels = list(
    glucose_measurements = use_channel(
      reducer = max_value()
    )
  ),

  output = num_output()
)
```

This variable uses the value face of the lab channel and returns a numeric summary.

### 14.5 Single-channel membership variable

``` r
has_glucose_measurement <- variable_spec(
  name = "has_glucose_measurement",
  concept = diabetes,

  unit = patient_unit(),

  channels = list(
    glucose_measurements = use_channel()
  ),

  output = bin_output()
)
```

This variable asks only whether at least one in-scope glucose measurement exists.

### 14.6 Thresholded lab membership variable

``` r
has_hyperglycaemia <- variable_spec(
  name = "has_hyperglycaemia",
  concept = diabetes,

  unit = patient_unit(),

  channels = list(
    glucose_measurements = use_channel(
      selector = analyte_value("GLU.GLU", gt = 11, unit = "mmol/L")
    )
  ),

  output = bin_output()
)
```

This variable asks whether at least one in-scope glucose result above the threshold exists.

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
12. The unit defines the output grain and task universe. `combine` is grain-agnostic.
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
