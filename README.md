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

A text variable records the model it needs:

```r
tabagismo_enum <- variable_spec(
  name = "tabagismo_enum",
  concept = tabagismo,
  output_one_row_per = "EVTID",
  channels = list(
    text_mentions = use_channel(
      method = llm_after_lucene(),
      extractor = llm_task(
        name = "tabagismo_enum",
        system_prompt = paste(
          "Classifie uniquement le statut tabagique explicitement documente.",
          "Ne deduis jamais non_fumeur du silence."
        ),
        type_builder = \(evidence_ids) ellmer::type_object(
          smoking_status = ellmer::type_enum(
            c("actif", "sevre", "non_fumeur", "indetermine")
          ),
          evidence_ids = ellmer::type_array(
            ellmer::type_enum(evidence_ids)
          ),
          decision_note = ellmer::type_string()
        ),
        prompt_builder = \(task, candidates) paste(
          "Extraits numerotes:",
          paste(
            sprintf(
              "%s: %s",
              candidates$snippet_id,
              candidates$snippet_text
            ),
            collapse = "\n\n"
          ),
          sep = "\n"
        ),
        parser = \(result, evidence_ids) {
          levels <- c("actif", "sevre", "non_fumeur", "indetermine")
          status <- if (length(result$smoking_status) == 1L) {
            as.character(result$smoking_status)
          } else {
            NA_character_
          }
          returned_ids <- unique(as.character(unlist(result$evidence_ids)))
          returned_ids <- returned_ids[
            !is.na(returned_ids) & nzchar(returned_ids)
          ]
          real_ids <- intersect(returned_ids, evidence_ids)
          invented_ids <- setdiff(returned_ids, evidence_ids)
          requires_evidence <- status %in% c(
            "actif", "sevre", "non_fumeur"
          )
          valid <- status %in% levels &&
            (!requires_evidence || length(real_ids) > 0L)

          fields <- tibble::tibble(
            field = "smoking_status",
            status = status,
            normalized_value = status,
            evidence_ids = list(real_ids),
            field_validity = if (valid) "valid" else "invalid",
            validity_reason = if (valid) "" else
              "invalid status or definitive status without evidence",
            citation_warning = length(invented_ids) > 0L,
            citation_warning_reason = if (length(invented_ids)) {
              "model cited an unsupplied snippet id"
            } else {
              NA_character_
            }
          )
          note <- if (length(result$decision_note) == 1L) {
            as.character(result$decision_note)
          } else {
            NA_character_
          }
          list(fields = fields, summary = note)
        }
      )
    )
  ),
  output = cat_output(c("actif", "sevre", "non_fumeur", "indetermine")),
  model = "gemma3:4b",
  model_params = list(temperature = 0, seed = 42)
)
```

The response schema is plain `ellmer` inside the authored `llm_task()`. The
evidence enum is built from the snippets actually supplied for each task, so a
model cannot be instructed to cite arbitrary IDs. The prompt and parser are
ordinary inline R functions: the parser resolves returned evidence IDs and
contains the study-owned rule that definitive statuses require evidence while
`indetermine` may abstain. The engine does not export a smoking concept or decide
its categories.

`llm_after_lucene()` passes every Lucene match. A real operational cap is written
as `llm_after_lucene(max_candidates = 10)` and is therefore visible in the spec;
advanced custom selection must be named explicitly with `select_candidates =`.

`run_variable()` creates the Ollama Chat automatically. `run_protocol()` runs
variables in list order and completes all rows of one variable before moving to
the next model. Passing `chat =` remains an explicit test/debug override.

## Development

Run package-native tests with:

```r
testthat::test_local(".")
```

Before adding a model to the package approval list, run
`Rscript scripts/check_grammar_enforcement.R` against that model.

The concise package contract is in [DESIGN.md](DESIGN.md). The pre-package
prototype is preserved at tag
`checkpoint/pre-package-rebuild-2026-07-12`.
