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

`"biology"` is the package's logical source name; `bio` is an arbitrary object
name in the caller's R session. `list(biology = bio)` connects them only at
execution. Biology typing is delegated to `redsan` automatically at this
boundary; callers do not manufacture engine-specific `analyte`, `value`, or row
identifier columns.

## Text models belong to variables

The concept declares where potentially relevant evidence lives:

```r
smoking <- concept_spec(
  name = "smoking",
  channels = list(
    smoking_mentions = text_channel(
      source = "documents",
      selector = lucene_query("taba*"),
      linkage = "event"
    )
  )
)
```

The variable declares what the model must extract:

```r
smoking_levels <- c(
  "actif",
  "sevre",
  "non_fumeur",
  "indetermine"
)

smoking_status <- variable_spec(
  name = "smoking_status",
  concept = smoking,
  output_one_row_per = "EVTID",

  channels = list(
    smoking_mentions = use_channel(
      method = llm_after_lucene(),

      extractor = llm_task(
        prompt = paste(
          "Determine le statut tabagique explicitement documente",
          "pour le patient cible dans les extraits fournis.",
          "",
          "Valeurs possibles :",
          "- actif : tabagisme actuel explicitement documente ;",
          "- sevre : ancien fumeur, arret ou sevrage explicitement documente ;",
          "- non_fumeur : non-fumeur ou absence de tabagisme explicitement documentee ;",
          "- indetermine : extraits insuffisants, ambigus ou contradictoires.",
          "",
          "Regles :",
          "- utilise uniquement les extraits fournis ;",
          "- evalue le patient cible, jamais sa famille ou son entourage ;",
          "- ne deduis jamais non_fumeur du silence ;",
          "- choisis une seule valeur ;",
          "- cite uniquement les identifiants des extraits soutenant la reponse ;",
          "- n'invente jamais d'identifiant.",
          sep = "\n"
        )
      )
    )
  ),

  output = cat_output(smoking_levels),

  model = "gemma3:4b",
  model_params = list(
    temperature = 0,
    seed = 42
  )
)
```

`cat_output()` is the single machine-readable declaration of the allowed values.
For each task, the engine derives the structured `ellmer` response type, appends
the numbered Lucene excerpts to the authored prompt, constrains evidence IDs to
the excerpts actually supplied, and maps the result into values and evidence.
The engine does not judge the scientific meaning of a returned category.

`llm_after_lucene()` passes every Lucene match. A real operational cap is written
as `llm_after_lucene(max_candidates = 10)` and is therefore visible in the spec;
advanced custom selection must be named explicitly with `select_candidates =`.

`run_variable()` creates the Ollama Chat automatically. `run_protocol()` runs
variables in list order and completes all rows of one variable before moving to
the next model. Passing `chat =` remains an explicit test/debug override.

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
