# =============================================================================
# concepts-hyperkalaemia.R -- the hyperkalaemia clinical example (lab path)
# -----------------------------------------------------------------------------
# Hyperkalaemia has no spec-layer concept_spec; it is a direct-executor clinical
# example of the neutral measure_analyte_value() core (R/structured.R). It lives
# here, beside the other concept/example modules, rather than in the generic engine.
# In this warehouse the analyte code fixes the interpretation; unit is not a
# measurement dimension, so concept selection belongs here, not in the loader.
# =============================================================================

# --- hyperkalaemia: thin clinically-named caller of measure_analyte_value() ----
# Kept for backward compatibility (direct structured callers/tests/scripts); the
# generic run_variable() lab branch calls the neutral measure_analyte_value() core
# directly.
POTASSIUM_CODES <- "K.K"

measure_hyperkalaemia <- function(biol, tasks, analytes = POTASSIUM_CODES,
                                  threshold = 5.0, from_days = -7L, to_days = 7L) {
    measure_analyte_value(
        biol, tasks, analytes = analytes, threshold = threshold,
        from_days = from_days, to_days = to_days,
        field = "hyperkalaemia", source = "biology")
}
