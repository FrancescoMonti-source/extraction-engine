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
