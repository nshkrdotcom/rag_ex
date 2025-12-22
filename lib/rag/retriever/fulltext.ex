if Code.ensure_loaded?(Ecto.Query) do
  defmodule Rag.Retriever.FullText do
    @moduledoc """
    Full-text retriever using PostgreSQL tsvector search.

    This retriever uses PostgreSQL's built-in full-text search
    capabilities with ts_rank for relevance scoring.

    ## Usage

        # Create a fulltext retriever
        retriever = %Rag.Retriever.FullText{repo: MyApp.Repo}

        # Retrieve using a text query
        {:ok, results} = Rag.Retriever.retrieve(retriever, "search terms", limit: 10)

    ## Result Format

    Returns results with a `score` field representing ts_rank:
    - `score` = PostgreSQL ts_rank value
    - Higher scores indicate better keyword matches
    - Typically ranges from 0.0 to 1.0

    ## Search Features

    - Supports multiple search terms (combined with AND)
    - Uses English text search configuration
    - Orders results by relevance (ts_rank)

    """

    @behaviour Rag.Retriever

    alias Rag.VectorStore

    defstruct [:repo]

    @type t :: %__MODULE__{
            repo: module()
          }

    @default_limit 10

    @doc """
    Retrieve documents using full-text search.

    ## Parameters

    - `retriever` - The FullText retriever struct
    - `query_text` - Text query string
    - `opts` - Options:
      - `:limit` - Maximum number of results (default: 10)

    ## Returns

    - `{:ok, results}` - List of results with ts_rank scores
    - `{:error, reason}` - Error during retrieval

    ## Examples

        iex> retriever = %FullText{repo: MyRepo}
        iex> FullText.retrieve(retriever, "machine learning", limit: 5)
        {:ok, [%{id: 1, content: "...", score: 0.85, metadata: %{}}]}

    """
    @impl true
    @spec retrieve(t(), String.t(), keyword()) ::
            {:ok, [Rag.Retriever.result()]} | {:error, term()}
    def retrieve(retriever, query_text, opts \\ [])

    def retrieve(%__MODULE__{repo: repo}, query_text, opts)
        when is_binary(query_text) do
      limit = Keyword.get(opts, :limit, @default_limit)

      try do
        results =
          query_text
          |> VectorStore.fulltext_search_query(limit: limit)
          |> repo.all()
          |> normalize_results()

        {:ok, results}
      rescue
        error -> {:error, Exception.message(error)}
      end
    end

    @doc """
    Returns false - FullText retriever doesn't use embeddings.
    """
    @impl true
    @spec supports_embedding?() :: boolean()
    def supports_embedding?, do: false

    @doc """
    Returns true - FullText retriever supports text queries.
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
          score: result.rank,
          metadata: result.metadata || %{}
        }
      end)
    end
  end
end
