defmodule Scry.Search.GrammarParityTest do
  @moduledoc """
  A permanent regression guard for the equivalence between `Grammar.VM`
  (interpreted) and `Scry.Search.Grammar.Compiled` (native codegen) for
  the *merged* core+search grammar specifically -- composition, not
  just a single grammar file, is the part most likely to surface a real
  divergence. See `scry_core`'s own
  identical test for the single-grammar case, and every other kind
  package's own identical test for its own extension-point case.
  """

  use ExUnit.Case, async: true

  alias Scry.Search.Grammar.Compiled

  setup_all do
    {:ok, analyzed} = Scry.Search.Grammar.compile()
    %{grammar: analyzed}
  end

  @queries [
    {"plain SEARCH, no other predicates", ~s[SELECT articles WHERE content SEARCH "ml" { id }]},
    {"SEARCH case-insensitive", ~s[SELECT articles WHERE content search "ml" { id }]},
    {"SEARCH combined with AND",
     ~s[SELECT articles WHERE category = "x" AND content SEARCH "ml" { id }]},
    {"SEARCH combined with OR",
     ~s[SELECT articles WHERE category = "x" OR content SEARCH "ml" { id }]},
    {"SEARCH negated with NOT", ~s[SELECT articles WHERE NOT content SEARCH "ml" { id }]},
    {"a plain query with no SEARCH at all", ~s[SELECT articles { title }]},
    {"relevance() as a computed field", ~s[SELECT articles { title, score: relevance() }]},
    {"relevance() in ORDER BY", ~s[SELECT articles ORDER BY relevance() DESC { title }]},
    {"the worked example",
     ~s"""
     SELECT articles
         WHERE published_at >= 2025-01-01 AND category = "research" AND content SEARCH "machine learning"
         ORDER BY relevance() DESC LIMIT 5
     {
         title,
         score: relevance()
     }
     """},
    {"block comment (via a commented-out WITH decl) before a SEARCH query",
     ";with x = SELECT y { z }\nSELECT articles WHERE content SEARCH \"ml\" { id }"},
    {"body items separated by a bare newline, no comma (scry_core's own body_list fix)",
     ~s"""
     SELECT articles WHERE content SEARCH "ml"
     {
         title
         score: relevance()
     }
     """},
    {"a trailing comma before the closing brace (also part of scry_core's own body_list fix)",
     ~s[SELECT articles WHERE content SEARCH "ml" { title, score: relevance(), }]}
  ]

  for {label, query} <- @queries do
    test "#{label}: Grammar.VM and Scry.Search.Grammar.Compiled agree", %{grammar: grammar} do
      vm_result = Grammar.VM.run(grammar, unquote(query), Scry.Search.Actions, nil)
      compiled_result = Compiled.run(unquote(query), nil)

      assert vm_result == compiled_result
    end
  end
end
