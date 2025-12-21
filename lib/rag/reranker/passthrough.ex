defmodule Rag.Reranker.Passthrough do
  @moduledoc """
  A simple passthrough reranker that returns documents unchanged.

  This reranker is useful for:
  - Baseline comparisons when evaluating reranking strategies
  - Testing pipelines without the overhead of LLM calls
  - Cases where the initial retrieval scores are already optimal

  ## Usage

      reranker = %Rag.Reranker.Passthrough{}
      {:ok, documents} = Rag.Reranker.rerank(reranker, query, documents)

  The documents are returned in their original order with original scores.
  """

  @behaviour Rag.Reranker

  defstruct []

  @type t :: %__MODULE__{}

  @doc """
  Returns documents unchanged without any reranking.

  ## Parameters

  - `reranker` - The passthrough reranker struct
  - `query` - The search query (ignored)
  - `documents` - List of documents
  - `opts` - Options (ignored)

  ## Returns

  - `{:ok, documents}` - The same documents in the same order

  ## Examples

      reranker = %Rag.Reranker.Passthrough{}
      docs = [
        %{id: 1, content: "...", score: 0.8, metadata: %{}},
        %{id: 2, content: "...", score: 0.6, metadata: %{}}
      ]
      {:ok, ^docs} = Rag.Reranker.Passthrough.rerank(reranker, "query", docs, [])
  """
  @impl Rag.Reranker
  @spec rerank(t(), String.t(), [Rag.Reranker.document()], keyword()) ::
          {:ok, [Rag.Reranker.document()]}
  def rerank(_reranker, _query, documents, _opts) do
    {:ok, documents}
  end
end
