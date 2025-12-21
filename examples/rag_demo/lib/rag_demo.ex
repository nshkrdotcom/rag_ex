defmodule RagDemo do
  @moduledoc """
  Demo application showcasing the RAG library features.

  ## Quick Start

      # Setup database
      mix setup

      # Run full demo
      mix demo

  ## Features Demonstrated

  1. Basic LLM interaction (generation, streaming)
  2. Embeddings and vector store (semantic search)
  3. Full-text and hybrid search (RRF)
  4. Embedding Service GenServer
  5. Agent framework with tools
  6. Routing strategies
  7. Complete RAG pipeline
  """

  alias Rag.Router
  alias Rag.VectorStore
  alias RagDemo.Repo

  @doc """
  Simple RAG query - searches context and generates augmented response.
  """
  def query(question, opts \\ []) do
    limit = Keyword.get(opts, :limit, 3)

    with {:ok, router} <- Router.new(providers: [:gemini]),
         {:ok, embeddings, router} <- Router.execute(router, :embeddings, [question], []),
         [query_embedding] <- embeddings,
         results <- Repo.all(VectorStore.semantic_search_query(query_embedding, limit: limit)),
         context <- build_context(results),
         prompt <- build_prompt(question, context),
         {:ok, response, _router} <- Router.execute(router, :text, prompt, []) do
      {:ok, response, results}
    end
  end

  defp build_context(results) do
    results
    |> Enum.map(fn r -> "- #{r.content}" end)
    |> Enum.join("\n")
  end

  defp build_prompt(question, context) do
    """
    Answer the question based on the following context.

    Context:
    #{context}

    Question: #{question}
    """
  end
end
