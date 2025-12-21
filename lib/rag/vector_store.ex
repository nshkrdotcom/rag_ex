defmodule Rag.VectorStore do
  @moduledoc """
  Vector store operations for semantic search with pgvector.

  This module provides functions for:
  - Building and managing text chunks
  - Semantic (vector) search using L2 distance
  - Full-text search using PostgreSQL tsvector
  - Hybrid search combining both approaches with RRF

  ## Usage

      # Build chunks from text
      chunks = VectorStore.build_chunks([
        %{content: "First paragraph", source: "doc.md"},
        %{content: "Second paragraph", source: "doc.md"}
      ])

      # Add embeddings (after generating with Router/Gemini)
      chunks = VectorStore.add_embeddings(chunks, embeddings)

      # Build search queries
      query = VectorStore.semantic_search_query(query_embedding, limit: 10)

  ## Search Types

  - **Semantic search**: Uses pgvector L2 distance for similarity
  - **Full-text search**: Uses PostgreSQL tsvector for keyword matching
  - **Hybrid search**: Combines both using Reciprocal Rank Fusion (RRF)

  """

  import Ecto.Query

  alias Rag.VectorStore.Chunk

  @default_limit 10
  @default_chunk_size 500
  @default_overlap 50
  # RRF constant (typically 60)
  @rrf_k 60

  @doc """
  Build a single chunk struct from attributes.

  ## Parameters

  - `attrs` - Map with `:content` (required), `:source`, `:embedding`, `:metadata`

  ## Examples

      iex> VectorStore.build_chunk(%{content: "Hello", source: "test.ex"})
      %Chunk{content: "Hello", source: "test.ex", metadata: %{}}

  """
  @spec build_chunk(map()) :: Chunk.t()
  def build_chunk(attrs) when is_map(attrs) do
    Chunk.new(attrs)
  end

  @doc """
  Build multiple chunks from a list of attributes.

  ## Examples

      iex> VectorStore.build_chunks([%{content: "a"}, %{content: "b"}])
      [%Chunk{content: "a"}, %Chunk{content: "b"}]

  """
  @spec build_chunks([map()]) :: [Chunk.t()]
  def build_chunks(attrs_list) when is_list(attrs_list) do
    Enum.map(attrs_list, &build_chunk/1)
  end

  @doc """
  Add embeddings to a list of chunks.

  Raises `ArgumentError` if the number of chunks doesn't match
  the number of embeddings.

  ## Examples

      iex> chunks = [%Chunk{content: "a"}, %Chunk{content: "b"}]
      iex> embeddings = [[0.1, 0.2], [0.3, 0.4]]
      iex> VectorStore.add_embeddings(chunks, embeddings)
      [%Chunk{content: "a", embedding: [0.1, 0.2]}, ...]

  """
  @spec add_embeddings([Chunk.t()], [[float()]]) :: [Chunk.t()]
  def add_embeddings(chunks, embeddings) do
    if length(chunks) != length(embeddings) do
      raise ArgumentError,
            "Chunk/embedding count mismatch: #{length(chunks)} chunks, #{length(embeddings)} embeddings"
    end

    Enum.zip_with(chunks, embeddings, fn chunk, embedding ->
      %{chunk | embedding: embedding}
    end)
  end

  @doc """
  Build an Ecto query for semantic search using L2 distance.

  Returns results ordered by distance (closest first).

  ## Options

  - `:limit` - Maximum number of results (default: 10)
  - `:min_similarity` - Minimum similarity threshold (optional)

  ## Examples

      iex> VectorStore.semantic_search_query([0.1, 0.2, ...], limit: 5)
      #Ecto.Query<...>

  """
  @spec semantic_search_query([float()], keyword()) :: Ecto.Query.t()
  def semantic_search_query(embedding, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    vector = Pgvector.new(embedding)

    from(c in Chunk,
      select: %{
        id: c.id,
        content: c.content,
        source: c.source,
        metadata: c.metadata,
        distance: fragment("? <-> ?", c.embedding, ^vector)
      },
      order_by: fragment("? <-> ?", c.embedding, ^vector),
      limit: ^limit
    )
  end

  @doc """
  Build an Ecto query for full-text search using PostgreSQL tsvector.

  ## Options

  - `:limit` - Maximum number of results (default: 10)

  ## Examples

      iex> VectorStore.fulltext_search_query("search terms", limit: 10)
      #Ecto.Query<...>

  """
  @spec fulltext_search_query(String.t(), keyword()) :: Ecto.Query.t()
  def fulltext_search_query(search_text, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    tsquery = to_tsquery(search_text)

    from(c in Chunk,
      select: %{
        id: c.id,
        content: c.content,
        source: c.source,
        metadata: c.metadata,
        rank: fragment("ts_rank(to_tsvector('english', ?), to_tsquery(?))", c.content, ^tsquery)
      },
      where: fragment("to_tsvector('english', ?) @@ to_tsquery(?)", c.content, ^tsquery),
      order_by: [
        desc: fragment("ts_rank(to_tsvector('english', ?), to_tsquery(?))", c.content, ^tsquery)
      ],
      limit: ^limit
    )
  end

  @doc """
  Calculate RRF (Reciprocal Rank Fusion) score to combine search results.

  Combines semantic search and full-text search results using RRF,
  which is effective for hybrid search.

  ## Formula

  RRF(d) = Σ 1 / (k + rank(d))

  where k is typically 60.

  ## Examples

      iex> semantic = [%{id: 1, distance: 0.1}, %{id: 2, distance: 0.2}]
      iex> fulltext = [%{id: 2, rank: 0.8}, %{id: 3, rank: 0.6}]
      iex> VectorStore.calculate_rrf_score(semantic, fulltext)
      [%{id: 2, rrf_score: ...}, %{id: 1, rrf_score: ...}, ...]

  """
  @spec calculate_rrf_score([map()], [map()]) :: [map()]
  def calculate_rrf_score(semantic_results, fulltext_results) do
    # Build RRF scores for semantic results
    semantic_scores =
      semantic_results
      |> Enum.with_index(1)
      |> Enum.map(fn {result, rank} ->
        {result.id, Map.put(result, :rrf_score, 1.0 / (@rrf_k + rank))}
      end)
      |> Map.new()

    # Build RRF scores for fulltext results and merge
    fulltext_results
    |> Enum.with_index(1)
    |> Enum.reduce(semantic_scores, fn {result, rank}, scores ->
      score = 1.0 / (@rrf_k + rank)

      Map.update(scores, result.id, Map.put(result, :rrf_score, score), fn existing ->
        Map.update!(existing, :rrf_score, &(&1 + score))
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.rrf_score, :desc)
  end

  @doc """
  Split text into chunks with optional overlap.

  Uses character-based chunking with sentence boundary awareness
  when possible.

  ## Options

  - `:max_chars` - Maximum characters per chunk (default: 500)
  - `:overlap` - Characters to overlap between chunks (default: 50)

  ## Examples

      iex> VectorStore.chunk_text("Long text...", max_chars: 200)
      ["First chunk...", "Second chunk..."]

  """
  @spec chunk_text(String.t(), keyword()) :: [String.t()]
  def chunk_text(text, opts \\ []) do
    max_chars = Keyword.get(opts, :max_chars, @default_chunk_size)
    overlap = Keyword.get(opts, :overlap, @default_overlap)

    if String.length(text) <= max_chars do
      [text]
    else
      do_chunk_text(text, max_chars, overlap, [])
    end
  end

  @doc """
  Prepare a chunk for database insertion.

  Converts chunk to a map suitable for Ecto insert_all,
  including timestamps for Ecto schemas with timestamps().

  ## Examples

      iex> prepared = VectorStore.prepare_for_insert(%Chunk{content: "Test"})
      iex> Map.keys(prepared) |> Enum.sort()
      [:content, :embedding, :inserted_at, :metadata, :source, :updated_at]

  """
  @spec prepare_for_insert(Chunk.t()) :: map()
  def prepare_for_insert(%Chunk{} = chunk) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %{
      content: chunk.content,
      source: chunk.source,
      embedding: chunk.embedding,
      metadata: chunk.metadata,
      inserted_at: now,
      updated_at: now
    }
  end

  # Private functions

  defp do_chunk_text(text, max_chars, overlap, acc) do
    if String.length(text) <= max_chars do
      Enum.reverse([text | acc])
    else
      # Try to find a sentence boundary near max_chars
      chunk = find_chunk_boundary(text, max_chars)
      chunk_len = String.length(chunk)

      # Calculate start of next chunk with overlap
      next_start = max(0, chunk_len - overlap)
      remaining = String.slice(text, next_start, String.length(text))

      do_chunk_text(remaining, max_chars, overlap, [chunk | acc])
    end
  end

  defp find_chunk_boundary(text, max_chars) do
    chunk = String.slice(text, 0, max_chars)

    # Try to find last sentence boundary
    case Regex.run(~r/^(.+[.!?])\s/s, chunk, capture: :all_but_first) do
      [match] when byte_size(match) > div(max_chars, 2) ->
        match

      _ ->
        # Fall back to word boundary
        case Regex.run(~r/^(.+)\s/, chunk, capture: :all_but_first) do
          [match] -> match
          _ -> chunk
        end
    end
  end

  defp to_tsquery(text) do
    text
    |> String.split(~r/\s+/)
    |> Enum.filter(&(String.length(&1) > 0))
    |> Enum.join(" & ")
  end
end
