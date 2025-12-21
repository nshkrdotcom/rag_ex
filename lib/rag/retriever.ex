defmodule Rag.Retriever do
  @moduledoc """
  Behaviour for retrieval strategies in RAG systems.

  A retrieval strategy determines how documents are retrieved from
  a vector store or database. Different strategies can be used for
  semantic search, full-text search, or hybrid approaches.

  ## Available Retrievers

  - `Rag.Retriever.Semantic` - Vector similarity search using embeddings
  - `Rag.Retriever.FullText` - PostgreSQL tsvector full-text search
  - `Rag.Retriever.Hybrid` - Combines semantic and fulltext with RRF fusion

  ## Implementing a Custom Retriever

      defmodule MyRetriever do
        @behaviour Rag.Retriever

        defstruct [:repo, :config]

        @impl true
        def retrieve(retriever, query, opts) do
          # Perform retrieval and return results
          {:ok, results}
        end

        @impl true
        def supports_embedding?(), do: true

        @impl true
        def supports_text_query?(), do: false
      end

  ## Result Format

  All retrievers must return results in a normalized format:

      %{
        id: any(),
        content: String.t(),
        score: float(),
        metadata: map()
      }

  The `score` field represents relevance (higher is better):
  - For semantic search: 1.0 - distance (converted from L2 distance)
  - For fulltext search: PostgreSQL ts_rank score
  - For hybrid search: RRF combined score

  """

  @type query :: String.t() | [float()] | {[float()], String.t()}
  @type result :: %{
          id: any(),
          content: String.t(),
          score: float(),
          metadata: map()
        }

  @doc """
  Retrieve relevant documents for the given query.

  ## Parameters

  - `retriever` - The retriever struct (e.g., %Semantic{}, %FullText{})
  - `query` - Query (text, embedding vector, or tuple for hybrid)
  - `opts` - Options including `:limit` for max results

  ## Returns

  - `{:ok, [result()]}` - List of retrieved results
  - `{:error, term()}` - Error during retrieval
  """
  @callback retrieve(retriever :: struct(), query :: query(), opts :: keyword()) ::
              {:ok, [result()]} | {:error, term()}

  @doc """
  Whether this retriever supports embedding-based queries.

  Returns `true` if the retriever can accept vector embeddings as queries.
  """
  @callback supports_embedding?() :: boolean()

  @doc """
  Whether this retriever supports text-based queries.

  Returns `true` if the retriever can accept text strings as queries.
  """
  @callback supports_text_query?() :: boolean()

  @optional_callbacks [supports_embedding?: 0, supports_text_query?: 0]

  @doc """
  Convenience function to call any retriever implementation.

  Delegates to the retriever's `retrieve/3` callback.

  ## Examples

      iex> retriever = %Rag.Retriever.Semantic{repo: MyRepo}
      iex> Rag.Retriever.retrieve(retriever, [0.1, 0.2, 0.3], limit: 5)
      {:ok, [%{id: 1, content: "...", score: 0.9, metadata: %{}}]}

  """
  @spec retrieve(struct(), query(), keyword()) :: {:ok, [result()]} | {:error, term()}
  def retrieve(%module{} = retriever, query, opts \\ []) do
    module.retrieve(retriever, query, opts)
  end
end
