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
