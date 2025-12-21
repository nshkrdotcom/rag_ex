defmodule Rag.VectorStore.Chunk do
  @moduledoc """
  Ecto schema for storing text chunks with embeddings.

  Each chunk represents a piece of text from a source document
  along with its vector embedding for semantic search.

  ## Fields

  - `content` - The text content of the chunk
  - `source` - The source file or document path
  - `embedding` - The vector embedding (768 dimensions for Gemini)
  - `metadata` - Additional metadata as a map

  ## Examples

      chunk = Chunk.new(%{
        content: "def hello, do: :world",
        source: "lib/greeting.ex",
        metadata: %{line_start: 1, line_end: 1}
      })

  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          content: String.t(),
          source: String.t() | nil,
          embedding: [float()] | nil,
          metadata: map(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "rag_chunks" do
    field(:content, :string)
    field(:source, :string)
    field(:embedding, Pgvector.Ecto.Vector)
    field(:metadata, :map, default: %{})

    timestamps()
  end

  @doc """
  Creates a new Chunk struct from the given attributes.

  ## Parameters

  - `attrs` - Map with `:content` (required), `:source`, `:embedding`, `:metadata`

  ## Examples

      iex> Chunk.new(%{content: "Hello", source: "test.ex"})
      %Chunk{content: "Hello", source: "test.ex", metadata: %{}}

  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      content: Map.get(attrs, :content),
      source: Map.get(attrs, :source),
      embedding: Map.get(attrs, :embedding),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  @doc """
  Creates a changeset for inserting or updating a chunk.

  Validates that `content` is present and not blank.

  ## Examples

      iex> Chunk.changeset(%Chunk{}, %{content: "Hello", source: "test.ex"})
      #Ecto.Changeset<...>

  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [:content, :source, :embedding, :metadata])
    |> validate_required([:content])
    |> validate_content_not_empty()
  end

  @doc """
  Creates a changeset for updating only the embedding.

  Use this when adding embeddings to existing chunks.

  ## Examples

      iex> Chunk.embedding_changeset(chunk, %{embedding: [0.1, 0.2, ...]})
      #Ecto.Changeset<...>

  """
  @spec embedding_changeset(t(), map()) :: Ecto.Changeset.t()
  def embedding_changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [:embedding])
  end

  @doc """
  Converts a Chunk struct to a plain map.

  Useful for vector store operations that expect maps.

  ## Examples

      iex> Chunk.to_map(%Chunk{content: "Hi", source: "t.ex"})
      %{content: "Hi", source: "t.ex", embedding: nil, metadata: %{}}

  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = chunk) do
    %{
      content: chunk.content,
      source: chunk.source,
      embedding: chunk.embedding,
      metadata: chunk.metadata
    }
  end

  # Private helpers

  defp validate_content_not_empty(changeset) do
    validate_change(changeset, :content, fn :content, content ->
      if String.trim(content) == "" do
        [content: "can't be blank"]
      else
        []
      end
    end)
  end
end
