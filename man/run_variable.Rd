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
\item{variables}{A non-empty list of variable specifications. It must be entirely
unnamed or entirely named. If named, names must exactly match each
\code{spec$name} in the same order; canonical names must be unique.}
\item{cohort}{The requested study-unit table or a patient-ID vector. If omitted,
\code{sources$cohort} is required. A table may carry \code{PATID + EVTID}; the
variable's \code{output$group_by} declaration projects it to patient, stay, or
element grain before internal extraction tasks are derived. It may also carry a
variable's named anchor date column; when a window consumes it, projection must
leave one non-missing \code{Date} or \code{POSIXt} value per output unit.}
\item{sources}{Named EDSAN views and, for text retrieval, a metadata-rich
\pkg{corpustools} \code{tCorpus}. Its metadata must retain the native document
identifiers and scope fields. Logical package source names are connected to
caller objects here, for example \code{list(biology = bio, documents = corpus)}.}
\item{chat}{An optional global \pkg{ellmer} Chat override applied to every LLM
activation in this run, intended for tests and debugging. When omitted, each
\code{lucene_llm} activation creates its own Ollama Chat from the \code{model}
and \code{model_params} declared in \code{use_channel()}. The activation's base
Chat is deep-cloned and cleared for every task. Deterministic \code{lucene}
activations do not create a Chat.}
}
\value{
\code{run_variable()} returns exactly \code{values}, \code{channel_status},
\code{evidence}, and \code{audit}. Row-keyed public frames expose native
output-grain columns: \code{PATID} at patient grain and \code{PATID + EVTID} at
stay grain. Public evidence classifies each row as \code{source_row},
\code{lucene_hit}, or \code{llm_citation} in \code{evidence_kind}.
\code{evidence_ref} is an opaque coordinate local to the executed run and source
snapshot, not a globally durable warehouse key. An LLM citation may retain its
task-local \code{snippet_id}. Any native evidence \code{EVTID} is published as
\code{source_EVTID}; at stay grain the target remains \code{EVTID}, even when
the two values are equal. Structured evidence keeps available prepared-source
columns; internal \code{source_row_id} and \code{hit_ref} coordinates are not
published.

\code{channel_status} contains one row per output task and activated channel. Its
stable core identifies the output unit, variable, channel, and source.
\code{selection_status} is exactly \code{matched}, \code{no_match}, or
\code{unavailable}. \code{processing_status} is \code{not_required} for
non-LLM channels; for \code{lucene_llm} it is exactly \code{completed},
\code{not_called}, \code{invalid}, or \code{failed}. These are mechanical
selection and processing states, not clinical interpretations.

\code{audit} contains a long \code{counts} table (grain keys, \code{channel},
\code{stage}, \code{unit}, \code{n}), \code{llm_calls}, and a resolved
\code{execution_manifest}. Controlled stages are \code{pre_selector},
\code{window}, \code{selector}, \code{filtered_selector}, \code{model_input},
and \code{output_input}; they appear only when separately instrumented, so
absence does not prove an operation did not run. They count associated
structured rows or searchable text documents before selection, window
survivors, selector matches, matches surviving activation filters, model
snippets, and prepared-source rows supplied to the terminal value expression,
respectively.
\code{llm_calls} has one row per task/channel model invocation actually made and
separates \code{call_status}, \code{response_status}, \code{task_validity}, and
\code{transport_attempts}. It retains configuration, timing, fingerprints,
diagnostics, and raw or partial response, with a stable schema even at zero rows.
A task that does not reach the model has no call row.
\code{execution_manifest} is the
resolved configuration snapshot, not a chronological log. It records the
terminal data flow as combine by, filter by qualified, group by, then evaluate
value.
Combine runs
additionally retain \code{overlap}, a tabular summary of channel-membership
patterns, and \code{combine_keys}, the evaluated key-level relation at
\code{combine$by}. \code{overlap} is computed from task-level hit patterns, not
by aggregating \code{combine_keys}. Executable and debugging details are kept under
\code{audit$internal} as \code{resolved_spec} and \code{channel_intermediates}.
Printing \code{execution_manifest} gives a compact summary while its complete
resolved fields remain directly addressable.

\code{run_protocol()} returns one such lossless result per variable and always
names that result list from \code{spec$name}, never from a local R binding.
Duplicate canonical names, partial names, and discordant supplied names fail. A
whole-frame LLM output publishes every authored TypeObject field and its
rationale when enabled. \code{cohort_from_sources()} returns an explicit PATID
frame for deliberate exploratory use.
}
\description{
Execute the authored rule without judging its scientific correctness. Model calls
use \code{ellmer::chat_structured()}, record the executed Chat's provider, model,
and parameters in \code{audit$llm_calls}, and preserve available failure and
truncation
diagnostics. Stable
typed rows and separate processing/review state are retained for no-candidate,
model-error, and invalid-schema outcomes.
}
