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

from_channel(channel, column = NULL, filter_by_qualified = NULL,
  group_by, reduce = NULL)
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
the signals referenced by \code{expr} must coexist.}
\item{channel}{The activation alias whose payload is published.}
\item{column}{For a deterministic activation, one exact prepared-source column
name. For an LLM activation, \code{NULL} publishes the complete structured frame
and a field name projects one column.}
\item{filter_by_qualified}{Optional qualifying-relation key used to filter native
payload rows before terminal grouping. It is admitted and required only when
\code{combine$by} is finer than the output \code{group_by}, and must then equal
one of those two keys. It must be \code{NULL} otherwise. A fine-to-coarse LLM
payload supports only the output \code{group_by}.}
\item{group_by}{Mandatory final result-grain key: \code{"PATID"},
\code{"EVTID"}, or \code{"ELTID"}. It is not inferred from a combine and is
distinct from \code{use_channel(group_by =)}, which groups rows only for
\code{filter_groups}.}
\item{reduce}{An optional plain function receiving non-missing values and
returning one scalar.}
}
\value{An anchor, combiner, or output specification.}
\description{
These objects describe mechanical execution. \code{bin_output(group_by)} publishes
membership or a hit-set decision. \code{from_channel()} publishes an explicitly
named activation payload.
}
\details{
Without \code{reduce}, zero non-missing values produce a typed missing value, one
is returned directly, and more than one is a cardinality error. Hit-set
expressions operate on observed membership and do not encode clinical ontology.
\code{combine_channels(expr, by)} accepts exactly one boolean expression string; no
separate public hit-set helper constructors are required.

For payload output, execution is ordered as combine by, filter by qualified,
group by, then reduce. The reducer is called once for each final group over its
non-missing raw values, without an implicit intermediate aggregation. LLM output
does not accept \code{reduce}.

\code{index_event()} is resolved from its named source before channel execution;
it is not associated with or inferred from a \code{use_channel()} activation.
Every cohort patient must resolve to an event. Multiple selected events can
generate separate EVTID tasks only for EVTID output starting from a PATID-only
cohort; other executions require one resolved anchor per patient.
}
