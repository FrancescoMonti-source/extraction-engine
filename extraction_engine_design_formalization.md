# Extraction Engine — Formalized Design Notes

## 1. Project goal

This project is an HDW-aware, protocol-agnostic extraction framework for building study variables from a stable hospital data warehouse structure.

The goal is not to build a generic chatbot, a generic LLM wrapper, or a one-off D0740/D0840 extractor.

The goal is:

> A framework where researchers define study-specific variables by selecting concepts, signal channels, units, time windows, extraction methods, reducers, transformations, output types, and absence policies. The engine executes those definitions against known HDW sources and returns auditable analytical variables.

The engine should not remove clinical or methodological judgment. It should prevent hidden judgment.

Researchers remain responsible for the scientific validity of the protocol and operational definitions. The engine is responsible for explicit execution, traceability, reproducibility, and mechanical consistency.

---

## 2. Core mental model

The framework separates four major responsibilities:

```text
source_spec
  maps raw HDW structures to canonical source roles

concept_spec
  declares available signal channels for a clinical/research concept

variable_template
  concept-specific parametric quickstart for common variable definitions

variable_spec
  concrete protocol-specific executable variable definition

runtime
  supplies actual data, model/provider settings, execution parameters, and environment
```

The key distinction is:

```text
concept_spec defines possible signals.
variable_spec defines the requested measurement.
```

A concept is not a final diagnosis, phenotype, or analytical variable. It is a reusable map of where concept-related information can be resurfaced in the HDW.

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

> For this clinical/research concept, what signal channels exist in the HDW, and how can each channel resurface candidate evidence?

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
optional extraction strategies
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
```

The engine should not validate scientific appropriateness:

```text
Does glucose prove diabetes?
Does absence of a PMSI code mean no diabetes?
Does no text mention mean no disease?
```

Those are protocol/researcher choices.

---

## 6. variable_spec

A `variable_spec` is the concrete, executable study-specific definition of one analytical variable.

It answers:

> In this study, for this unit, using these channels, in this time window, with these extraction/reduction/transformation/combination rules, produce this output variable.

It should explicitly declare:

```text
name
concept
unit
anchor
time window
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

  output = binary(),
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

  output = numeric(),
  absence_policy = missing_if_no_measurement()
)
```

Same concept. Different variable. Different selected channels. Different output.

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
```

Invalid or misplaced examples:

```text
max_value()
closest_before_anchor()
llm_after_lucene()
any_positive()
threshold_binary()
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
    output = binary(),
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
threshold_binary()
lucene_only()
llm_after_lucene()
regex_extract()
```

They are not variable templates.

They are implementation primitives.

Rule:

```text
Generic reusable computational pieces are operators/helpers.
Concept-specific reusable quickstarts are variable_templates.
Concrete study-specific definitions are variable_specs.
```

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

---

## 10. Absence semantics

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

Absence is interpreted at `variable_spec` level, not at `concept_spec` or channel level.

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
```

Candidate retrieval recall is a known ceiling. This is acceptable and must remain visible. If needed, researchers can use broader queries, including `*`, to retrieve larger corpora.

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

3. source_spec knows the warehouse.

4. concept_spec declares available signal channels for a clinical/research concept.

5. A channel resurfaces source-specific signals. It does not interpret their clinical meaning.

6. variable_template is a concept-specific parametric quickstart, not a generic computation pattern.

7. variable_spec is the concrete executable study-specific variable definition.

8. Generic reusable pieces such as reducers, windows, extraction methods, and combiners are operators/helpers, not variable templates.

9. No concept channel is used by default unless the variable_spec or template explicitly activates it.

10. Absence is never silently inferred. Execution statuses are preserved until variable_spec explicitly collapses them.

11. The final output type belongs to variable_spec.

12. Units and linkage are first-class because many errors come from measuring the right signal at the wrong grain.

13. LLM extraction must be evidence-grounded and auditable.

14. The framework should optimize for explicitness, reuse, and reviewability, not for hiding protocol choices.
```

---

## 16. Minimal example

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
    output = binary(),
    combine = any_positive(),
    absence_policy = open_world()
  )
)

# Concrete study-specific variable
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

# Different variable from same concept
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
  output = numeric(),
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
