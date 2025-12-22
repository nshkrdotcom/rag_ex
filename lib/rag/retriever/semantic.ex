if Code.ensure_loaded?(Ecto.Query) do
  defmodule Rag.Retriever.Semantic do
    @moduledoc """
    Semantic retriever using vector similarity search.

    This retriever uses pgvector's L2 distance to find the most
    semantically similar documents to a query embedding.

    ## Usage

        # Create a semantic retriever
        retriever = %Rag.Retriever.Semantic{repo: MyApp.Repo}

        # Retrieve using an embedding vector
        query_embedding = [0.1, 0.2, 0.3, ...]
        {:ok, results} = Rag.Retriever.retrieve(retriever, query_embedding, limit: 10)

    ## Result Format

    Returns results with a `score` field representing similarity:
    - `score = 1.0 - distance` (L2 distance converted to similarity)
    - Higher scores indicate more similar documents
    - Range: 0.0 (dissimilar) to 1.0 (identical)

    """

    @behaviour Rag.Retriever

    alias Rag.VectorStore

    defstruct [:repo]

    @type t :: %__MODULE__{
            repo: module()
          }

    @default_limit 10

    @doc """
    Retrieve documents using semantic similarity search.

    ## Parameters

    - `retriever` - The Semantic retriever struct
    - `embedding` - Query embedding vector (list of floats)
    - `opts` - Options:
      - `:limit` - Maximum number of results (default: 10)

    ## Returns

    - `{:ok, results}` - List of results with similarity scores
    - `{:error, reason}` - Error during retrieval

    ## Examples

        iex> retriever = %Semantic{repo: MyRepo}
        iex> Semantic.retrieve(retriever, [0.1, 0.2, 0.3], limit: 5)
        {:ok, [%{id: 1, content: "...", score: 0.95, metadata: %{}}]}

    """
    @impl true
    @spec retrieve(t(), [float()], keyword()) ::
            {:ok, [Rag.Retriever.result()]} | {:error, term()}
    def retrieve(retriever, embedding, opts \\ [])

    def retrieve(%__MODULE__{repo: repo}, embedding, opts)
        when is_list(embedding) do
      limit = Keyword.get(opts, :limit, @default_limit)

      try do
        results =
          embedding
          |> VectorStore.semantic_search_query(limit: limit)
          |> repo.all()
          |> normalize_results()

        {:ok, results}
      rescue
        error -> {:error, Exception.message(error)}
      end
    end

    @doc """
    Returns true - Semantic retriever supports embedding queries.
    """
    @impl true
    @spec supports_embedding?() :: boolean()
    def supports_embedding?, do: true

    @doc """
    Returns false - Semantic retriever requires embeddings, not text.
    """
    @impl true
    @spec supports_text_query?() :: boolean()
    def supports_text_query?, do: false

    # Private functions

    defp normalize_results(results) do
      Enum.map(results, fn result ->
        %{
          id: result.id,
          content: result.content,
          source: Map.get(result, :source, "unknown"),
          score: distance_to_similarity(result.distance),
          metadata: result.metadata || %{}
        }
      end)
    end

    defp distance_to_similarity(distance) do
      # Convert L2 distance to similarity score (0.0 to 1.0)
      # Distance of 0 = similarity of 1.0
      # We use 1.0 - distance, clamped to [0, 1]
      max(0.0, 1.0 - distance)
    end
  end
end
