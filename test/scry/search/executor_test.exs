defmodule Scry.Search.ExecutorTest do
  @moduledoc """
  `Scry.Search.Executor.run/3` -- `SEARCH`/`relevance()` actually
  filtering and scoring rows, not just parsing. The
  toy token-overlap scorer's own exact arithmetic, composition with
  `GROUP BY` (the pseudo-field-adjacent kinds, `scry_document`/`scry_
  graph`, both needed a real scope limit here; `SEARCH` doesn't, since
  matching happens per-row before grouping, same as any other `WHERE`
  filter), and this module's own two stated scope limits (a non-field
  `SEARCH` left-hand side, `SEARCH` inside `HAVING`) all get real
  coverage, not just claimed.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Scry.Core.Cursor

  @articles [
    %{
      "id" => 1,
      "title" => "Deep Learning Basics",
      "category" => "research",
      "published_at" => ~D[2025-06-01],
      "content" =>
        "Machine learning is a subset of AI, and deep learning is a subset of machine learning."
    },
    %{
      "id" => 2,
      "title" => "Gardening Tips",
      "category" => "research",
      "published_at" => ~D[2025-06-02],
      "content" => "How to grow tomatoes in your machine-tilled garden."
    },
    %{
      "id" => 3,
      "title" => "Old Research",
      "category" => "research",
      "published_at" => ~D[2024-01-01],
      "content" => "Machine learning research from last year."
    },
    %{
      "id" => 4,
      "title" => "News",
      "category" => "news",
      "published_at" => ~D[2025-06-03],
      "content" => "Machine learning is in the news."
    }
  ]

  @conn %{["articles"] => @articles}

  defp run!(query_text, conn \\ @conn) do
    {:ok, query} = Scry.Search.parse(query_text)
    {:ok, cursor} = Scry.Search.Executor.run(query, conn)
    Cursor.to_list(cursor)
  end

  test "run/3 returns a real Scry.Core.Cursor.t()" do
    {:ok, query} = Scry.Search.parse(~s[SELECT articles { title }])
    assert {:ok, %Cursor{}} = Scry.Search.Executor.run(query, @conn)
  end

  test "the worked example runs correctly end to end" do
    rows =
      run!("""
      SELECT articles
          WHERE published_at >= 2025-01-01 AND category = "research" AND content SEARCH "machine learning"
          ORDER BY relevance() DESC LIMIT 5
      {
          title,
          score: relevance()
      }
      """)

    # "Old Research" excluded (published before the WHERE cutoff);
    # "News" excluded (wrong category). "Deep Learning Basics" scores 2
    # (both "machine" and "learning" tokens present); "Gardening Tips"
    # scores 1 (only "machine", via "machine-tilled" tokenizing to
    # "machine") -- sorted descending by score.
    assert rows == [
             %{"title" => "Deep Learning Basics", "score" => 2},
             %{"title" => "Gardening Tips", "score" => 1}
           ]
  end

  test "a row with no token overlap at all does not match, and is excluded" do
    rows = run!(~s[SELECT articles WHERE content SEARCH "xylophone" { title }])
    assert rows == []
  end

  test "SEARCH is a case-insensitive, token-overlap count -- not a substring match" do
    conn = %{["items"] => [%{"id" => 1, "text" => "The Quick Brown Fox"}]}
    rows = run!(~s[SELECT items WHERE text SEARCH "quick fox" { id }], conn)
    assert rows == [%{"id" => 1}]
  end

  test "a field value of nil never matches, no crash" do
    conn = %{["items"] => [%{"id" => 1, "text" => nil}]}
    rows = run!(~s[SELECT items WHERE text SEARCH "anything" { id }], conn)
    assert rows == []
  end

  test "SEARCH negated with NOT correctly inverts the match" do
    rows = run!(~s[SELECT articles WHERE NOT content SEARCH "machine" { id }])
    assert rows == []

    rows2 = run!(~s[SELECT articles WHERE NOT content SEARCH "xylophone" { id }])
    assert length(rows2) == 4
  end

  test "SEARCH combined with OR widens the match set" do
    rows =
      run!(~s[SELECT articles WHERE category = "news" OR content SEARCH "tomatoes" { title }])

    assert Enum.sort(Enum.map(rows, & &1["title"])) == Enum.sort(["Gardening Tips", "News"])
  end

  test "relevance() with no SEARCH anywhere in the query is always 0, not an error" do
    rows = run!(~s[SELECT articles WHERE category = "news" { title, score: relevance() }])
    assert rows == [%{"title" => "News", "score" => 0}]
  end

  test "two SEARCH clauses on the same row sum their scores under relevance()" do
    conn = %{
      ["items"] => [%{"id" => 1, "title" => "machine learning", "body" => "deep learning ai"}]
    }

    rows =
      run!(
        ~s[SELECT items WHERE title SEARCH "machine" AND body SEARCH "deep learning" { id, score: relevance() }],
        conn
      )

    assert rows == [%{"id" => 1, "score" => 3}]
  end

  test "a plain query with no SEARCH/relevance() at all behaves exactly as an ordinary query" do
    rows = run!(~s[SELECT articles WHERE category = "news" { title }])
    assert rows == [%{"title" => "News"}]
  end

  describe "composes with GROUP BY -- matching happens per row, before grouping" do
    test "GROUP BY with a SEARCH-filtered WHERE" do
      rows =
        run!(
          ~s[SELECT articles WHERE content SEARCH "machine" GROUP BY category { category, n: count(id) }]
        )

      assert Enum.sort(rows) ==
               Enum.sort([
                 %{"category" => "research", "n" => 3},
                 %{"category" => "news", "n" => 1}
               ])
    end
  end

  describe "stated scope limits, not silently mishandled" do
    test "SEARCH anywhere in HAVING is a clear, declined-construct error" do
      {:ok, query} = Scry.Search.parse(~s[SELECT articles HAVING content SEARCH "x" { id }])

      assert Scry.Search.Executor.run(query, @conn) ==
               {:error, {:unsupported, {:construct, :search_in_having}}}
    end

    test "SEARCH nested inside AND/OR inside HAVING is caught too, not just a bare HAVING" do
      {:ok, query} =
        Scry.Search.parse(
          ~s[SELECT articles GROUP BY category HAVING count(id) > 0 AND content SEARCH "x" { category }]
        )

      assert Scry.Search.Executor.run(query, @conn) ==
               {:error, {:unsupported, {:construct, :search_in_having}}}
    end

    test "a non-field SEARCH left-hand side is a clear, declined-construct error, checked before any row is touched" do
      {:ok, query} = Scry.Search.parse(~s[SELECT articles WHERE json(content) SEARCH "x" { id }])

      assert Scry.Search.Executor.run(query, @conn) ==
               {:error, {:unsupported, {:construct, :search_lhs_not_a_field}}}
    end

    test "a SEARCH left-hand side resolving to a non-String, non-nil value hard-errors clearly" do
      conn = %{["items"] => [%{"id" => 1, "text" => 42}]}
      {:ok, query} = Scry.Search.parse(~s[SELECT items WHERE text SEARCH "x" { id }])

      assert_raise ArgumentError, ~r/must resolve to a String/, fn ->
        {:ok, cursor} = Scry.Search.Executor.run(query, conn)
        Cursor.to_list(cursor)
      end
    end
  end

  describe "an unknown source surfaces the same error shape any other engine already produces" do
    test "no such source" do
      {:ok, query} = Scry.Search.parse(~s[SELECT nonexistent { id }])

      assert Scry.Search.Executor.run(query, @conn) ==
               {:error, {:query_error, {:no_such_source, ["nonexistent"]}}}
    end
  end

  describe "generic Scry.Core.QueryOps.run_document/4 orchestration, reused for free" do
    test "a WITH binding composes correctly" do
      rows =
        run!("""
        WITH recent = SELECT articles WHERE published_at >= 2025-01-01 { id, title, content }
        SELECT recent WHERE content SEARCH "machine" { title }
        """)

      assert Enum.sort(Enum.map(rows, & &1["title"])) ==
               Enum.sort(["Deep Learning Basics", "Gardening Tips", "News"])
    end

    test "UNION across two SEARCH-filtered sources composes correctly" do
      conn = %{
        ["a"] => [%{"id" => 1, "name" => "Alice", "bio" => "loves machine learning"}],
        ["b"] => [%{"id" => 2, "name" => "Bob", "bio" => "loves gardening"}]
      }

      rows =
        run!(
          """
          SELECT a WHERE bio SEARCH "machine" { name }
          UNION
          SELECT b WHERE bio SEARCH "gardening" { name }
          """,
          conn
        )

      assert Enum.sort(Enum.map(rows, & &1["name"])) == Enum.sort(["Alice", "Bob"])
    end

    test "a correlated nested SELECT composes correctly" do
      # A nested SELECT is a *bare* body item (no `alias:` prefix --
      # `Scry.Core.Query`'s own moduledoc: it's `t()` directly, already
      # self-describing via its struct); the projected key is the
      # nested query's own source name, `"articles"`.
      conn = %{
        ["authors"] => [%{"id" => 1, "name" => "Alice"}],
        ["articles"] => Enum.map(@articles, &Map.put(&1, "author_id", 1))
      }

      rows =
        run!(
          """
          SELECT authors {
              name,
              SELECT articles WHERE author_id = authors.id AND content SEARCH "machine" { title }
          }
          """,
          conn
        )

      # All 4 fixture articles' own content contains "machine" as a
      # token (including "Old Research" and "News" -- unlike the
      # worked-example test above, this query has no WHERE/category
      # filter at all beyond the correlation itself).
      assert [%{"name" => "Alice", "articles" => matches}] = rows
      assert length(matches) == 4
    end
  end

  # Per AGENTS.md's own guidance: the toy scorer's input space (any two
  # strings) is bigger than a handful of hand-picked examples usefully
  # covers, so its core match/no-match invariant gets a property test
  # -- a naive independent reference (case-insensitive word-set
  # intersection) rather than more hand-picked cases.
  property "matches iff needle and content share at least one case-insensitive word, against a naive reference" do
    vocabulary = ~w(alpha beta gamma delta epsilon zeta)

    check all(
            content_words <- list_of(member_of(vocabulary), min_length: 0, max_length: 5),
            needle_words <- list_of(member_of(vocabulary), min_length: 1, max_length: 3)
          ) do
      content = Enum.join(content_words, " ")
      needle = Enum.join(needle_words, " ")

      conn = %{["items"] => [%{"id" => 1, "text" => content}]}
      rows = run!(~s[SELECT items WHERE text SEARCH "#{needle}" { id }], conn)

      expected_match? =
        MapSet.disjoint?(MapSet.new(content_words), MapSet.new(needle_words)) == false

      assert rows != [] == expected_match?
    end
  end
end
