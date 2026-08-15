defmodule Scry.Search do
  @moduledoc """
  The `search` kind for Scry -- `<field> SEARCH <string>` only. This
  package's own README/CHANGELOG have the full scope reasoning.

  `parse/1` mirrors `Scry.Core.parse/1`'s own shape and is the intended
  entry point for anything outside this package that only needs to
  parse. `Scry.Search.Executor.run/3` is the intended entry point for
  anything that also needs to *execute* a parsed query -- `SEARCH`
  means nothing to `Scry.Core.Executor`/`Scry.Core.QueryOps` on their
  own, and computing whether/how well a row matches one needs access to
  that row's own raw field value, which no pure AST-rewrite-then-
  delegate pass (the shape `scry_time_series`'s own `LAST`-lowering
  uses) can provide -- see `Scry.Search.Executor`'s own moduledoc for
  the full "why a real `EngineBehaviour` implementation, not a lowering
  pass" reasoning, a genuinely different shape from every other kind
  package built so far.

  `relevance()` (the other keyword this package introduces) needs **no
  grammar contribution at all** -- an ordinary bare call already parses fine
  through core's own generic `call`/`call_arg` production (confirmed
  directly, the same finding that resolved `scry_time_series`'s own
  `rate(<duration>)`), so this package's own grammar fragment fills
  only `comparison_ep1e`. Unlike `rate`, `relevance` is never
  registered with `scry_core` as a built-in at all (no `@aggregate_names`/
  `@call_names` addition anywhere) -- `Scry.Search.Executor` rewrites
  every `{:call, "relevance", []}` occurrence into an ordinary field
  reference before `Scry.Core.QueryOps` ever runs, so core never even
  sees the literal name `"relevance"` in the query it actually
  evaluates.
  """

  alias Scry.Core.{CombinedQuery, Query}

  @doc """
  Parses `source` (Scry query text) into a `%Scry.Core.Query{}` (or a
  `%Scry.Core.CombinedQuery{}`, per `Scry.Core.parse/1`'s own combinator
  handling), using `Scry.Search.Grammar.Compiled` -- checked-in,
  pre-generated from core merged with this package's own fragment (see
  `Scry.Search.Grammar`'s own moduledoc). A `<field> SEARCH <string>`
  comparison resolves into `{:variant, {:search, left, needle}}` inside
  `query.wheres`/`query.havings` (this package's own `Scry.Search.
  Actions` tags it directly -- unlike an EP1(b)/(c)/(d) body-item
  construct, core's own `comparison` production has no host-level
  wrapping clause for `comparison_ep1e` to defer to, so the wrapping
  happens here instead). A query with no `SEARCH` at all behaves
  exactly as `Scry.Core.parse/1` already does, since every one of
  core's own rules is unchanged by this package's own composition.
  `SEARCH` is never executed by `parse/1` itself -- see `Scry.Search.
  Executor.run/3` for that.
  """
  @spec parse(String.t()) :: {:ok, Query.t() | CombinedQuery.t()} | {:error, term()}
  def parse(source) when is_binary(source) do
    Scry.Search.Grammar.Compiled.run(source, nil)
  end
end
