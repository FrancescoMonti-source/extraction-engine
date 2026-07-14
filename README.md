# extractionengine

> `extractionengine` is the auditable executor of a study's operational
> definitions, not the author of those definitions.

The package executes explicit study-variable specifications over prepared EDSAN
views. It returns the value together with source coverage, resolvable evidence,
and execution provenance. The researcher owns the clinical definition, the
scientific validity of the rule, and interpretation of the result.

`redsan` owns EDSAN retrieval, source mechanics, and normalization. `ellmer`
owns model transport and structured output. `extractionengine` connects those
boundaries without hiding the authored rule.

The package is currently for internal use. It contains no patient data and no
exported clinical concepts.

## First structured variable

The cohort declares the available study units. It may contain one row per stay:

```r
cohorte <- readRDS("path/to/cohorte")  # PATID + EVTID
bio <- readRDS("path/to/bio")
```

The variable, not the cohort object, chooses the output grain. With
`output_one_row_per = "PATID"`, repeated stays are projected to one row per
patient. With `output_one_row_per = "EVTID"`, `PATID + EVTID` identifies one
output row per stay. Internal extraction tasks are derived by the engine; users
pass a `cohort`.

A concept declares where a signal can be observed. Here the same measurement is
available through two EDSAN analyte codes:

```r
hemoglobine <- concept_spec(
  name = "hemoglobine",
  channels = list(
    hemoglobin_gdl = lab_channel(
      source = "biology",
      selector = analyte("NGR.NGR-HB-GDL")
    ),
    hemoglobin_mml = lab_channel(
      source = "biology",
      selector = analyte("NGR.NGR-HB-MML")
    )
  )
)
```

The study variable activates those channels and supplies the operational rule.
`keep_when` extends the inherited analyte selector, so its code is not repeated.
The thresholds and conversion below are demonstration choices owned by the
researcher; the engine does not validate their scientific correctness.

```r
anemia <- variable_spec(
  name = "anemia_demo",
  concept = hemoglobine,
  output_one_row_per = "EVTID",
  channels = list(
    hemoglobin_gdl = use_channel(
      keep_when = \(value, PATSEX) {
        value < ifelse(PATSEX == "F", 12, 13)
      }
    ),
    hemoglobin_mml = use_channel(
      keep_when = \(value, PATSEX) {
        value < ifelse(PATSEX == "F", 12, 13) * 0.6206
      }
    )
  ),
  combine_channels = any_positive(),
  output = bin_output()
)

anemia                         # concise human-readable print
inspect(anemia)                # compiled debugging representation

result <- run_variable(
  anemia,
  cohort = cohorte,
  sources = list(biology = bio)
)
```

Published result views carry the native output-grain keys. A patient-grain
variable exposes `PATID`; a stay-grain variable exposes `PATID + EVTID`.
Composite execution IDs remain internal to the engine.

`"biology"` is the package's logical source name; `bio` is an arbitrary object
name in the caller's R session. `list(biology = bio)` connects them only at
execution. Biology typing is delegated to `redsan` automatically at this
boundary; callers do not manufacture engine-specific `analyte`, `value`, or row
identifier columns.

## Text evidence and text variables

The concept declares every place where potentially relevant evidence can be
found. It does not say what to do with that evidence. Text channels use the
logical source `"documents"` by default, while `evidence_scope` explicitly says
whether eligible documents come from the same patient or the same stay.

```r
smoking <- concept_spec(
  name = "smoking",
  channels = list(
    smoking_mentions = text_channel(
      selector = lucene_query("taba*"),
      evidence_scope = "event"
    )
  )
)
```

The same channel can support a deterministic presence variable with
`method = "lucene"` and `bin_output()`, or a structured extraction with
`method = "lucene_llm"`. The latter keeps the detailed study instruction in a
plain prompt owned by the researcher:

```r
smoking_levels <- c(
  "actif",
  "sevre",
  "non_fumeur",
  "indetermine"
)

smoking_prompt <- paste(
  "Détermine le statut tabagique explicitement documenté",
  "pour le patient cible dans les extraits fournis.",
  "",
  "Valeurs possibles :",
  "- actif : tabagisme actuel explicitement documenté ;",
  "- sevre : ancien fumeur, arrêt ou sevrage explicitement documenté ;",
  "- non_fumeur : non-fumeur ou absence de tabagisme explicitement documentée ;",
  "- indetermine : extraits insuffisants, ambigus ou contradictoires.",
  "",
  "Règles :",
  "- utilise uniquement les extraits fournis ;",
  "- évalue le patient cible, jamais sa famille ou son entourage ;",
  "- ne déduis jamais non_fumeur du silence ;",
  "- choisis une seule valeur ;",
  "- cite uniquement les identifiants des extraits soutenant la réponse ;",
  "- n’invente jamais d’identifiant.",
  sep = "\n"
)

smoking_status <- variable_spec(
  name = "smoking_status",
  concept = smoking,
  output_one_row_per = "EVTID",

  channels = list(
    smoking_mentions = use_channel(
      method = "lucene_llm",
      prompt = smoking_prompt
    )
  ),

  output = cat_output(
    smoking_levels,
    description = "Statut tabagique explicitement documenté dans les extraits.",
    rationale = paste(
      "Justification brève du choix, fondée uniquement sur les extraits",
      "et sans ajouter d'information non documentée."
    )
  ),

  model = "gemma3:4b",
  model_params = list(
    temperature = 0,
    seed = 42
  )
)

corpus <- corpustools::create_tcorpus(
  docs |>
    dplyr::select(ELTID, RECTXT, PATID, EVTID, RECDATE, RECTYPE) |>
    as.data.frame(),
  text_columns = "RECTXT",
  doc_column = "ELTID",
  split_sentences = TRUE,
  remember_spaces = FALSE,
  verbose = FALSE
)

result_smoking <- run_variable(
  smoking_status,
  cohort = cohorte,
  sources = list(documents = corpus)
)
```

The document source is the caller-owned `tCorpus`. Its metadata must retain
`PATID`, `EVTID`, `RECDATE`, and `RECTYPE`; corpustools stores the declared
`ELTID` document column as `doc_id`, which the engine maps back internally. As
with biology, binding happens only at execution: `documents = corpus` connects
the object to the logical source name used by `text_channel()`.

`cat_output()` is the single machine-readable declaration of the allowed values.
Its optional `description` gives ellmer the study-owned meaning of the returned
value. Its optional `rationale` requests a required non-empty explanation and is
used as that field's ellmer description; the published row then carries both
`value` and `rationale`. The engine supplies the enclosing-object and
evidence-field descriptions itself. For each cohort row, it derives the structured `ellmer` response type,
appends the numbered Lucene excerpts to the authored prompt, constrains the value
to those levels, and constrains evidence IDs to the excerpts actually supplied.
The model may select the wrong allowed category, but it cannot return a category
outside the declared vocabulary. The engine does not judge the scientific meaning
of the selected category.

By default every Lucene match is passed to the model. A real operational cap is
written explicitly as `max_candidates = 10` inside `use_channel()`. The optional
`system_prompt` lives in the same place; when omitted, the package supplies a
French structured-extraction default that treats excerpts as data, requires the
declared schema, and forbids invented information or evidence identifiers.

`run_variable()` creates the Ollama Chat automatically. `run_protocol()` runs
variables in list order and completes all rows of one variable before moving to
the next model. One base Chat is created per `lucene_llm` variable and cloned for
its cohort rows; the Ollama model is not rebuilt for every row. Passing `chat =`
remains an explicit test/debug override. A `method = "lucene"` variable never
creates a Chat.

## Development

Build and check the package with:

```text
R CMD build .
R CMD check extractionengine_0.1.0.tar.gz
```

Before adding a model to the package approval list, run
`Rscript scripts/check_grammar_enforcement.R` against that model.

The concise package contract is in [DESIGN.md](DESIGN.md). The pre-package
prototype is preserved at tag
`checkpoint/pre-package-rebuild-2026-07-12`.
