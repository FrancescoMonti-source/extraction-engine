\name{run_variable}
\alias{run_variable}
\alias{run_protocol}
\alias{cohort_from_sources}
\title{Execute compiled study variables}
\usage{
run_variable(variable, cohort = NULL, sources = NULL, chat = NULL)

run_protocol(variables, cohort = NULL, sources = NULL, chat = NULL)

cohort_from_sources(sources)
}
\arguments{
\item{variable}{One authored variable specification.}
\item{variables}{A uniquely named list of variable specifications.}
\item{cohort}{The requested study-unit table or a patient-ID vector. If omitted,
\code{sources$cohort} is required. A table may carry \code{PATID + EVTID}; the
variable's \code{output_one_row_per} declaration projects it to patient or stay
grain before internal extraction tasks are derived.}
\item{sources}{Named EDSAN views and, for text retrieval, document candidate
inputs. Logical package source names are connected to caller objects here, for
example \code{list(biology = bio)}.}
\item{chat}{An optional \pkg{ellmer} Chat. It is required by text channels and is
deep-cloned and cleared for every task.}
}
\value{
\code{run_variable()} returns values, per-channel status and coverage, resolvable
evidence, the compiled spec, and provenance. \code{run_protocol()} returns one
such result per variable. \code{cohort_from_sources()} returns an explicit PATID
frame for deliberate exploratory use.
}
\description{
Execute the authored rule without judging its scientific correctness. Model calls
use the supplied Chat's provider, model, and parameters and preserve available
failure and truncation diagnostics.
}
