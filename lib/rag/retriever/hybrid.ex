if Code.ensure_loaded?(Ecto.Query) do
  defmodule Rag.Retriever.Hybrid do
    @moduledoc """
    Hybrid retriever combining semantic and full-text search with RRF.

    This retriever combines vector similarity search and full-text search
    using Reciprocal Rank Fusion (RRF) to produce better results than
    either approach alone.

    ## Reciprocal Rank Fusion (RRF)

    RRF is an effective technique for combining rankings from different
    retrieval systems. For each document, it calculates:

        RRF(d) = Σ 1 / (k + rank(d))

    where k is typically 60, and the sum is over all retrieval systems
    where the document appears.

    ## Usage

        # Create a hybrid retriever
        retriever = %Rag.Retriever.Hybrid{repo: MyApp.Repo}

        # Retrieve using both embedding and text query
        query_embedding = [0.1, 0.2, 0.3, ...]
        query_text = "search terms"
        {:ok, results} = Rag.Retriever.retrieve(
          retriever,
          {query_embedding, query_text},
          limit: 10
        )

    ## Result Format

    Returns results with a `score` field representing RRF score:
    - `score` = Combined RRF score from both retrieval methods
    - Higher scores indicate better overall relevance
    - Documents appearing in both result sets get higher scores

    """

    @behaviour Rag.Retriever

    alias Rag.VectorStore

    defstruct [:repo]

    @type t :: %__MODULE__{
            repo: module()
          }

    @default_limit 10

    @doc """
    Retrieve documents using hybrid search with RRF fusion.

    ## Parameters

    - `retriever` - The Hybrid retriever struct
    - `query` - Tuple of {embedding, text} for hybrid search
    - `opts` - Options:
      - `:limit` - Maximum number of results (default: 10)

    ## Returns

    - `{:ok, results}` - List of results with RRF scores
    - `{:error, reason}` - Error during retrieval

    ## Examples

        iex> retriever = %Hybrid{repo: MyRepo}
        iex> Hybrid.retrieve(retriever, {[0.1, 0.2], "machine learning"}, limit: 5)
        {:ok, [%{id: 1, content: "...", score: 0.032, metadata: %{}}]}

    """
    @impl true
    @spec retrieve(t(), {[float()], String.t()}, keyword()) ::
            {:ok, [Rag.Retriever.result()]} | {:error, term()}
    def retrieve(retriever, query, opts \\ [])

    def retrieve(%__MODULE__{repo: repo}, {embedding, text}, opts)
        when is_list(embedding) and is_binary(text) do
      limit = Keyword.get(opts, :limit, @default_limit)

      try do
        # Perform both searches
        semantic_results =
          embedding
          |> VectorStore.semantic_search_query(limit: limit)
          |> repo.all()

        fulltext_results =
          text
          |> VectorStore.fulltext_search_query(limit: limit)
          |> repo.all()

        # Combine with RRF
        results =
          VectorStore.calculate_rrf_score(semantic_results, fulltext_results)
          |> Enum.take(limit)
          |> normalize_results()

        {:ok, results}
      rescue
        error -> {:error, Exception.message(error)}
      end
    end

    def retrieve(%__MODULE__{}, _query, _opts) do
      {:error, :invalid_query_format}
    end

    @doc """
    Returns true - Hybrid retriever supports embedding queries.
    """
    @impl true
    @spec supports_embedding?() :: boolean()
    def supports_embedding?, do: true

    @doc """
    Returns true - Hybrid retriever supports text queries.
    """
    @impl true
    @spec supports_text_query?() :: boolean()
    def supports_text_query?, do: true

    # Private functions

    defp normalize_results(results) do
      Enum.map(results, fn result ->
        %{
          id: result.id,
          content: result.content,
          source: Map.get(result, :source, "unknown"),
          score: result.rrf_score,
          metadata: result.metadata || %{}
        }
      end)
    end
  end
end
