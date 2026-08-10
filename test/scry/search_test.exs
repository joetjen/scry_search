defmodule Scry.SearchTest do
  use ExUnit.Case, async: true

  alias Scry.Core.Query

  test "SEARCH resolves into a {:variant, {:search, left, needle}} predicate leaf in WHERE" do
    assert {:ok, %Query{} = q} =
             Scry.Search.parse(
               ~s[SELECT articles WHERE content SEARCH "machine learning" { title }]
             )

    assert q.wheres == [{:variant, {:search, ["content"], "machine learning"}}]
  end

  test "SEARCH is case-insensitive, matching every other structural keyword" do
    assert {:ok, %Query{} = q} =
             Scry.Search.parse(~s[SELECT articles WHERE content search "x" { title }])

    assert q.wheres == [{:variant, {:search, ["content"], "x"}}]
  end

  test "SEARCH composes with an ordinary core AND/OR alongside it" do
    assert {:ok, %Query{} = q} =
             Scry.Search.parse(
               ~s[SELECT articles WHERE category = "research" AND content SEARCH "ml" { title }]
             )

    assert q.wheres == [
             {:and, {:cmp, :eq, ["category"], "research"},
              {:variant, {:search, ["content"], "ml"}}}
           ]
  end

  test "SEARCH negated with NOT still resolves correctly" do
    assert {:ok, %Query{} = q} =
             Scry.Search.parse(~s[SELECT articles WHERE NOT content SEARCH "x" { title }])

    assert q.wheres == [{:not, {:variant, {:search, ["content"], "x"}}}]
  end

  test "a plain query with no SEARCH at all parses exactly as Scry.Core.parse/1 already would" do
    assert {:ok, %Query{} = q} = Scry.Search.parse(~s[SELECT articles { title }])
    assert q.wheres == []
    assert q.select == [{:field, ["title"]}]
  end

  test "relevance() needs no grammar contribution -- an ordinary bare call, parsed generically" do
    assert {:ok, %Query{} = q} =
             Scry.Search.parse(~s[SELECT articles { title, score: relevance() }])

    assert q.select == [
             {:field, ["title"]},
             {:computed, "score", {:call, "relevance", []}}
           ]
  end

  test "ORDER BY relevance() DESC parses via core's own widened ORDER BY grammar" do
    assert {:ok, %Query{} = q} =
             Scry.Search.parse(~s[SELECT articles ORDER BY relevance() DESC { title }])

    assert q.order_bys == [{{:call, "relevance", []}, :desc}]
  end

  test "the lang_spec.md §8.5 worked example parses end to end" do
    # A comma between body items, unlike the spec's own prose (written
    # GraphQL-style, no separator) -- scry_core's own body_list
    # production is `head:body_item (COMMA tail:body_item)*`, a real
    # requirement, not a stylistic choice the prose happens to skip.
    query = """
    SELECT articles
        WHERE published_at >= 2025-01-01 AND category = "research" AND content SEARCH "machine learning"
        ORDER BY relevance() DESC LIMIT 5
    {
        title,
        score: relevance()
    }
    """

    assert {:ok, %Query{} = q} = Scry.Search.parse(query)

    assert q.wheres == [
             {:and,
              {:and, {:cmp, :ge, ["published_at"], ~D[2025-01-01]},
               {:cmp, :eq, ["category"], "research"}},
              {:variant, {:search, ["content"], "machine learning"}}}
           ]

    assert q.order_bys == [{{:call, "relevance", []}, :desc}]
    assert q.limit == 5

    assert q.select == [
             {:field, ["title"]},
             {:computed, "score", {:call, "relevance", []}}
           ]
  end
end
