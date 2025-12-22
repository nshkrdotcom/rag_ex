if Code.ensure_loaded?(Ecto.Query) do
  defmodule Rag.VectorStore.Pgvector do
    @moduledoc """
    PostgreSQL pgvector implementation of VectorStore.Store.

    Uses pgvector extension for efficient vector similarity search
    with L2 distance.

    ## Usage

        # Create a store with your Repo
        store = %Rag.VectorStore.Pgvector{repo: MyApp.Repo}

        # Insert documents
        {:ok, count} = Rag.VectorStore.Store.insert(store, documents)

        # Search by embedding
        {:ok, results} = Rag.VectorStore.Store.search(store, embedding, limit: 10)

    ## Requirements

    - PostgreSQL with pgvector extension
    - The `rag_chunks` table (see migrations in README)

    """

    @behaviour Rag.VectorStore.Store

    import Ecto.Query

    alias Rag.VectorStore.Chunk

    defstruct [:repo]

    @type t :: %__MODULE__{
            repo: module()
          }

    @default_limit 10

    @doc """
    Create a new Pgvector store.

    ## Options

    - `:repo` - The Ecto Repo module to use (required)

    ## Examples

        iex> Rag.VectorStore.Pgvector.new(repo: MyApp.Repo)
        %Rag.VectorStore.Pgvector{repo: MyApp.Repo}

    """
    @spec new(keyword()) :: t()
    def new(opts) do
      repo = Keyword.fetch!(opts, :repo)
      %__MODULE__{repo: repo}
    end

    @impl true
    @spec insert(t(), [map()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
    def insert(%__MODULE__{repo: _repo}, [], _opts), do: {:ok, 0}

    def insert(%__MODULE__{repo: repo}, documents, opts) when is_list(documents) do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      inserts =
        Enum.map(documents, fn doc ->
          %{
            content: doc.content,
            embedding: doc.embedding,
            source: doc[:source],
            metadata: doc[:metadata] || %{},
            inserted_at: now,
            updated_at: now
          }
        end)

      try do
        {count, _} = repo.insert_all(Chunk, inserts, opts)
        {:ok, count}
      rescue
        error -> {:error, Exception.message(error)}
      end
    end

    @impl true
    @spec search(t(), [float()], keyword()) ::
            {:ok, [Rag.VectorStore.Store.result()]} | {:error, term()}
    def search(%__MODULE__{repo: repo}, embedding, opts) when is_list(embedding) do
      limit = Keyword.get(opts, :limit, @default_limit)
      vector = Pgvector.new(embedding)

      query =
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

      try do
        results =
          repo.all(query)
          |> Enum.map(fn row ->
            %{
              id: row.id,
              content: row.content,
              source: row.source,
              metadata: row.metadata,
              score: distance_to_score(row.distance)
            }
          end)

        {:ok, results}
      rescue
        error -> {:error, Exception.message(error)}
      end
    end

    @impl true
    @spec delete(t(), [any()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
    def delete(%__MODULE__{repo: _repo}, [], _opts), do: {:ok, 0}

    def delete(%__MODULE__{repo: repo}, ids, _opts) when is_list(ids) do
      query = from(c in Chunk, where: c.id in ^ids)

      try do
        {count, _} = repo.delete_all(query)
        {:ok, count}
      rescue
        error -> {:error, Exception.message(error)}
      end
    end

    @impl true
    @spec get(t(), [any()], keyword()) :: {:ok, [map()]} | {:error, term()}
    def get(%__MODULE__{repo: _repo}, [], _opts), do: {:ok, []}

    def get(%__MODULE__{repo: repo}, ids, _opts) when is_list(ids) do
      query = from(c in Chunk, where: c.id in ^ids)

      try do
        results =
          repo.all(query)
          |> Enum.map(fn chunk ->
            %{
              id: chunk.id,
              content: chunk.content,
              source: chunk.source,
              embedding: chunk.embedding,
              metadata: chunk.metadata
            }
          end)

        {:ok, results}
      rescue
        error -> {:error, Exception.message(error)}
      end
    end

    # Convert L2 distance to similarity score (0-1)
    defp distance_to_score(distance) when is_number(distance) do
      # Use exponential decay for better score distribution
      # score = 1 / (1 + distance)
      1.0 / (1.0 + distance)
    end
  end
end
