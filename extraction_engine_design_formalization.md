# Extraction Engine — Formalized Design Notes

## 1. Project goal

This project is an HDW-aware, protocol-agnostic extraction framework for building study analytical variables from a stable hospital data warehouse structure.

The goal is not to build a generic chatbot, a generic LLM wrapper, or a one-off D0740/D0840 extractor.

The goal is:

> A framework where researchers define study-specific analytical variables by selecting concepts, signal channels, units, time windows, extraction methods, reducers, transformations, output types, and absence policies. The engine executes those definitions against known HDW sources and returns auditable analytical variables.

The engine should not remove clinical or methodological judgment. It should prevent hidden judgment.

Researchers remain responsible for the scientific validity of the protocol and operational definitions. The engine is responsible for explicit execution, traceability, reproducibility, and mechanical consistency.

A central boundary:

> The engine owns execution and traceability. The researcher owns interpretation.

The engine should avoid introducing new semantic layers unless they are explicitly requested by the protocol. Whenever possible, it should expose source contributions rather than infer confidence levels.

Concretely at the LLM boundary, the engine does **not** promise that the model's output is accurate — that is reviewed. It promises a deterministic pipeline that selected the candidates, called the model under a controlled schema, accepted only the grounded/valid parts, routed failures and ungrounded claims to review, and preserved evidence, status, and provenance. See §11.

---

## 2. Core mental model

The framework separates major responsibilities:

```text
source_spec
  maps raw HDW structures to canonical source roles

concept_spec
  declares available signal channels for a clinical/research concept

channel
  one source-specific signal route; resurfaces information without clinical interpretation

variable_template
  concept-specific parametric quickstart

variable_spec
  concrete protocol-specific executable analytical variable definition

operators/helpers
  generic pieces used inside variable_specs/templates

runtime
  supplies actual data, model/provider settings, execution parameters, and environment
```

The key distinction is:

```text
concept_spec defines possible signals.
variable_spec defines the analytical variable requested by the protocol.
```

Or more explicitly:

```text
concept_spec answers:
  "Where can signals related to this concept be found?"

variable_spec answers:
  "How should those signals be transformed into the analytical variable required by this protocol?"
```

A concept is not a final diagnosis, phenotype, or analytical variable. It is a reusable collection of related signal channels inside the HDW.

A variable is where protocol-specific choices are made.

---

## 3. source_spec

A `source_spec` describes how to read and normalize one HDW source.

It maps raw columns to canonical roles. Study-facing code should not need to know raw HDW column names.

Example roles:

```text
subject_id
event_id
stay_id
document_id
date
interval_start
interval_end
text
code
analyte
value
unit
native_ref
```

Examples:

```text
documents source:
  subject_id = PATID
  event_id = EVTID
  document_id = ELTID
  text = RECTXT
  date = DATE_DOC
  native_ref = PATID + EVTID + ELTID

biology source:
  subject_id = PATID
  event_id = EVTID
  analyte = TYPEANA
  value = NUMRES
  unit = UNITE
  date = DATEXAM
  native_ref = PATID + EVTID + ELTID

PMSI diagnosis source:
  subject_id = PATID
  stay_id = RSS_ID
  code = CIM10
  interval_start = DATE_ENTREE
  interval_end = DATE_SORTIE
  native_ref = RSS_ID + diagnosis row identifier
```

The `source_spec` knows the warehouse. It does not know the study protocol.

---

## 4. concept_spec

A `concept_spec` is a stable, reusable concept-level signal map.

It answers:

> For this concept, what signal channels exist in the HDW, and how can each channel resurface candidate evidence?

Example:

```r
diabetes <- concept_spec(
  name = "diabetes",

  channels = list(
    pmsi_diag_e10_e14 = code_channel(
      source = "pmsi_diag",
      selector = icd10("^E1[0-4]"),
      produces = "code_hit"
    ),

    text_diabetes_mentions = text_channel(
      source = "documents",
      selector = lucene_query("diabete OR diabetique OR insulinotherapie OR insuline"),
      produces = "text_candidate"
    ),

    glucose_measurements = lab_channel(
      source = "biology",
      selector = analyte("GLU.GLU"),
      produces = "numeric_measurement"
    ),

    hba1c_measurements = lab_channel(
      source = "biology",
      selector = analyte("HBA1C"),
      produces = "numeric_measurement"
    ),

    antidiabetic_prescriptions = medication_channel(
      source = "prescriptions",
      selector = drug_class("antidiabetic"),
      produces = "drug_exposure"
    )
  )
)
```

This object does not say whether the patient has diabetes.

It says:

> Diabetes-related information may appear through these channels in this HDW.

The concept layer resurfaces information. It does not interpret scientific meaning.

Concepts can be broad if they remain signal catalogs. For example, `smoking` may later contain text mentions, coded tobacco-related diagnoses, pack-year mentions, or cessation mentions. A concept should not be narrowed into a single variable output shape unless the observation itself is genuinely the reusable concept.

---

## 5. Channel

A channel is one source-specific route for resurfacing signals related to a concept.

A channel should define:

```text
name
source
selector
native grain
produced signal shape
required roles
linkage affordances
native reference fields
optional default extraction strategy/schema
```

A channel does not decide final clinical truth.

Examples:

```text
pmsi_diag_e10_e14 channel:
  source: pmsi_diag
  selector: ICD10 code matching E10-E14
  native grain: diagnosis row
  produces: code_hit
  roles: subject_id, stay_id, interval_start, interval_end, code, native_ref

glucose_measurements channel:
  source: biology
  selector: TYPEANA == GLU.GLU
  native grain: lab result
  produces: numeric_measurement
  roles: subject_id, event_id, date, value, unit, native_ref

text_diabetes_mentions channel:
  source: documents
  selector: Lucene query
  native grain: document / sentence / extracted assertion
  produces: text_candidate or llm_assertion depending on variable_spec activation
  roles: subject_id, event_id, document_id, date, text, native_ref
```

Channels resurface information. They do not judge whether the information is clinically sufficient.

The engine may validate mechanical compatibility:

```text
Does this channel provide dates if a time window is requested?
Does this channel provide values if a numeric reducer is requested?
Does this channel provide text if an LLM extractor is requested?
Can this evidence be linked to the selected study unit?
Does it expose native references for audit?
```

The engine should not validate scientific appropriateness:

```text
Does glucose prove diabetes?
Does absence of a PMSI code mean no diabetes?
Does no text mention mean no disease?
```

Those are protocol/researcher choices.

### Channel definition versus channel activation

A channel definition lives in `concept_spec`.

A channel activation lives in `variable_spec`.

Example:

```r
# Concept-level route
glucose_measurements = lab_channel(
  source = "biology",
  selector = analyte("GLU.GLU"),
  produces = "numeric_measurement"
)

# Variable-level use of that route
channels = list(
  glucose_measurements = use_channel(reducer = max_value())
)
```

The reducer belongs to the variable's activation of the channel, not to the reusable channel definition.

---

## 6. variable_spec

A `variable_spec` is the concrete, executable study-specific definition of one analytical variable.

It answers:

> In this study, for this unit, using these channels, in this time window or event scope, with these extraction/reduction/transformation/combination rules, produce this output variable.

It should explicitly declare:

```text
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
absence policy
audit requirements
```

Example:

```r
diabete_pre_greffe <- variable_spec(
  name = "diabete_pre_greffe",
  concept = concepts$diabetes,

  unit = transplant_unit(),
  anchor = transplant_date(),
  window = before_anchor(days = 3650),

  channels = list(
    pmsi_diag_e10_e14 = use_channel(),
    text_diabetes_mentions = use_channel(
      method = llm_after_lucene(top_n = 20),
      prompt = diabetes_documented_status_prompt()
    )
  ),

  output = binary_output(),
  combine = any_positive(),
  absence_policy = open_world()
)
```

Another variable using the same concept:

```r
perioperative_max_glucose <- variable_spec(
  name = "perioperative_max_glucose",
  concept = concepts$diabetes,

  unit = surgery_unit(),
  anchor = surgery_date(),
  window = days_after(0, 2),

  channels = list(
    glucose_measurements = use_channel(
      reducer = max_value()
    )
  ),

  output = number_output(),
  absence_policy = missing_if_no_measurement()
)
```

Same concept. Different analytical variable. Different selected channels. Different output.

---

## 7. variable_template

A `variable_template` is a concept-specific parametric quickstart.

It is analogous to a parametric 3D printing file:

```text
variable_template
  = reusable parametric base model

variable_spec
  = concrete configured print for one protocol
```

Important: variable templates are concept-specific. They should not become generic operational patterns detached from concepts.

Valid examples:

```text
diabetes_baseline_status_template
diabetes_glycaemic_control_template
diabetes_perioperative_hyperglycaemia_template

smoking_status_around_anchor_template
active_smoking_binary_template

dialysis_status_before_anchor_template
incident_dialysis_after_anchor_template

recipient_anastomoses_template
```

Invalid or misplaced examples:

```text
max_value()
closest_before_anchor()
llm_after_lucene()
any_positive()
threshold_binary()
documented_status()
collect_fields()
```

These are operators/helpers, not variable templates.

A variable template should provide a useful starting configuration for a common concept-specific variable. It may set defaults, expose parameters, and generate a concrete `variable_spec`.

Example:

```r
diabetes_baseline_status_template <- variable_template(
  concept = concepts$diabetes,

  parameters = list(
    name,
    unit,
    anchor,
    window = before_anchor(),
    channels = c("pmsi_diag_e10_e14", "text_diabetes_mentions"),
    text_method = llm_after_lucene(top_n = 20),
    output = binary_output(),
    combine = any_positive(),
    absence_policy = open_world()
  ),

  build = function(params) {
    variable_spec(
      name = params$name,
      concept = concepts$diabetes,
      unit = params$unit,
      anchor = params$anchor,
      window = params$window,
      channels = list(
        pmsi_diag_e10_e14 = use_channel(),
        text_diabetes_mentions = use_channel(method = params$text_method)
      ),
      output = params$output,
      combine = params$combine,
      absence_policy = params$absence_policy
    )
  }
)
```

The resulting object is a `variable_spec`.

A `variable_spec` may also be written directly when no template exists. Some direct variable specs will never become templates. Others may later be promoted to templates if the pattern recurs.

Lifecycle:

```text
direct variable_spec
  → if repeated/stabilized
  → promoted to concept-specific variable_template
  → reused to generate future variable_specs
```

---

## 8. Operators and helpers

Operators/helpers are reusable low-level pieces used inside `variable_spec` or `variable_template`.

Examples:

```text
before_anchor()
around_anchor()
days_after()
max_value()
min_value()
closest_before_anchor()
first_event()
last_event()
any_positive()
hit_set_difference()
threshold_binary()
lucene_only()
llm_after_lucene()
regex_extract()
categorical_output()
documented_status()
fields_output()
collect_fields()
```

They are not variable templates.

They are implementation primitives.

Rule:

```text
Generic reusable computational pieces are operators/helpers.
Concept-specific reusable quickstarts are variable_templates.
Concrete study-specific definitions are variable_specs.
```

Operators should primarily implement researcher-defined analytical rules. They should avoid introducing additional clinical interpretation beyond the rule selected in the variable definition.

For example, if a researcher defines:

```text
dialysis = ICD10 OR CCAM OR text
```

then the engine should execute that rule and expose which channels had signals. It should not automatically invent labels such as "uncorroborated", "possible", or "weak evidence" unless such labels are explicitly part of the variable definition.

### Boolean hit-set expressions (the deterministic boolean layer)

The engine has a real deterministic boolean layer, not a special-case `NOT`. The **public boolean-combine surface is a bare string expression** over channel names:

```r
combine = "(transplant_act | transplant_status) & !dialysis_signal"
```

Boolean logic is **set algebra over explicit hit sets, not clinical ontology**. A hit set is the set of ids (task/patient ids) matched by one signal definition — a channel under a `variable_spec`. The operators are plain set algebra over those hit sets:

```text
A | B  = union(A, B)
A & B  = intersect(A, B)
!A     = complement of A relative to the current task universe
```

`!dialysis_signal` therefore means "**not in the `dialysis_signal` hit set within the current task universe**", under the selected `dialysis_signal` definition. It does **not** mean "clinically no dialysis". So `!` is allowed as set exclusion — it subtracts one explicit result set from another, it does not negate a disease — and must not be over-policed.

**Grammar.**

```text
allowed   : channel-name symbols (matching the variable's activated channels),
            the operators | & ! , and parentheses
rejected  : function calls, arithmetic, comparison operators, literals/constants,
            unknown symbols (a name not among the activated channels), and any
            malformed expression
```

Referenced channels must be exactly the variable's activated channels; an unknown symbol or an activated-but-unused channel is a build-time error.

**Observed hit-set algebra (the decision).** Each channel produces a per-task hit that is one of `TRUE` = observed hit, `FALSE` = ascertained no-hit, `NA` = unavailable / unevaluable. The **final cohort decision uses observed set algebra, not Kleene truth logic**: a task is a member of a channel's set **iff `hit == TRUE`**, so both `FALSE` and `NA` mean "no observed hit" (non-member). The decision is therefore always determined:

```text
A & !B   with A = TRUE (hit), B = NA (unavailable)
  ->  A's observed set contains the task; B's observed set does not.
  ->  decision = included, value = 1, channel_coverage = partial
  NOT decision = undetermined.
```

The reasoning: `A NOT B` is `A` minus the **observed** B hits. If B produced no hit, the task stays in `A`. The uncertainty about B belongs in the audit (`channel_coverage`, membership), **not** in the final set operation. NA must not silently flip the decision. (A strict epistemic mode that *does* propagate NA into the decision is a deliberate future extension, gated behind an explicit flag — it is not the default.)

The envelope therefore carries three separate fields, resolving an earlier conflation where one `ascertainment` field meant both "is the decision determined" and "were the channels evaluable":

```text
decision          included / excluded   (observed set-algebra result; binary, determined)
decision_state    determined            (always, in the default observed mode)
channel_coverage  complete / partial / failed
                    complete = every selected channel was evaluable (TRUE/FALSE)
                    partial  = a selected channel was unavailable / unusable (NA)
                    failed   = a selected channel errored
```

`value` is therefore always `0` / `1` for a boolean variable; the "some channel was unavailable" caveat lives in `channel_coverage`, not in a missing value. The engine still keeps two things distinct (invariants #13/#14 — never infer clinical absence from silence): an **observed non-hit** (`FALSE`, the selected definition was evaluated and not matched) versus an **unavailable source** (`NA`). The closed-world clinical label ("patients with the act and no dialysis") is only honest if the `variable_spec` explicitly declares the selected exclusion definition sufficient for it; otherwise the result is "patients with the act and **no dialysis hit**, coverage permitting".

**Overlap audit (Venn / UpSet).** The audit is not reduced to in/out. Alongside `values` it emits a **membership long-form** (`task_id`, `channel`, `role` in the expression = asserted/negated/mixed, `hit` = TRUE/FALSE/NA preserved, `processing_state`, `evidence_refs` for hits) and an **overlap summary** that groups tasks by their membership pattern across the expression channels (per-channel state columns with NA preserved + `pattern` + count + the pattern-determined `decision`, `decision_state`, and `channel_coverage`). The overlap summary is directly consumable by ggupset / UpSetR; the scientifically useful part is how the source hit sets overlap or fail to overlap, not just the final flag.

`R/hitset.R` is the pure core (parser, grammar check, role derivation, Kleene evaluator, overlap); `R/run_variable.R` attaches per-channel status + evidence provenance.

**`hit_set_difference()` is sugar, not a parallel system.** `hit_set_difference(include = a, exclude = b)` lowers to the string expression `a & !b` (with OR-within-role unions for multiple channels) and is evaluated by the same machinery. It exists only as a convenience for the common "include minus exclude" case; the string expression is the primary, documented API. There is one boolean mental model, not two.

---

## 9. Unit and linkage

The unit defines what one output row represents.

Examples:

```text
patient
stay
surgery
transplant
consultation
pregnancy
donor-recipient pair
timepoint
```

The unit should be first-class because many errors come from measuring the right concept at the wrong grain.

Channels should expose linkage affordances, not protocol interpretation.

Example:

```text
biology channel:
  native grain = lab result
  linkable by subject_id
  has measurement date
  may have event_id

PMSI diagnosis channel:
  native grain = diagnosis row
  linkable by subject_id and stay_id
  has stay interval

document channel:
  native grain = document / assertion
  linkable by subject_id, event_id, document_id
  has document date
```

The `variable_spec` decides which unit to use and how to anchor/window the evidence.

The engine checks whether selected channels can be mechanically linked to the requested unit/window.

Some variables are event-scoped rather than date-windowed. For example, operative-report anastomoses may be linked by subject + surgical event and declare `window = NULL`. The runner should not force a misleading placeholder date window onto event-scoped variables.

---

## 10. Absence, silence, and source contribution

Absence semantics are hard and must not be collapsed silently.

Channels and execution should preserve statuses such as:

```text
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

The `variable_spec` decides how these statuses become:

```text
TRUE
FALSE
NA
unknown
needs_review
```

Example principle:

```text
The engine reports no_candidate.
The variable_spec decides whether no_candidate means FALSE, NA, unknown, or needs_review.
```

Silence from one channel must never be interpreted as contradiction with another channel unless the variable definition explicitly requests such logic.

For example:

```text
ICD10/CCAM dialysis signal present
documents no_candidate
```

should normally be represented as:

```text
final_value = value produced by the researcher-selected rule
positive_sources = ICD10/CCAM channel
silent_sources = documents
evidence = coded row(s)
channel_status = documents no_candidate
```

The engine should not automatically infer "uncorroborated", "weak yes", or "possible dialysis" unless the `variable_spec` explicitly defines such labels.

The primary responsibility of the engine is not to estimate certainty.

Its responsibility is to expose:

```text
which channels were activated
which channels produced evidence
which channels produced no candidate
which channels were unavailable
which evidence supports positive outputs
which rule produced the final value
```

Clinical interpretation of that evidence belongs to the researcher.

---

## 11. Text and LLM extraction

For text channels, candidate retrieval and extraction are separate concerns.

A text channel may define:

```text
Lucene query
document source
text roles
native refs
candidate retrieval shape
optional default extractor/schema
```

The `variable_spec` decides whether to use:

```text
lucene_only
llm_after_lucene
regex extraction
whole-corpus query such as *
top-N retrieval
specific prompt/schema
```

The concept or channel may provide a default extractor/schema when the default answer shape is concept-specific. The variable may override the extraction method or schema when a protocol needs a different text signal.

The LLM should return evidence-grounded outputs where relevant, for example:

```text
value
evidence sentence
native document reference
reasoning/rationale
status
```

The engine should preserve traceability of:

```text
Lucene query
retrieved candidates
prompt/schema
model/provider/settings
LLM response
parsed output
evidence refs
citation warnings
```

Candidate retrieval recall is a known ceiling. This is acceptable and must remain visible. If needed, researchers can use broader queries, including `*`, to retrieve larger corpora.

A useful parser behavior for evidence IDs:

```text
real evidence id + fabricated evidence id
  → keep value, keep real evidence, surface citation_warning

only fabricated evidence id
  → invalid / needs_review
```

This keep-and-flag rule is now uniform across the text parsers (smoking, anastomoses, and the shared binary-presence definition), implemented once in a shared `resolve_cited_ids()` helper rather than re-derived per concept. Surfacing the flag into the higher combine/envelope paths stays incremental: the single-channel text paths (`documented_status`, `collect_fields`) carry it; the multi-source OR path (`any_positive`) computes it per channel but does not yet hoist it into the combined source status, because doing so would extend the generic combine contract with no current consumer.

### What the engine promises at the LLM boundary

The LLM call is the **only** non-deterministic node in the pipeline; everything else (retrieval and eligibility, the structured code/lab measures, the combine operators, the absence policy, and the audit envelope) is deterministic. That node is human-reviewed by design — the researcher never assumes the model is correct.

So the engine does **not** promise:

```text
the LLM output is accurate.
```

The engine **does** promise that, around that one call, the deterministic pipeline:

```text
1. selected the candidates                         (retrieval + eligibility)
2. called the model under a controlled schema      (grammar-enforced JSON)
3. accepted only the grounded / valid parts        (field-level acceptance)
4. routed failures or ungrounded claims to review  (needs_review, citation_warning)
5. preserved evidence / status / provenance        (the audit envelope)
```

Consequently, accuracy / gold-label scoring of the model is **out of scope** for the engine's guarantees. A run where the model extracted little, abstained (`not_documented`), or made an ungrounded claim that was routed to `needs_review` is the pipeline working as promised, not a failure. The engine's job at this boundary is a controlled, fully auditable, reviewable call — not a correct one. Validation therefore targets the *mechanism* (does the deterministic pipeline run end-to-end and emit a reviewable, grounded envelope), not the model's answers.

---

## 12. Validation and review

The framework should support review, but early development should not over-focus on metrics before the tool works.

Physicians/researchers are expected to review outputs, especially LLM-derived variables.

The immediate priority is that outputs are reviewable:

```text
final value
source/channel used
evidence sentence or source row
native refs
LLM reasoning when applicable
status/failure information
field-level validity when relevant
citation_warning when relevant
```

Later, the framework can add:

```text
manual adjudication workflows
disagreement tracking
retry policies
performance metrics
gold-label comparisons
```

These are important but not the first milestone.

---

## 13. Provenance and versioning

Versioning is annoying but also a strength.

A produced dataset should eventually be traceable to:

```text
source_spec version
concept_spec version
variable_template version if used
variable_spec version
code commit
source export date
runtime settings
model/provider
prompt/schema version
retrieval query
execution timestamp
```

The engine owns traceability. The researcher owns interpretation.

---

## 14. Out of scope

The tool does not aim to become a full clinical trial or study-management platform.

It does not own:

```text
full protocol design
scientific justification
cohort governance
clinical trial management
physician workflow management
global study lifecycle management
```

A future higher layer could integrate this extraction engine into a broader research platform, but that is not the current scope.

The current scope is:

> Build auditable analytical variables from stable HDW sources using explicit, reusable, study-specific definitions.

---

## 15. Design invariants

These are the core principles future agents should not violate.

```text
1. The engine should not remove judgment. It should prevent hidden judgment.

2. The engine owns execution and traceability. The researcher owns interpretation.

3. The engine should avoid introducing new semantic layers unless they are explicitly requested by the protocol.

4. source_spec knows the warehouse.

5. concept_spec declares available signal channels for a clinical/research concept.

6. A concept is a reusable signal-channel catalog, not a clinical truth object.

7. A channel resurfaces source-specific signals. It does not interpret their clinical meaning.

8. A channel definition lives in concept_spec; a channel activation lives in variable_spec.

9. variable_template is a concept-specific parametric quickstart, not a generic computation pattern.

10. variable_spec is the concrete executable study-specific analytical variable definition.

11. Generic reusable pieces such as reducers, windows, extraction methods, and combiners are operators/helpers, not variable templates.

12. No concept channel is used by default unless the variable_spec or template explicitly activates it.

13. Absence is never silently inferred. Execution statuses are preserved until variable_spec explicitly collapses them.

14. Silence from one channel is not contradiction with another channel unless the variable_spec explicitly defines such logic.

15. The final output type belongs to variable_spec.

16. Units and linkage are first-class because many errors come from measuring the right signal at the wrong grain.

17. LLM extraction must be evidence-grounded and auditable.

18. The framework should optimize for explicitness, reuse, source contribution reporting, and reviewability, not for hiding protocol choices.

19. The boolean combine surface is a string hit-set expression (`|` `&` `!` over channel names) evaluated as **observed** set algebra over explicit hit sets, not clinical ontology and not Kleene truth logic. A task is in a channel's set iff its hit is observed (`TRUE`); `FALSE` and `NA` are both non-members, and `!A` is complement within the task universe, not clinical negation. The final decision is always determined (included / excluded); an unavailable channel lowers `channel_coverage` (complete / partial / failed) and is preserved in the membership/overlap audit, but does **not** propagate into the decision (a strict NA-propagating mode is a future opt-in). Keep three fields separate: `decision` (the combine result), `decision_state` (determined / undetermined), `channel_coverage` (were the selected channels evaluable). Distinguish an observed non-hit from an unavailable source; never read silence as a closed-world clinical absence. `hit_set_difference()` is sugar that lowers to `a & !b`, not a parallel system.
```

---

## 16. Minimal examples

```r
# Stable concept library
diabetes <- concept_spec(
  name = "diabetes",
  channels = list(
    pmsi_diag_e10_e14 = code_channel(
      source = "pmsi_diag",
      selector = icd10("^E1[0-4]"),
      produces = "code_hit"
    ),
    text_diabetes_mentions = text_channel(
      source = "documents",
      selector = lucene_query("diabete OR diabetique OR insulinotherapie OR insuline"),
      produces = "text_candidate"
    ),
    glucose_measurements = lab_channel(
      source = "biology",
      selector = analyte("GLU.GLU"),
      produces = "numeric_measurement"
    )
  )
)

# Concept-specific quickstart
diabetes_baseline_status_template <- variable_template(
  concept = diabetes,
  defaults = list(
    window = before_anchor(),
    channels = c("pmsi_diag_e10_e14", "text_diabetes_mentions"),
    output = binary_output(),
    combine = any_positive(),
    absence_policy = open_world()
  )
)

# Concrete study-specific variable from template
diabete_pre_greffe <- variable_spec(
  template = diabetes_baseline_status_template,
  name = "diabete_pre_greffe",
  unit = transplant_unit(),
  anchor = transplant_date(),
  window = before_anchor(days = 3650),
  channels = list(
    pmsi_diag_e10_e14 = use_channel(),
    text_diabetes_mentions = use_channel(
      method = llm_after_lucene(top_n = 20),
      prompt = diabetes_documented_status_prompt()
    )
  )
)

# Different direct variable from same concept
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
  output = number_output(),
  absence_policy = missing_if_no_measurement()
)
```

This illustrates the central design:

```text
same concept_spec
different variable_specs
different selected channels
different units/windows
different outputs
```

A multi-source OR example should expose source contribution rather than infer confidence:

```r
dialysis_status <- variable_spec(
  name = "dialysis_status_before_anchor",
  concept = dialysis,
  unit = patient_unit(),
  anchor = inclusion_date(),
  window = before_anchor(),
  channels = list(
    pmsi_dialysis_codes = use_channel(),
    ccam_dialysis_acts = use_channel(),
    text_dialysis_mentions = use_channel(method = llm_after_lucene())
  ),
  output = binary_output(),
  combine = any_positive(),
  absence_policy = open_world()
)
```

The output should make clear whether the final value came from PMSI, CCAM, text, or several channels, and which selected channels were silent/unavailable.
