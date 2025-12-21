defmodule Rag.VectorStore.ChunkTest do
  use ExUnit.Case, async: true

  alias Rag.VectorStore.Chunk

  describe "new/1" do
    test "creates a chunk struct with required fields" do
      chunk =
        Chunk.new(%{
          content: "Hello world",
          source: "readme.md"
        })

      assert %Chunk{} = chunk
      assert chunk.content == "Hello world"
      assert chunk.source == "readme.md"
    end

    test "creates a chunk with optional metadata" do
      chunk =
        Chunk.new(%{
          content: "Test content",
          source: "test.ex",
          metadata: %{line_start: 1, line_end: 10}
        })

      assert chunk.metadata == %{line_start: 1, line_end: 10}
    end

    test "creates a chunk with optional embedding" do
      embedding = List.duplicate(0.5, 768)

      chunk =
        Chunk.new(%{
          content: "Test content",
          source: "test.ex",
          embedding: embedding
        })

      assert chunk.embedding == embedding
    end

    test "defaults metadata to empty map" do
      chunk = Chunk.new(%{content: "test", source: "test.ex"})

      assert chunk.metadata == %{}
    end

    test "defaults embedding to nil" do
      chunk = Chunk.new(%{content: "test", source: "test.ex"})

      assert chunk.embedding == nil
    end
  end

  describe "changeset/2" do
    test "validates required fields" do
      changeset = Chunk.changeset(%Chunk{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).content
    end

    test "accepts valid attributes" do
      attrs = %{
        content: "Valid content",
        source: "file.ex",
        metadata: %{type: "code"}
      }

      changeset = Chunk.changeset(%Chunk{}, attrs)

      assert changeset.valid?
    end

    test "validates content is not empty string" do
      changeset = Chunk.changeset(%Chunk{}, %{content: "", source: "file.ex"})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).content
    end

    test "accepts embedding vector" do
      embedding = List.duplicate(0.1, 768)

      attrs = %{
        content: "Content",
        source: "file.ex",
        embedding: embedding
      }

      changeset = Chunk.changeset(%Chunk{}, attrs)

      assert changeset.valid?
    end
  end

  describe "embedding_changeset/2" do
    test "updates only the embedding field" do
      chunk = %Chunk{content: "test", source: "test.ex"}
      embedding = List.duplicate(0.5, 768)

      changeset = Chunk.embedding_changeset(chunk, %{embedding: embedding})

      assert changeset.valid?
      # Pgvector wraps the list, so we convert to list for comparison
      changed = Ecto.Changeset.get_change(changeset, :embedding)
      assert Pgvector.to_list(changed) == embedding
    end

    test "does not allow changing content" do
      chunk = %Chunk{content: "original", source: "test.ex"}

      changeset =
        Chunk.embedding_changeset(chunk, %{
          embedding: List.duplicate(0.5, 768),
          content: "modified"
        })

      # content should not be changed
      refute Ecto.Changeset.get_change(changeset, :content)
    end
  end

  describe "to_map/1" do
    test "converts chunk to map for vector store operations" do
      embedding = List.duplicate(0.5, 768)

      chunk = %Chunk{
        id: 1,
        content: "Hello world",
        source: "readme.md",
        embedding: embedding,
        metadata: %{line: 5}
      }

      map = Chunk.to_map(chunk)

      assert map.content == "Hello world"
      assert map.source == "readme.md"
      assert map.embedding == embedding
      assert map.metadata == %{line: 5}
    end
  end

  # Helper to extract error messages from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
