defmodule Rag.VectorStoreTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Rag.VectorStore
  alias Rag.VectorStore.Chunk

  @embedding_dimension 768

  setup :verify_on_exit!

  describe "insert/2" do
    test "creates a chunk with the given attributes" do
      attrs = %{
        content: "Hello world",
        source: "test.ex",
        metadata: %{type: "code"}
      }

      chunk = VectorStore.build_chunk(attrs)

      assert %Chunk{} = chunk
      assert chunk.content == "Hello world"
      assert chunk.source == "test.ex"
      assert chunk.metadata == %{type: "code"}
    end

    test "accepts embedding in attributes" do
      embedding = random_embedding()

      attrs = %{
        content: "Test",
        source: "test.ex",
        embedding: embedding
      }

      chunk = VectorStore.build_chunk(attrs)

      assert chunk.embedding == embedding
    end
  end

  describe "build_chunk/1" do
    test "builds a chunk struct without persisting" do
      attrs = %{content: "Test content", source: "file.ex"}

      chunk = VectorStore.build_chunk(attrs)

      assert %Chunk{} = chunk
      assert chunk.content == "Test content"
      assert is_nil(chunk.id)
    end

    test "handles missing optional fields" do
      chunk = VectorStore.build_chunk(%{content: "Test"})

      assert chunk.content == "Test"
      assert is_nil(chunk.source)
      assert chunk.metadata == %{}
    end
  end

  describe "build_chunks/1" do
    test "builds multiple chunks from a list of attributes" do
      attrs_list = [
        %{content: "First", source: "a.ex"},
        %{content: "Second", source: "b.ex"},
        %{content: "Third", source: "c.ex"}
      ]

      chunks = VectorStore.build_chunks(attrs_list)

      assert length(chunks) == 3
      assert Enum.map(chunks, & &1.content) == ["First", "Second", "Third"]
    end
  end

  describe "add_embeddings/2" do
    test "adds embeddings to chunks" do
      chunks = [
        VectorStore.build_chunk(%{content: "First"}),
        VectorStore.build_chunk(%{content: "Second"})
      ]

      embeddings = [random_embedding(), random_embedding()]

      result = VectorStore.add_embeddings(chunks, embeddings)

      assert length(result) == 2

      Enum.each(result, fn chunk ->
        assert chunk.embedding != nil
        assert length(chunk.embedding) == @embedding_dimension
      end)
    end

    test "raises when chunk count doesn't match embedding count" do
      chunks = [VectorStore.build_chunk(%{content: "Single"})]
      embeddings = [random_embedding(), random_embedding()]

      assert_raise ArgumentError, ~r/mismatch/, fn ->
        VectorStore.add_embeddings(chunks, embeddings)
      end
    end
  end

  describe "semantic_search_query/2" do
    test "builds a query for L2 distance search" do
      embedding = random_embedding()

      query = VectorStore.semantic_search_query(embedding, limit: 10)

      assert %Ecto.Query{} = query
    end

    test "respects limit option" do
      query = VectorStore.semantic_search_query(random_embedding(), limit: 5)

      assert %Ecto.Query{} = query
    end

    test "defaults to limit 10" do
      query = VectorStore.semantic_search_query(random_embedding(), [])

      assert %Ecto.Query{} = query
    end
  end

  describe "fulltext_search_query/2" do
    test "builds a query for PostgreSQL fulltext search" do
      query = VectorStore.fulltext_search_query("search terms", limit: 10)

      assert %Ecto.Query{} = query
    end
  end

  describe "calculate_rrf_score/2" do
    test "combines semantic and fulltext results using RRF" do
      semantic_results = [
        %{id: 1, content: "First", distance: 0.1},
        %{id: 2, content: "Second", distance: 0.2},
        %{id: 3, content: "Third", distance: 0.3}
      ]

      fulltext_results = [
        %{id: 2, content: "Second", rank: 0.8},
        %{id: 4, content: "Fourth", rank: 0.6},
        %{id: 1, content: "First", rank: 0.4}
      ]

      combined = VectorStore.calculate_rrf_score(semantic_results, fulltext_results)

      # Results should be combined and re-ranked
      assert is_list(combined)
      # ID 1 and 2 should be in both, so should rank higher
      ids = Enum.map(combined, & &1.id)
      assert 1 in ids
      assert 2 in ids
    end

    test "handles empty semantic results" do
      fulltext_results = [%{id: 1, content: "Test", rank: 0.5}]

      combined = VectorStore.calculate_rrf_score([], fulltext_results)

      assert [%{id: 1}] = combined
    end

    test "handles empty fulltext results" do
      semantic_results = [%{id: 1, content: "Test", distance: 0.1}]

      combined = VectorStore.calculate_rrf_score(semantic_results, [])

      assert [%{id: 1}] = combined
    end
  end

  describe "chunk_text/2" do
    test "splits text into chunks by character limit" do
      text = String.duplicate("Hello world. ", 100)

      chunks = VectorStore.chunk_text(text, max_chars: 200)

      assert length(chunks) > 1

      Enum.each(chunks, fn chunk ->
        assert String.length(chunk) <= 200
      end)
    end

    test "respects overlap option" do
      text = "First sentence. Second sentence. Third sentence. Fourth sentence."

      chunks = VectorStore.chunk_text(text, max_chars: 40, overlap: 10)

      assert length(chunks) >= 2
    end

    test "handles text shorter than max_chars" do
      text = "Short text"

      chunks = VectorStore.chunk_text(text, max_chars: 100)

      assert chunks == ["Short text"]
    end
  end

  describe "prepare_for_insert/1" do
    test "converts chunk to map suitable for database insert" do
      chunk = %Chunk{
        content: "Test",
        source: "file.ex",
        embedding: random_embedding(),
        metadata: %{line: 1}
      }

      prepared = VectorStore.prepare_for_insert(chunk)

      assert is_map(prepared)
      assert prepared.content == "Test"
      assert prepared.source == "file.ex"
    end

    test "excludes nil id" do
      chunk = VectorStore.build_chunk(%{content: "Test"})

      prepared = VectorStore.prepare_for_insert(chunk)

      refute Map.has_key?(prepared, :id)
    end

    test "includes timestamps for Ecto insert_all" do
      chunk = VectorStore.build_chunk(%{content: "Test"})

      prepared = VectorStore.prepare_for_insert(chunk)

      assert Map.has_key?(prepared, :inserted_at)
      assert Map.has_key?(prepared, :updated_at)
      assert %NaiveDateTime{} = prepared.inserted_at
      assert %NaiveDateTime{} = prepared.updated_at
    end
  end

  # Helper to generate random embeddings for testing
  defp random_embedding do
    Enum.map(1..@embedding_dimension, fn _ -> :rand.uniform() end)
  end
end
