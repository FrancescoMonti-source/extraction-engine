\name{index_event}
\alias{index_event}
\alias{combine_channels}
\alias{bin_output}
\alias{from_channel}
\title{Compose anchors, channel combinations, and outputs}
\usage{
index_event(source, selector, at = NULL, select_event = NULL)

combine_channels(expr, by)

bin_output(group_by)

from_channel(channel, group_by, value = NULL, filter_by_qualified = NULL)
}
\arguments{
\item{source}{The registered prepared source used to derive an index event.}
\item{selector}{A code selector created with \code{icd10()} or \code{ccam()}.}
\item{at}{Optional exact date-column name in \code{source}; otherwise its
registered source clock.}
\item{select_event}{Optional plain function evaluated separately for each
patient when multiple events match. It receives matched rows carrying
\code{PATID}, \code{EVTID}, and the physical date-column name and must return the
selected row or rows without altering or inventing an \code{EVTID}/date pair.
Without it, multiple matches are an error.}
\item{expr}{A hit-set expression using activation aliases and \code{|},
\code{&}, \code{!}, and parentheses.}
\item{by}{The \code{"PATID"}, \code{"EVTID"}, or \code{"ELTID"} key where
the signals referenced by \code{expr} must coexist. \code{"ELTID"} is valid
only when all referenced activations resolve to the same source identity domain;
a payload consuming those qualified keys at \code{ELTID} must use that domain too.}
\item{channel}{The activation alias whose payload is published.}
\item{value}{For a deterministic activation, one data-masked expression evaluated
over the complete, aligned prepared-source rows of each final group. It may use
multiple columns and must return exactly one cell. Omit it for an LLM activation
to publish the complete structured frame.}
\item{filter_by_qualified}{Optional qualifying-relation key used to filter native
payload rows before terminal grouping. It is admitted and required only when
\code{combine$by} is finer than the output \code{group_by}, and must then equal
one of those two keys. It must be \code{NULL} otherwise. A fine-to-coarse LLM
payload supports only the output \code{group_by}.}
\item{group_by}{Mandatory final result-grain key: \code{"PATID"},
\code{"EVTID"}, or \code{"ELTID"}. It is not inferred from a combine and is
distinct from \code{use_channel(group_by =)}, which groups rows only for
\code{filter_groups}.}
}
\value{An anchor, combiner, or output specification.}
\description{
These objects describe mechanical execution. \code{bin_output(group_by)} publishes
membership or a hit-set decision. \code{from_channel()} publishes an explicitly
named activation payload.
}
\details{
Data-masked expressions see prepared-source columns as bare names. \code{.data}
supports programmatic column selection and \code{.env} disambiguates captured
external values. Missing values remain aligned and are not removed automatically.
When no payload row remains, \code{value} is not evaluated and the result is a
logical missing value. Otherwise it must return one atomic scalar or one list
cell; longer or dimensional results are cardinality errors. Hit-set expressions
operate on observed membership and do not encode clinical ontology.
\code{combine_channels(expr, by)} accepts exactly one boolean expression string; no
separate public hit-set helper constructors are required.

For payload output, execution is ordered as combine by, filter by qualified,
group by, then evaluate value. The expression is evaluated once for each final
group over its aligned raw rows, without implicit missing-value removal or an
intermediate aggregation. LLM output omits \code{value}.

\code{index_event()} is resolved from its named source before channel execution;
it is not associated with or inferred from a \code{use_channel()} activation.
Every cohort patient must resolve to an event. Multiple selected events can
generate separate EVTID tasks only for EVTID output starting from a PATID-only
cohort; other executions require one resolved anchor per patient.
}
