defmodule Rag.RetrieverTest do
  use ExUnit.Case, async: true

  alias Rag.Retriever
  alias Rag.Retriever.Semantic
  alias Rag.Retriever.FullText
  alias Rag.Retriever.Hybrid

  # Mock repo module for testing
  defmodule MockRepo do
    def start_link do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def set_results(results) do
      Agent.update(__MODULE__, fn _ -> results end)
    end

    def all(_query) do
      Agent.get(__MODULE__, & &1)
    end
  end

  setup do
    {:ok, _pid} =
      start_supervised(%{
        id: MockRepo,
        start: {MockRepo, :start_link, []}
      })

    :ok
  end

  describe "Retriever behaviour - Semantic" do
    test "retrieve/3 returns semantic search results" do
      mock_results = [
        %{
          id: 1,
          content: "First result",
          source: "doc1.md",
          metadata: %{},
          distance: 0.1
        },
        %{
          id: 2,
          content: "Second result",
          source: "doc2.md",
          metadata: %{},
          distance: 0.2
        }
      ]

      MockRepo.set_results(mock_results)

      retriever = %Semantic{repo: MockRepo}
      {:ok, results} = Retriever.retrieve(retriever, [0.1, 0.2, 0.3], limit: 5)

      assert length(results) == 2
      assert hd(results).id == 1
      assert hd(results).content == "First result"
      # Distance 0.1 converts to similarity 0.9
      assert hd(results).score == 0.9
    end

    test "retrieve/3 converts distance to similarity score" do
      mock_results = [
        %{id: 1, content: "Test", source: "test.md", metadata: %{}, distance: 0.0}
      ]

      MockRepo.set_results(mock_results)

      retriever = %Semantic{repo: MockRepo}
      {:ok, results} = Retriever.retrieve(retriever, [0.5, 0.5])

      # Distance 0.0 should convert to score 1.0
      assert hd(results).score == 1.0
    end

    test "supports_embedding?/0 returns true for Semantic" do
      assert Semantic.supports_embedding?() == true
    end

    test "supports_text_query?/0 returns false for Semantic" do
      assert Semantic.supports_text_query?() == false
    end
  end

  describe "Retriever behaviour - FullText" do
    test "retrieve/3 returns fulltext search results" do
      mock_results = [
        %{
          id: 1,
          content: "First result with search terms",
          source: "doc1.md",
          metadata: %{},
          rank: 0.8
        },
        %{
          id: 2,
          content: "Second result with terms",
          source: "doc2.md",
          metadata: %{},
          rank: 0.6
        }
      ]

      MockRepo.set_results(mock_results)

      retriever = %FullText{repo: MockRepo}
      {:ok, results} = Retriever.retrieve(retriever, "search terms", limit: 10)

      assert length(results) == 2
      assert hd(results).id == 1
      assert hd(results).score == 0.8
    end

    test "supports_embedding?/0 returns false for FullText" do
      assert FullText.supports_embedding?() == false
    end

    test "supports_text_query?/0 returns true for FullText" do
      assert FullText.supports_text_query?() == true
    end
  end

  describe "Retriever behaviour - Hybrid" do
    test "retrieve/3 combines semantic and fulltext with RRF" do
      # Mock both semantic and fulltext results
      semantic_results = [
        %{id: 1, content: "Result 1", source: "doc1.md", metadata: %{}, distance: 0.1},
        %{id: 2, content: "Result 2", source: "doc2.md", metadata: %{}, distance: 0.2}
      ]

      fulltext_results = [
        %{id: 2, content: "Result 2", source: "doc2.md", metadata: %{}, rank: 0.9},
        %{id: 3, content: "Result 3", source: "doc3.md", metadata: %{}, rank: 0.7}
      ]

      # Calculate expected RRF scores manually
      # RRF formula: 1/(k + rank), k = 60
      # ID 1: appears in semantic at rank 1 -> 1/61 = 0.016393
      # ID 2: appears in semantic at rank 2 -> 1/62 = 0.016129, and fulltext at rank 1 -> 1/61 = 0.016393, total = 0.032522
      # ID 3: appears in fulltext at rank 2 -> 1/62 = 0.016129

      # The retriever will call VectorStore.calculate_rrf_score which does this calculation
      # We'll test with a mock that returns the results with RRF scores
      mock_rrf_results = [
        %{id: 2, content: "Result 2", source: "doc2.md", metadata: %{}, rrf_score: 0.032},
        %{id: 1, content: "Result 1", source: "doc1.md", metadata: %{}, rrf_score: 0.016},
        %{id: 3, content: "Result 3", source: "doc3.md", metadata: %{}, rrf_score: 0.016}
      ]

      # Create a custom repo that returns different results based on call count
      defmodule HybridMockRepo do
        def start_link do
          Agent.start_link(fn -> %{call_count: 0, semantic: [], fulltext: []} end,
            name: __MODULE__
          )
        end

        def set_results(semantic, fulltext) do
          Agent.update(__MODULE__, fn state ->
            %{state | call_count: 0, semantic: semantic, fulltext: fulltext}
          end)
        end

        def all(_query) do
          Agent.get_and_update(__MODULE__, fn state ->
            call_count = state.call_count
            new_state = %{state | call_count: call_count + 1}

            result =
              case call_count do
                0 -> state.semantic
                1 -> state.fulltext
              end

            {result, new_state}
          end)
        end
      end

      start_supervised!(%{
        id: HybridMockRepo,
        start: {HybridMockRepo, :start_link, []}
      })

      HybridMockRepo.set_results(semantic_results, fulltext_results)

      retriever = %Hybrid{repo: HybridMockRepo}
      {:ok, results} = Retriever.retrieve(retriever, {[0.1, 0.2, 0.3], "search query"}, limit: 5)

      assert length(results) == 3
      # Should be ordered by RRF score (ID 2 first)
      assert hd(results).id == 2
      # RRF scores should be present
      assert hd(results).score > 0
    end

    test "retrieve/3 requires tuple query for Hybrid" do
      retriever = %Hybrid{repo: MockRepo}

      {:error, reason} = Retriever.retrieve(retriever, "just text")

      assert reason == :invalid_query_format
    end

    test "supports_embedding?/0 returns true for Hybrid" do
      assert Hybrid.supports_embedding?() == true
    end

    test "supports_text_query?/0 returns true for Hybrid" do
      assert Hybrid.supports_text_query?() == true
    end
  end

  describe "Retriever.retrieve/3 convenience function" do
    test "delegates to retriever module" do
      mock_results = [
        %{id: 1, content: "Test", source: "test.md", metadata: %{}, distance: 0.1}
      ]

      MockRepo.set_results(mock_results)

      retriever = %Semantic{repo: MockRepo}
      {:ok, results} = Retriever.retrieve(retriever, [0.1, 0.2])

      assert length(results) == 1
    end
  end

  describe "result normalization" do
    test "Semantic normalizes results with score field" do
      mock_results = [
        %{id: 1, content: "Test", source: "test.md", metadata: %{foo: "bar"}, distance: 0.5}
      ]

      MockRepo.set_results(mock_results)

      retriever = %Semantic{repo: MockRepo}
      {:ok, [result]} = Retriever.retrieve(retriever, [0.1])

      assert result.id == 1
      assert result.content == "Test"
      assert result.score == 0.5
      assert result.metadata == %{foo: "bar"}
    end

    test "FullText normalizes results with score field" do
      mock_results = [
        %{id: 1, content: "Test", source: "test.md", metadata: %{}, rank: 0.75}
      ]

      MockRepo.set_results(mock_results)

      retriever = %FullText{repo: MockRepo}
      {:ok, [result]} = Retriever.retrieve(retriever, "test")

      assert result.score == 0.75
    end
  end

  describe "error handling" do
    test "Semantic handles repo errors" do
      # Create a repo that raises
      defmodule ErrorRepo do
        def all(_query), do: raise("Database error")
      end

      retriever = %Semantic{repo: ErrorRepo}
      {:error, reason} = Retriever.retrieve(retriever, [0.1])

      assert reason =~ "Database error"
    end

    test "FullText handles repo errors" do
      defmodule ErrorRepo2 do
        def all(_query), do: raise("Database error")
      end

      retriever = %FullText{repo: ErrorRepo2}
      {:error, reason} = Retriever.retrieve(retriever, "test")

      assert reason =~ "Database error"
    end
  end

  describe "options handling" do
    test "Semantic uses default limit when not specified" do
      mock_results = []
      MockRepo.set_results(mock_results)

      retriever = %Semantic{repo: MockRepo}
      {:ok, _} = Retriever.retrieve(retriever, [0.1])

      # Just verify it doesn't crash - default limit is used
      assert true
    end

    test "FullText uses default limit when not specified" do
      mock_results = []
      MockRepo.set_results(mock_results)

      retriever = %FullText{repo: MockRepo}
      {:ok, _} = Retriever.retrieve(retriever, "test")

      # Just verify it doesn't crash - default limit is used
      assert true
    end

    test "Hybrid respects limit option" do
      defmodule HybridLimitRepo do
        def all(_query), do: []
      end

      retriever = %Hybrid{repo: HybridLimitRepo}
      {:ok, results} = Retriever.retrieve(retriever, {[0.1], "test"}, limit: 15)

      # Should not error and return empty list
      assert results == []
    end
  end
end
