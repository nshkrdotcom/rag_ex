defmodule Rag.Retriever.GraphTest do
  use ExUnit.Case, async: true

  alias Rag.Retriever
  alias Rag.Retriever.Graph

  @embedding_dimension 768

  # Mock modules for testing
  defmodule MockGraphStore do
    defstruct [:responses]

    def new do
      %__MODULE__{responses: %{}}
    end

    def set_response(store, function, response) do
      %{store | responses: Map.put(store.responses, function, response)}
    end

    def vector_search(store, _embedding, _opts) do
      Map.get(store.responses, :vector_search, {:ok, []})
    end

    def traverse(store, _node_id, _opts) do
      Map.get(store.responses, :traverse, {:ok, []})
    end

    def search_communities(store, _embedding, _opts) do
      Map.get(store.responses, :search_communities, {:ok, []})
    end
  end

  defmodule MockVectorStore do
    defstruct [:responses]

    def new do
      %__MODULE__{responses: %{}}
    end

    def set_response(store, function, response) do
      %{store | responses: Map.put(store.responses, function, response)}
    end

    def get_chunks_by_ids(store, _ids) do
      Map.get(store.responses, :get_chunks_by_ids, {:ok, []})
    end
  end

  # Custom graph store with configurable responses
  defmodule CustomGraphStore do
    defstruct [
      :vector_search_response,
      :traverse_responses,
      :search_communities_response
    ]

    def vector_search(store, _embedding, _opts) do
      store.vector_search_response || {:ok, []}
    end

    def traverse(store, node_id, _opts) do
      case store.traverse_responses do
        nil -> {:ok, []}
        responses -> Map.get(responses, node_id, {:ok, []})
      end
    end

    def search_communities(store, _embedding, _opts) do
      store.search_communities_response || {:ok, []}
    end
  end

  describe "Graph.new/1" do
    test "creates a graph retriever with default options" do
      graph_store = MockGraphStore.new()
      vector_store = MockVectorStore.new()

      retriever =
        Graph.new(
          graph_store: graph_store,
          vector_store: vector_store
        )

      assert %Graph{} = retriever
      assert retriever.graph_store == graph_store
      assert retriever.vector_store == vector_store
      assert retriever.mode == :local
      assert retriever.depth == 2
      assert retriever.local_weight == 1.0
      assert retriever.global_weight == 1.0
    end

    test "creates a graph retriever with custom mode" do
      retriever =
        Graph.new(
          graph_store: MockGraphStore.new(),
          vector_store: MockVectorStore.new(),
          mode: :global
        )

      assert retriever.mode == :global
    end

    test "creates a graph retriever with custom depth" do
      retriever =
        Graph.new(
          graph_store: MockGraphStore.new(),
          vector_store: MockVectorStore.new(),
          depth: 3
        )

      assert retriever.depth == 3
    end

    test "creates a graph retriever with custom weights" do
      retriever =
        Graph.new(
          graph_store: MockGraphStore.new(),
          vector_store: MockVectorStore.new(),
          mode: :hybrid,
          local_weight: 0.7,
          global_weight: 0.3
        )

      assert retriever.local_weight == 0.7
      assert retriever.global_weight == 0.3
    end
  end

  describe "Graph.retrieve/3 with local search mode" do
    test "performs local search with entity expansion" do
      query_embedding = random_embedding()

      # Seed entities from vector search
      seed_entities = [
        %{id: 1, name: "Alice", type: "person", source_chunk_ids: [101, 102]},
        %{id: 2, name: "Bob", type: "person", source_chunk_ids: [103]}
      ]

      # Expanded entities from graph traversal
      expanded_entities_1 = [
        %{id: 1, name: "Alice", type: "person", source_chunk_ids: [101, 102], depth: 0},
        %{id: 3, name: "Carol", type: "person", source_chunk_ids: [104, 105], depth: 1}
      ]

      expanded_entities_2 = [
        %{id: 2, name: "Bob", type: "person", source_chunk_ids: [103], depth: 0}
      ]

      # Chunks from vector store
      chunks = [
        %{id: 101, content: "Alice works at Acme", metadata: %{}},
        %{id: 102, content: "Alice knows Bob", metadata: %{}},
        %{id: 103, content: "Bob is a developer", metadata: %{}},
        %{id: 104, content: "Carol leads the team", metadata: %{}},
        %{id: 105, content: "Carol mentors Alice", metadata: %{}}
      ]

      vector_store =
        MockVectorStore.new()
        |> MockVectorStore.set_response(:get_chunks_by_ids, {:ok, chunks})

      # Create custom graph store that returns different results based on node_id
      custom_graph_store = %CustomGraphStore{
        vector_search_response: {:ok, seed_entities},
        traverse_responses: %{
          1 => {:ok, expanded_entities_1},
          2 => {:ok, expanded_entities_2}
        }
      }

      retriever =
        Graph.new(
          graph_store: custom_graph_store,
          vector_store: vector_store,
          mode: :local,
          depth: 2
        )

      {:ok, results} = Retriever.retrieve(retriever, query_embedding, limit: 5)

      assert length(results) == 5
      assert Enum.all?(results, fn r -> Map.has_key?(r, :content) end)
      assert Enum.all?(results, fn r -> Map.has_key?(r, :score) end)
      assert Enum.all?(results, fn r -> r.score >= 0 end)
    end

    test "handles empty entity search results" do
      query_embedding = random_embedding()

      graph_store =
        MockGraphStore.new()
        |> MockGraphStore.set_response(:vector_search, {:ok, []})

      retriever =
        Graph.new(
          graph_store: graph_store,
          vector_store: MockVectorStore.new(),
          mode: :local
        )

      {:ok, results} = Retriever.retrieve(retriever, query_embedding)

      assert results == []
    end

    test "handles graph traversal errors gracefully" do
      query_embedding = random_embedding()

      seed_entities = [
        %{id: 1, name: "Alice", type: "person", source_chunk_ids: [101]}
      ]

      custom_graph_store = %CustomGraphStore{
        vector_search_response: {:ok, seed_entities},
        traverse_responses: %{1 => {:error, :traversal_failed}}
      }

      retriever =
        Graph.new(
          graph_store: custom_graph_store,
          vector_store: MockVectorStore.new(),
          mode: :local
        )

      {:error, reason} = Retriever.retrieve(retriever, query_embedding)

      assert reason == :traversal_failed
    end
  end

  describe "Graph.retrieve/3 with global search mode" do
    test "performs global search on community summaries" do
      query_embedding = random_embedding()

      # Mock communities with summaries
      communities = [
        %{
          id: 1,
          level: 0,
          summary: "A team of developers working on AI projects",
          entity_ids: [1, 2, 3]
        },
        %{
          id: 2,
          level: 0,
          summary: "Marketing team handling product launches",
          entity_ids: [4, 5]
        }
      ]

      graph_store =
        MockGraphStore.new()
        |> MockGraphStore.set_response(:search_communities, {:ok, communities})

      retriever =
        Graph.new(
          graph_store: graph_store,
          vector_store: MockVectorStore.new(),
          mode: :global
        )

      {:ok, results} = Retriever.retrieve(retriever, query_embedding, limit: 10)

      assert length(results) == 2
      assert hd(results).content =~ "developers working on AI"
      assert Enum.all?(results, fn r -> Map.has_key?(r, :score) end)
      assert Enum.all?(results, fn r -> Map.has_key?(r, :metadata) end)
    end

    test "handles empty community results" do
      query_embedding = random_embedding()

      graph_store =
        MockGraphStore.new()
        |> MockGraphStore.set_response(:search_communities, {:ok, []})

      retriever =
        Graph.new(
          graph_store: graph_store,
          vector_store: MockVectorStore.new(),
          mode: :global
        )

      {:ok, results} = Retriever.retrieve(retriever, query_embedding)

      assert results == []
    end

    test "handles search_communities errors" do
      query_embedding = random_embedding()

      graph_store =
        MockGraphStore.new()
        |> MockGraphStore.set_response(:search_communities, {:error, :search_failed})

      retriever =
        Graph.new(
          graph_store: graph_store,
          vector_store: MockVectorStore.new(),
          mode: :global
        )

      {:error, reason} = Retriever.retrieve(retriever, query_embedding)

      assert reason == :search_failed
    end
  end

  describe "Graph.retrieve/3 with hybrid search mode" do
    test "combines local and global search with RRF" do
      query_embedding = random_embedding()

      # Local search results
      seed_entities = [
        %{id: 1, name: "Alice", type: "person", source_chunk_ids: [101]}
      ]

      expanded_entities = [
        %{id: 1, name: "Alice", type: "person", source_chunk_ids: [101], depth: 0}
      ]

      chunks = [
        %{id: 101, content: "Alice works at Acme", metadata: %{}}
      ]

      # Global search results
      communities = [
        %{
          id: 1,
          level: 0,
          summary: "Development team at Acme Corp",
          entity_ids: [1, 2]
        }
      ]

      custom_graph_store = %CustomGraphStore{
        vector_search_response: {:ok, seed_entities},
        traverse_responses: %{1 => {:ok, expanded_entities}},
        search_communities_response: {:ok, communities}
      }

      vector_store =
        MockVectorStore.new()
        |> MockVectorStore.set_response(:get_chunks_by_ids, {:ok, chunks})

      retriever =
        Graph.new(
          graph_store: custom_graph_store,
          vector_store: vector_store,
          mode: :hybrid,
          local_weight: 0.6,
          global_weight: 0.4
        )

      {:ok, results} = Retriever.retrieve(retriever, query_embedding, limit: 10)

      # Should have results from both local and global
      assert length(results) >= 1
      assert Enum.all?(results, fn r -> Map.has_key?(r, :content) end)
      assert Enum.all?(results, fn r -> Map.has_key?(r, :score) end)
    end

    test "handles when local search returns nothing" do
      query_embedding = random_embedding()

      communities = [
        %{id: 1, level: 0, summary: "Test community", entity_ids: [1]}
      ]

      custom_graph_store = %CustomGraphStore{
        vector_search_response: {:ok, []},
        search_communities_response: {:ok, communities}
      }

      retriever =
        Graph.new(
          graph_store: custom_graph_store,
          vector_store: MockVectorStore.new(),
          mode: :hybrid
        )

      {:ok, results} = Retriever.retrieve(retriever, query_embedding)

      # Should still have global results
      assert length(results) == 1
    end

    test "handles when global search returns nothing" do
      query_embedding = random_embedding()

      seed_entities = [
        %{id: 1, name: "Alice", type: "person", source_chunk_ids: [101]}
      ]

      expanded_entities = [
        %{id: 1, name: "Alice", type: "person", source_chunk_ids: [101], depth: 0}
      ]

      chunks = [
        %{id: 101, content: "Alice works at Acme", metadata: %{}}
      ]

      custom_graph_store = %CustomGraphStore{
        vector_search_response: {:ok, seed_entities},
        traverse_responses: %{1 => {:ok, expanded_entities}},
        search_communities_response: {:ok, []}
      }

      vector_store =
        MockVectorStore.new()
        |> MockVectorStore.set_response(:get_chunks_by_ids, {:ok, chunks})

      retriever =
        Graph.new(
          graph_store: custom_graph_store,
          vector_store: vector_store,
          mode: :hybrid
        )

      {:ok, results} = Retriever.retrieve(retriever, query_embedding)

      # Should still have local results
      assert length(results) == 1
    end
  end

  describe "Graph.local_search/3" do
    test "performs vector search, graph expansion, and chunk retrieval" do
      query_embedding = random_embedding()

      seed_entities = [
        %{id: 1, name: "Alice", type: "person", source_chunk_ids: [101, 102]}
      ]

      expanded_entities = [
        %{id: 1, name: "Alice", type: "person", source_chunk_ids: [101, 102], depth: 0},
        %{id: 2, name: "Bob", type: "person", source_chunk_ids: [103], depth: 1}
      ]

      chunks = [
        %{id: 101, content: "Alice content 1", metadata: %{}},
        %{id: 102, content: "Alice content 2", metadata: %{}},
        %{id: 103, content: "Bob content", metadata: %{}}
      ]

      custom_graph_store = %CustomGraphStore{
        vector_search_response: {:ok, seed_entities},
        traverse_responses: %{1 => {:ok, expanded_entities}}
      }

      vector_store =
        MockVectorStore.new()
        |> MockVectorStore.set_response(:get_chunks_by_ids, {:ok, chunks})

      retriever =
        Graph.new(
          graph_store: custom_graph_store,
          vector_store: vector_store,
          depth: 2
        )

      {:ok, results} = Graph.local_search(retriever, query_embedding, limit: 10)

      assert length(results) == 3
      assert Enum.all?(results, fn r -> Map.has_key?(r, :content) end)
      assert Enum.all?(results, fn r -> Map.has_key?(r, :score) end)
    end

    test "accepts text query with embedding function" do
      query_text = "Who is Alice?"
      query_embedding = random_embedding()

      embedding_fn = fn text ->
        assert text == query_text
        {:ok, query_embedding}
      end

      seed_entities = [
        %{id: 1, name: "Alice", type: "person", source_chunk_ids: [101]}
      ]

      custom_graph_store = %CustomGraphStore{
        vector_search_response: {:ok, seed_entities},
        traverse_responses: %{1 => {:ok, seed_entities |> Enum.map(&Map.put(&1, :depth, 0))}}
      }

      vector_store =
        MockVectorStore.new()
        |> MockVectorStore.set_response(
          :get_chunks_by_ids,
          {:ok, [%{id: 101, content: "Alice is a person", metadata: %{}}]}
        )

      retriever =
        Graph.new(
          graph_store: custom_graph_store,
          vector_store: vector_store
        )

      {:ok, results} = Graph.local_search(retriever, query_text, embedding_fn: embedding_fn)

      assert length(results) == 1
    end

    test "scores results by relevance and graph distance" do
      query_embedding = random_embedding()

      seed_entities = [
        %{id: 1, name: "Alice", type: "person", source_chunk_ids: [101]}
      ]

      expanded_entities = [
        %{id: 1, name: "Alice", type: "person", source_chunk_ids: [101], depth: 0},
        %{id: 2, name: "Bob", type: "person", source_chunk_ids: [102], depth: 1},
        %{id: 3, name: "Carol", type: "person", source_chunk_ids: [103], depth: 2}
      ]

      chunks = [
        %{id: 101, content: "Alice", metadata: %{}},
        %{id: 102, content: "Bob", metadata: %{}},
        %{id: 103, content: "Carol", metadata: %{}}
      ]

      custom_graph_store = %CustomGraphStore{
        vector_search_response: {:ok, seed_entities},
        traverse_responses: %{1 => {:ok, expanded_entities}}
      }

      vector_store =
        MockVectorStore.new()
        |> MockVectorStore.set_response(:get_chunks_by_ids, {:ok, chunks})

      retriever =
        Graph.new(
          graph_store: custom_graph_store,
          vector_store: vector_store,
          depth: 2
        )

      {:ok, results} = Graph.local_search(retriever, query_embedding)

      # Results should be ordered by score (higher is better)
      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)

      # Closer nodes should have higher scores
      first_result = hd(results)
      last_result = List.last(results)
      assert first_result.score >= last_result.score
    end
  end

  describe "Graph.global_search/3" do
    test "searches community summaries" do
      query_embedding = random_embedding()

      communities = [
        %{
          id: 1,
          level: 0,
          summary: "Engineering team working on AI",
          entity_ids: [1, 2, 3]
        },
        %{
          id: 2,
          level: 1,
          summary: "Product management division",
          entity_ids: [4, 5]
        }
      ]

      graph_store =
        MockGraphStore.new()
        |> MockGraphStore.set_response(:search_communities, {:ok, communities})

      retriever =
        Graph.new(
          graph_store: graph_store,
          vector_store: MockVectorStore.new()
        )

      {:ok, results} = Graph.global_search(retriever, query_embedding, limit: 5)

      assert length(results) == 2
      assert hd(results).content == "Engineering team working on AI"
      assert hd(results).metadata.community_id == 1
      assert hd(results).metadata.level == 0
      assert hd(results).metadata.entity_count == 3
    end

    test "accepts text query with embedding function" do
      query_text = "What teams exist?"
      query_embedding = random_embedding()

      embedding_fn = fn text ->
        assert text == query_text
        {:ok, query_embedding}
      end

      communities = [
        %{id: 1, level: 0, summary: "Development team", entity_ids: [1, 2]}
      ]

      graph_store =
        MockGraphStore.new()
        |> MockGraphStore.set_response(:search_communities, {:ok, communities})

      retriever =
        Graph.new(
          graph_store: graph_store,
          vector_store: MockVectorStore.new()
        )

      {:ok, results} = Graph.global_search(retriever, query_text, embedding_fn: embedding_fn)

      assert length(results) == 1
      assert hd(results).content == "Development team"
    end
  end

  describe "Graph.hybrid_search/3" do
    test "runs local and global searches in parallel" do
      query_embedding = random_embedding()

      # Setup for local search
      seed_entities = [%{id: 1, name: "Alice", type: "person", source_chunk_ids: [101]}]
      chunks = [%{id: 101, content: "Alice local", metadata: %{}}]

      # Setup for global search
      communities = [%{id: 1, level: 0, summary: "Alice global", entity_ids: [1]}]

      custom_graph_store = %CustomGraphStore{
        vector_search_response: {:ok, seed_entities},
        traverse_responses: %{1 => {:ok, seed_entities |> Enum.map(&Map.put(&1, :depth, 0))}},
        search_communities_response: {:ok, communities}
      }

      vector_store =
        MockVectorStore.new()
        |> MockVectorStore.set_response(:get_chunks_by_ids, {:ok, chunks})

      retriever =
        Graph.new(
          graph_store: custom_graph_store,
          vector_store: vector_store,
          local_weight: 0.5,
          global_weight: 0.5
        )

      {:ok, results} = Graph.hybrid_search(retriever, query_embedding, limit: 10)

      # Should have both local and global results
      contents = Enum.map(results, & &1.content)
      assert "Alice local" in contents
      assert "Alice global" in contents
    end

    test "applies weighted RRF fusion" do
      query_embedding = random_embedding()

      seed_entities = [%{id: 1, name: "Test", type: "person", source_chunk_ids: [101]}]
      chunks = [%{id: 101, content: "Local result", metadata: %{}}]
      communities = [%{id: 1, level: 0, summary: "Global result", entity_ids: [1]}]

      custom_graph_store = %CustomGraphStore{
        vector_search_response: {:ok, seed_entities},
        traverse_responses: %{1 => {:ok, seed_entities |> Enum.map(&Map.put(&1, :depth, 0))}},
        search_communities_response: {:ok, communities}
      }

      vector_store =
        MockVectorStore.new()
        |> MockVectorStore.set_response(:get_chunks_by_ids, {:ok, chunks})

      retriever =
        Graph.new(
          graph_store: custom_graph_store,
          vector_store: vector_store,
          local_weight: 0.8,
          global_weight: 0.2
        )

      {:ok, results} = Graph.hybrid_search(retriever, query_embedding)

      # Results should be scored and sorted
      assert Enum.all?(results, fn r -> is_float(r.score) and r.score > 0 end)
      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "deduplicates results by id" do
      query_embedding = random_embedding()

      # Same chunk appears in both local and global (via same id)
      seed_entities = [%{id: 1, name: "Alice", type: "person", source_chunk_ids: [101]}]
      chunks = [%{id: 101, content: "Shared content", metadata: %{}}]
      communities = [%{id: 1, level: 0, summary: "Shared content", entity_ids: [1]}]

      custom_graph_store = %CustomGraphStore{
        vector_search_response: {:ok, seed_entities},
        traverse_responses: %{1 => {:ok, seed_entities |> Enum.map(&Map.put(&1, :depth, 0))}},
        search_communities_response: {:ok, communities}
      }

      vector_store =
        MockVectorStore.new()
        |> MockVectorStore.set_response(:get_chunks_by_ids, {:ok, chunks})

      retriever =
        Graph.new(
          graph_store: custom_graph_store,
          vector_store: vector_store,
          mode: :hybrid
        )

      {:ok, results} = Graph.hybrid_search(retriever, query_embedding)

      # Should deduplicate based on ID or content
      ids = Enum.map(results, & &1.id)
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  describe "Graph.supports_embedding?/0" do
    test "returns true" do
      assert Graph.supports_embedding?() == true
    end
  end

  describe "Graph.supports_text_query?/0" do
    test "returns true" do
      assert Graph.supports_text_query?() == true
    end
  end

  # Helper functions

  defp random_embedding do
    Enum.map(1..@embedding_dimension, fn _ -> :rand.uniform() end)
  end
end
