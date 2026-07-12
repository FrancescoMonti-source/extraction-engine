\name{code_channel}
\alias{code_channel}
\alias{act_channel}
\alias{lab_channel}
\alias{text_channel}
\alias{doc_channel}
\alias{icd10}
\alias{ccam}
\alias{lucene_query}
\alias{doc_meta}
\alias{analyte}
\alias{analyte_value}
\title{Declare source channels and selectors}
\usage{
code_channel(source, selector, native_grain = NA_character_,
  required_roles = character(), linkage = character(),
  group_at_level = NULL, keep_group_when = NULL)

act_channel(source, selector, native_grain = NA_character_,
  required_roles = character(), linkage = character(),
  group_at_level = NULL, keep_group_when = NULL)

lab_channel(source, selector, native_grain = NA_character_,
  required_roles = character(), linkage = character(),
  group_at_level = NULL, keep_group_when = NULL)

text_channel(source, selector, extractor = NULL, default_method = NULL,
  native_grain = NA_character_, required_roles = character(),
  linkage = character(), group_at_level = NULL, keep_group_when = NULL)

doc_channel(source, selector, native_grain = NA_character_,
  required_roles = character(), linkage = character(),
  group_at_level = NULL, keep_group_when = NULL)

icd10(pattern, match = c("regex", "exact"))

ccam(codes, match = c("exact", "regex"))

lucene_query(query)

doc_meta(...)

analyte(codes)

analyte_value(codes, gt = NULL, lt = NULL, unit = NULL, keep_when = NULL)
}
\arguments{
\item{source}{A name from \code{edsan_source_specs()}.}
\item{selector}{A selector compatible with the typed channel.}
\item{native_grain}{Optional descriptive native grain.}
\item{required_roles}{Source roles the authored definition expects.}
\item{linkage}{Relational eligibility scope. \code{"subject"} joins source rows
to a task by \code{PATID}; including \code{"event"} joins by
\code{PATID + EVTID}. It does not itself group snippets: the variable's output
grain determines the task receiving those eligible rows.}
\item{group_at_level}{Optional identity-spine grouping level.}
\item{keep_group_when}{A plain function returning one logical per group.}
\item{extractor}{An LLM task created with \code{llm_task()}. For ordinary
categorical extraction it contains only the study-authored prompt.}
\item{default_method}{An optional default \code{llm_after_lucene()} method.}
\item{pattern,codes}{Code or analyte values.}
\item{match}{Exact or regular-expression matching.}
\item{query}{One Lucene query.}
\item{...}{Uniquely named document-metadata filters.}
\item{gt,lt}{Optional strict numeric bounds.}
\item{unit}{An audit label for an upstream-normalized unit.}
\item{keep_when}{A vectorized row predicate whose formal names are prepared-view
columns.}
}
\value{A typed channel or selector specification.}
\description{
Channels select source rows and carry their payload. They do not assign clinical
meaning to those rows.
}
