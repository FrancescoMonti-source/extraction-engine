\name{index_event}
\alias{index_event}
\alias{any_positive}
\alias{hit_set_expr}
\alias{hit_set_difference}
\alias{llm_after_lucene}
\alias{bin_output}
\alias{num_output}
\alias{cat_output}
\alias{date_output}
\alias{struct_output}
\title{Compose anchors, channel algebra, text methods, and outputs}
\usage{
index_event(source, selector, at = NULL, select_event = NULL)

any_positive()

hit_set_expr(expr)

hit_set_difference(include, exclude = character())

llm_after_lucene(max_candidates = NULL, select_candidates = NULL)

bin_output()

num_output(values_from = NULL, reduce = NULL)

cat_output(levels, values_from = NULL, reduce = NULL)

date_output(values_from = NULL, reduce = NULL)

struct_output(fields)
}
\arguments{
\item{source,selector}{The source and selector used to derive an index event.}
\item{at}{Optional source date column; otherwise the registered source clock.}
\item{select_event}{Optional plain function selecting matched event rows.}
\item{expr}{A hit-set expression using channel names and \code{|}, \code{&},
\code{!}, and parentheses.}
\item{include,exclude}{Channel names for difference sugar.}
\item{max_candidates}{Optional positive integer. When omitted, every Lucene
match is passed to the LLM task. When supplied, only the first N matches in the
engine's deterministic candidate order are retained.}
\item{select_candidates}{Optional advanced plain function that selects or
reorders one task's Lucene matches. It cannot be combined with
\code{max_candidates}; using it is part of the authored evidence-selection rule.}
\item{values_from}{The channel carrying an output payload.}
\item{reduce}{A plain function reducing payload values to one value.}
\item{levels}{Allowed categorical values.}
\item{fields}{Names of fields emitted by a structured text definition.}
}
\value{A typed operator, method, anchor, or output specification.}
\description{
These objects describe mechanical execution. Hit-set expressions operate on
observed row membership and do not encode clinical ontology.
}
