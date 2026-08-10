# scry_search

The `search` kind for [Scry](https://github.com/joetjen/scry)
(lang_spec.md §8.5) — a `scry_<kind>` package (impl_spec.md §2), the
first real, shipped package to fill `comparison_ep1e`'s EP1(e) infix
comparison-tier shape at all (`scry_core`'s own third extension point,
added alongside `select_ep1a`/`body_item_ep1` specifically to make this
package possible).

## Scope and real findings from building this

**A genuinely different architecture from every other kind package
built so far.** `scry_time_series`'s `LAST` lowers into an ordinary
predicate via a pure AST rewrite (its own threshold is a constant,
computed once against `now` — no row access needed), and `scry_document`/
`scry_graph`'s own executors bypass `Scry.Core.EngineBehaviour` entirely
because their work is about `select`-body structure. `SEARCH` is
neither: whether a row matches, and how well, can only be decided by
inspecting that row's own field value. That need lines up exactly with
`Scry.Core.EngineBehaviour`'s own `execute/3` contract, so `Scry.Search
.Executor` implements it directly — the first kind package to double as
its own engine, rather than requiring a real storage adapter underneath
it. No bespoke `Conn` module exists here either — `SEARCH` needs no new
storage primitive the way `scry_document`'s hierarchical paths or
`scry_graph`'s adjacency index did, only new *execution* logic, so
`conn` is the same plain `%{[String.t(), ...] => [row]}` map every
other in-memory reference engine in this ecosystem already uses.

**`relevance()` needs no grammar contribution at all, and no core
registration either.** An ordinary bare call already parses fine
through core's own generic `call`/`call_arg` production (the same
finding that resolved `scry_time_series`'s own `rate(<duration>)`), so
this package's grammar fragment fills only `comparison_ep1e`. Unlike
`rate`, `relevance` is never registered with `scry_core` as a built-in
at all — `Scry.Search.Executor` rewrites every `{:call, "relevance",
[]}` occurrence (in `select`/`order_bys`) into an ordinary field
reference before `Scry.Core.QueryOps` ever runs, so core never sees the
literal name `"relevance"` in the query it actually evaluates. This is
also why `lang_spec.md` §5/§8.5's own `ORDER BY relevance() DESC`
needed a real, separate `scry_core` change first: `order_bys` widened
from a bare field path to a full expression (see `scry_core`'s own
`CHANGELOG.md`) — without it, that syntax couldn't parse at all,
independent of anything `SEARCH`-specific.

**Four real gaps found in `scry_core` itself while building this** —
every predicate-tree walker that existed before `comparison_ep1e` was
added assumed a closed set of shapes (`{:cmp, ...}`/`{:in, ...}`/
`{:and, ...}`/`{:or, ...}`/`{:not, ...}`) and had no clause for the new
`{:variant, ...}` leaf: `Scry.Core.QueryOps.streaming_predicate_calls/1`,
`predicate_has_aggregate_call?/1`, and `rewrite_predicate_correlation/4`,
plus all three of `Scry.Core.TypeCheck`'s own walkers (`walk_type_check/3`,
`walk_json_check/2`, `check_predicate/4`) — the last three meant parsing
*any* query using `SEARCH` crashed unconditionally, with no `TYPE`
declaration involved at all. All fixed upstream, in `scry_core`; see
that package's own `CHANGELOG.md` for each one.

**The toy relevance scorer, stated plainly**: this is a reference
implementation proving the language construct executes, not an
integration with any real search engine. `<field> SEARCH <needle>`
lowercases and tokenizes both sides on non-letter/non-digit boundaries
and scores a match as the count of `<needle>`'s own tokens also present
among `<field>`'s tokens — a simple token-overlap count, nothing
resembling real fuzzy matching, stemming, or ranked relevance.
`relevance()` is the *sum* of every `SEARCH` clause's own score for
that row, when more than one is present. A row "matches" iff its score
is greater than zero.

**Deliberately out of scope this round, and stated as a clear,
declined-construct error rather than silently mishandled**: `SEARCH`
anywhere inside `HAVING` (a per-row match doesn't obviously aggregate
across a group the way `lang_spec.md`'s own single worked example,
`SEARCH` only ever inside `WHERE`, implies); a `SEARCH` left-hand side
that isn't a bare field path (`predicate_lhs`'s other two shapes,
`{:call, ...}`/`{:dot, ...}`, parse fine but aren't resolved here).
`SEARCH` composes for free with `GROUP BY` and `WITH` bindings (both
handled directly, not declined) — see `Scry.Search.Executor`'s own
moduledoc for the one real, narrower-than-core's-own limit the `WITH`
case has (a bound query's own value can't itself reference a
*different*, outer-scoped `WITH` binding, the identical limit core's
own generic resolution already has).

Source: <https://github.com/joetjen/scry_search>. Specs live in the
separate [`scry`](https://github.com/joetjen/scry) repository; the
composition machinery this composes against lives in
[`scry_core`](https://github.com/joetjen/scry_core).

## Usage

```elixir
alias Scry.Search.Executor

conn = %{
  ["articles"] => [
    %{
      "id" => 1,
      "title" => "Deep Learning Basics",
      "category" => "research",
      "published_at" => ~D[2025-06-01],
      "content" => "Machine learning is a subset of AI."
    },
    %{
      "id" => 2,
      "title" => "Gardening Tips",
      "category" => "research",
      "published_at" => ~D[2025-06-02],
      "content" => "How to grow tomatoes."
    }
  ]
}

{:ok, query} =
  Scry.Search.parse(~s"""
  SELECT articles
      WHERE published_at >= 2025-01-01 AND category = "research" AND content SEARCH "machine learning"
      ORDER BY relevance() DESC LIMIT 5
  {
      title,
      score: relevance()
  }
  """)

{:ok, cursor} = Executor.run(query, conn)
Scry.Core.Cursor.to_list(cursor)
# [%{"title" => "Deep Learning Basics", "score" => 2}]
```

A query with no `SEARCH`/`relevance()` at all parses (and executes)
exactly the way `Scry.Core.parse/1`/`Scry.Core.Executor.run/4` already
handle it — the merged grammar still runs every one of core's own
rules unchanged; only `comparison_ep1e` is new. `Scry.Search.Executor
.run/3` returns a lazy `Scry.Core.Cursor.t()`, the same widened
contract every other kind's own executor already has.

## Installation

```elixir
def deps do
  [
    {:scry_search, "~> 0.1.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_search>.
- Latest `main` is built and deployed automatically by
  [`.github/workflows/docs.yml`](.github/workflows/docs.yml) to
  [GitHub Pages](https://joetjen.github.io/scry_search/) on every push to `main`.
