defmodule Rag.Reranker do
  @moduledoc """
  Behaviour for reranking retrieved results.

  Rerankers improve retrieval quality by rescoring
  documents based on relevance to the query.

  ## Usage

      # Using Passthrough reranker (no reranking)
      reranker = %Rag.Reranker.Passthrough{}
      {:ok, docs} = Rag.Reranker.rerank(reranker, query, documents)

      # Using LLM-based reranker
      reranker = Rag.Reranker.LLM.new()
      {:ok, docs} = Rag.Reranker.rerank(reranker, query, documents, top_k: 5)

  ## Document Format

  Documents should be maps with the following structure:

      %{
        id: any(),           # Unique identifier
        content: String.t(), # The text content
        score: float(),      # Relevance score
        metadata: map()      # Additional metadata
      }

  ## Reranker Implementations

  - `Rag.Reranker.Passthrough` - Returns documents unchanged
  - `Rag.Reranker.LLM` - Uses an LLM to score and rerank documents
  """

  @type document :: %{
          id: any(),
          content: String.t(),
          score: float(),
          metadata: map()
        }

  @doc """
  Rerank documents based on their relevance to the query.

  ## Parameters

  - `reranker` - The reranker struct implementing this behaviour
  - `query` - The search query string
  - `documents` - List of documents to rerank
  - `opts` - Additional options (implementation-specific)

  ## Returns

  - `{:ok, reranked_documents}` - Documents sorted by relevance
  - `{:error, reason}` - If reranking fails
  """
  @callback rerank(
              reranker :: struct(),
              query :: String.t(),
              documents :: [document()],
              opts :: keyword()
            ) ::
              {:ok, [document()]} | {:error, term()}

  @doc """
  Convenience function to rerank documents.

  Delegates to the appropriate reranker implementation based on the struct type.

  ## Examples

      reranker = Rag.Reranker.LLM.new()
      {:ok, docs} = Rag.Reranker.rerank(reranker, "What is Elixir?", documents)

      # With options
      {:ok, docs} = Rag.Reranker.rerank(reranker, query, documents, top_k: 5)
  """
  @spec rerank(struct(), String.t(), [document()], keyword()) ::
          {:ok, [document()]} | {:error, term()}
  def rerank(reranker, query, documents, opts \\ []) do
    reranker.__struct__.rerank(reranker, query, documents, opts)
  end
end
