defmodule Scry.Search.Executor do
  @moduledoc """
  `<field> SEARCH <string>` / `relevance()`'s own execution (lang_spec.md
  §8.5). A genuinely different shape from every other kind package
  built so far: `scry_time_series`'s `Executor.run/5` lowers `LAST`
  into an ordinary predicate via a pure AST rewrite (no row access
  needed, since the threshold is a constant computed once against
  `now`), and `scry_document`/`scry_graph`'s own executors bypass
  `Scry.Core.EngineBehaviour` entirely because their work is about
  `select`-body structure, not `WHERE`-predicate evaluation. `SEARCH`
  is neither: whether a row matches, and how well, can only be decided
  by inspecting that row's own field value -- there is no AST-only
  transform that produces an equivalent ordinary predicate ahead of
  time. That need lines up exactly with `Scry.Core.EngineBehaviour`'s
  own `execute/3` contract (an engine that receives real rows and
  decides the whole query), so this module implements it directly --
  the first kind package to double as its own engine, rather than
  requiring a real storage adapter to sit underneath it.

  `run/3` is the intended public entry point; `execute/3` (the
  `EngineBehaviour` callback) is also the module's own recursive
  re-entry point for `Scry.Core.QueryOps.run_document/4`'s generic
  nested-`SELECT`/combinator resolution -- the identical shape `Scry.
  Core.EngineBehaviour`'s own moduledoc documents and every reference
  test-double engine in this ecosystem (e.g. `scry_time_series`'s own
  `FakeEngine` test support) already establishes: `execute/3` checks
  whether `query.select` contains a nested `%Query{}` and, if so,
  delegates to `run_document/4`, which recurses into `execute/3` again
  for each flat leaf it finds; otherwise it handles `SEARCH`/
  `relevance()` itself directly.

  A `WITH`-bound source is resolved by `execute_flat/3` itself, not via
  `run_document/4` -- confirmed by reading `run_document/4`'s own
  `resolve_source/5` directly: once a `WITH` binding resolves to real
  rows, it calls `Scry.Core.QueryOps.run_flat/3` *directly*, bypassing
  `execute/3` entirely for the query that *consumes* the binding --
  exactly the layer this module's own rewrite needs to run at. Handled
  by recursing into this module's own `run/3` for the bound query
  instead (`fetch_rows/3`'s own moduledoc comment has the full
  reasoning and its one real, narrower-than-core's-own scope limit).

  ## The toy relevance scorer, stated plainly

  This is a reference implementation proving the language construct
  executes, not an integration with any real search engine. `<field>
  SEARCH <needle>` lowercases and tokenizes both `<needle>` and the
  row's own `<field>` value on non-letter/non-digit boundaries, and
  scores a match as the count of `<needle>`'s own tokens that also
  appear among `<field>`'s tokens -- a simple token-overlap count, nothing
  resembling real fuzzy matching, stemming, or ranked relevance. A row
  "matches" (survives `WHERE`/`AND`/`OR`/`NOT` combination with
  whatever else is in the predicate tree) iff its score is greater than
  zero. `relevance()` is the *sum* of every `SEARCH` clause's own score
  for that row, when more than one is present.

  ## How `SEARCH`/`relevance()` actually get resolved (the rewrite)

  1. `query.wheres` (a list of predicates, ANDed) is walked recursively
     -- through `{:and, ...}`/`{:or, ...}`/`{:not, ...}`, never into a
     nested `%Query{}` (those are handled by `run_document/4`'s own
     recursion, not this module's rewrite) -- collecting every
     `{:variant, {:search, left, needle}}` leaf found anywhere in it
     and replacing each occurrence, in place, with an ordinary
     `{:cmp, :eq, [marker], true}` predicate referencing a fresh
     synthetic per-clause boolean field name (`"_scry_search_match_N"`).
     This preserves the surrounding `AND`/`OR`/`NOT` structure exactly
     -- a `SEARCH` used inside an `OR`, or negated, behaves exactly as
     it reads.
  2. For each of `query.source`'s own rows, every extracted clause's
     own `score(row)` is computed and merged onto the row as that
     clause's own boolean marker field plus a running total under
     `"_scry_relevance"`.
  3. Every `{:call, "relevance", []}` occurrence in `query.select` and
     `query.order_bys` is rewritten to `{:field, ["_scry_relevance"]}`
     -- an ordinary field reference by the time `Scry.Core.QueryOps`
     ever sees it; core never sees the literal name `"relevance"` at
     all in the query it actually evaluates.
  4. The rewritten query (real `WHERE`, no `SEARCH`/`relevance()` left
     anywhere in it) and the annotated rows are handed to `Scry.Core.
     QueryOps.run_flat/3`, exactly like any other engine -- `GROUP BY`/
     `HAVING`/`ORDER BY`/`LIMIT`/`DISTINCT`/projection are all ordinary
     core semantics from this point on, composing for free (a `SEARCH`
     predicate combined with `GROUP BY`, unlike `scry_document`/`scry_
     graph`'s own pseudo-fields, needs no special case at all -- the
     matching happens per-row, before grouping, exactly like any other
     `WHERE` filter would).

  ## Stated scope limits (not silently mishandled)

  - `SEARCH`'s own left-hand side must be a bare field path in this
    reference implementation -- `predicate_lhs`'s other two shapes
    (`{:call, ...}`/`{:dot, ...}`) are accepted by the grammar (the
    same "grammar stays permissive, execution decides" posture every
    other construct in this ecosystem already has) but raise a clear
    `ArgumentError` here, not a silent misresolution.
  - `SEARCH` anywhere in `query.havings` is `{:error, {:unsupported,
    {:construct, :search_in_having}}}` -- a per-row match doesn't
    obviously aggregate across a group the way `lang_spec.md`'s own
    single worked example (`SEARCH` only ever inside `WHERE`) implies,
    so this stays a stated "not yet" rather than a guessed semantic.
    A bare `relevance()` call (no `SEARCH` alongside it) is not
    rewritten inside `havings` for the same reason this rewrite is
    scoped to `select`/`order_bys` only -- it reaches core's own
    generic "unknown function" error instead, same posture.
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.{CombinedQuery, Cursor, Query, QueryOps}

  @relevance_field "_scry_relevance"

  @doc """
  Like `Scry.Core.Executor.run/4`, but resolves `SEARCH`/`relevance()`
  along the way (this module's own moduledoc has the full mechanics).
  `conn` is a plain `%{[String.t(), ...] => [row]}` map, the same
  shape every other in-memory reference engine in this ecosystem
  already uses -- `SEARCH` needs no new storage primitive the way
  `scry_document`'s hierarchical paths or `scry_graph`'s adjacency
  index did, only new *execution* logic, so no bespoke `Conn` module
  exists here at all.
  """
  @spec run(Query.t() | CombinedQuery.t(), map(), map()) ::
          {:ok, Scry.Core.Cursor.t()} | {:error, term()}
  def run(query_or_combined, conn, params \\ %{}) do
    with {:ok, rows} <- execute(conn, query_or_combined, params) do
      {:ok, Scry.Core.Cursor.new(rows)}
    end
  end

  @impl true
  def execute(conn, %CombinedQuery{} = combined, params) do
    QueryOps.run_document(conn, combined, params, __MODULE__)
  end

  @impl true
  def execute(conn, %Query{} = query, params) do
    if Enum.any?(query.select, &match?(%Query{}, &1)) do
      QueryOps.run_document(conn, query, params, __MODULE__)
    else
      execute_flat(conn, query, params)
    end
  end

  defp execute_flat(conn, query, params) do
    {rewritten_wheres, clauses} = extract_search_clauses(query.wheres)

    with :ok <- reject_search_in_havings(query.havings),
         :ok <- reject_unsupported_lhs(clauses),
         {:ok, raw_rows} <- fetch_rows(conn, query, params) do
      scored_rows = Enum.map(raw_rows, &annotate_row(&1, clauses))

      rewritten_query = %{
        query
        | wheres: rewritten_wheres,
          select: Enum.map(query.select, &rewrite_relevance_body_item/1),
          order_bys: Enum.map(query.order_bys, &rewrite_relevance_order_item/1)
      }

      QueryOps.run_flat(scored_rows, rewritten_query, params)
    end
  end

  # A `WITH`-bound source needs resolving *ourselves*, not via `Scry.
  # Core.QueryOps.run_document/4` -- that function's own `resolve_
  # source/5` (confirmed by reading it directly, not assumed) calls
  # `run_flat/3` *directly* once a `WITH` binding resolves to real
  # rows, bypassing `execute/3` entirely for the *consuming* query --
  # exactly the layer this module's own `SEARCH`/`relevance()` rewrite
  # needs to run at. Resolving it here instead (recursing into this
  # module's own `run/3`, so the bound query's own `SEARCH`/`relevance()`
  # -- if it has any -- resolves correctly too) means the consuming
  # query's own rewrite still happens, same as the ordinary-source case.
  # A real, narrower scope limit than `run_document/4`'s own general
  # case: a `WITH` binding's own value can't itself reference a
  # *different*, outer-scoped `WITH` binding this way, since `with_
  # bindings` is only ever populated on the top-level query (`Scry.
  # Core.Query`'s own moduledoc) -- the identical limit core's own
  # generic resolution already has, not a new one this rewrite adds.
  defp fetch_rows(conn, %Query{source: [name]} = query, params) do
    case Map.fetch(query.with_bindings, name) do
      {:ok, bound_query} ->
        with {:ok, cursor} <- run(bound_query, conn, params) do
          {:ok, Cursor.to_list(cursor)}
        end

      :error ->
        fetch_source(conn, query.source)
    end
  end

  defp fetch_rows(conn, query, _params), do: fetch_source(conn, query.source)

  defp fetch_source(conn, source) do
    case Map.fetch(conn, source) do
      {:ok, rows} -> {:ok, rows}
      :error -> {:error, {:query_error, {:no_such_source, source}}}
    end
  end

  # A cheap, fail-fast, query-shape check -- same posture as
  # `reject_search_in_havings/1`, checked before any row is touched,
  # rather than raising deep inside per-row scoring once processing is
  # already underway. `match_score/2`'s own "must resolve to a String"
  # case stays a raised runtime error, deliberately -- whether a given
  # row's own field value happens to be a string is real row *data*,
  # not something knowable from the query's own AST ahead of time the
  # way an unsupported `left` shape already is.
  defp reject_unsupported_lhs(clauses) do
    if Enum.all?(clauses, fn {_marker, left, _needle} -> is_list(left) end) do
      :ok
    else
      {:error, {:unsupported, {:construct, :search_lhs_not_a_field}}}
    end
  end

  # ---- SEARCH extraction (a recursive predicate-tree walk, wheres only --
  # havings is checked, never rewritten, by reject_search_in_havings/1) ----

  defp extract_search_clauses(predicates) do
    {rewritten, {_next_index, clauses}} =
      Enum.map_reduce(predicates, {0, []}, &rewrite_predicate/2)

    {rewritten, Enum.reverse(clauses)}
  end

  defp rewrite_predicate({:variant, {:search, left, needle}}, {index, clauses}) do
    marker = "_scry_search_match_#{index}"
    rewritten = {:cmp, :eq, [marker], true}
    {rewritten, {index + 1, [{marker, left, needle} | clauses]}}
  end

  defp rewrite_predicate({:and, l, r}, state) do
    {l2, state} = rewrite_predicate(l, state)
    {r2, state} = rewrite_predicate(r, state)
    {{:and, l2, r2}, state}
  end

  defp rewrite_predicate({:or, l, r}, state) do
    {l2, state} = rewrite_predicate(l, state)
    {r2, state} = rewrite_predicate(r, state)
    {{:or, l2, r2}, state}
  end

  defp rewrite_predicate({:not, p}, state) do
    {p2, state} = rewrite_predicate(p, state)
    {{:not, p2}, state}
  end

  defp rewrite_predicate(other, state), do: {other, state}

  defp reject_search_in_havings(havings) do
    if Enum.any?(havings, &has_search?/1) do
      {:error, {:unsupported, {:construct, :search_in_having}}}
    else
      :ok
    end
  end

  defp has_search?({:variant, {:search, _left, _needle}}), do: true
  defp has_search?({:and, l, r}), do: has_search?(l) or has_search?(r)
  defp has_search?({:or, l, r}), do: has_search?(l) or has_search?(r)
  defp has_search?({:not, p}), do: has_search?(p)
  defp has_search?(_other), do: false

  # ---- Per-row scoring --------------------------------------------------

  defp annotate_row(row, clauses) do
    {row_with_markers, total_score} =
      Enum.reduce(clauses, {row, 0}, fn {marker, left, needle}, {row_acc, score_acc} ->
        score = left |> resolve_search_lhs(row_acc) |> match_score(needle)
        {Map.put(row_acc, marker, score > 0), score_acc + score}
      end)

    Map.put(row_with_markers, @relevance_field, total_score)
  end

  defp resolve_search_lhs(path, row) when is_list(path), do: get_in_row(row, path)

  defp resolve_search_lhs(other, _row) do
    raise ArgumentError,
          "SEARCH's own left-hand side must be a bare field path in this reference " <>
            "implementation, got: #{inspect(other)}"
  end

  defp get_in_row(row, [key]), do: Map.get(row, key)
  defp get_in_row(row, [key | rest]), do: row |> Map.get(key, %{}) |> get_in_row(rest)

  defp match_score(nil, _needle), do: 0

  defp match_score(value, needle) when is_binary(value) do
    needle_tokens = tokenize(needle)
    value_tokens = tokenize(value)
    Enum.count(needle_tokens, &(&1 in value_tokens))
  end

  defp match_score(other, _needle) do
    raise ArgumentError,
          "SEARCH's own left-hand side must resolve to a String (or nil), got: #{inspect(other)}"
  end

  defp tokenize(text) do
    text |> String.downcase() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
  end

  # ---- relevance() rewrite (select/order_bys only -- see moduledoc) -----

  defp rewrite_relevance_body_item({:computed, alias_name, expr}),
    do: {:computed, alias_name, rewrite_relevance_expr(expr)}

  defp rewrite_relevance_body_item(other), do: other

  defp rewrite_relevance_order_item({key, direction}),
    do: {rewrite_relevance_expr(key), direction}

  defp rewrite_relevance_expr({:call, "relevance", []}), do: {:field, [@relevance_field]}

  defp rewrite_relevance_expr({:call, name, args}),
    do: {:call, name, Enum.map(args, &rewrite_relevance_expr/1)}

  defp rewrite_relevance_expr({:arith, op, left, right}),
    do: {:arith, op, rewrite_relevance_expr(left), rewrite_relevance_expr(right)}

  defp rewrite_relevance_expr({:when, clauses, else_expr}) do
    rewritten_clauses =
      Enum.map(clauses, fn {predicate, expr} -> {predicate, rewrite_relevance_expr(expr)} end)

    {:when, rewritten_clauses, rewrite_relevance_expr(else_expr)}
  end

  defp rewrite_relevance_expr({:distinct, expr}), do: {:distinct, rewrite_relevance_expr(expr)}

  defp rewrite_relevance_expr({:dot, base, path}),
    do: {:dot, rewrite_relevance_expr(base), path}

  defp rewrite_relevance_expr({:window, call, partition_by, order_bys, frame}) do
    rewritten_order_bys = Enum.map(order_bys, &rewrite_relevance_order_item/1)
    {:window, rewrite_relevance_expr(call), partition_by, rewritten_order_bys, frame}
  end

  defp rewrite_relevance_expr(other), do: other
end
