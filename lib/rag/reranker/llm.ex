defmodule Rag.Reranker.LLM do
  @moduledoc """
  LLM-based reranker that scores documents using a language model.

  This reranker uses an LLM to evaluate the relevance of each document
  to the query and assigns new scores. Documents are then sorted by
  these LLM-generated relevance scores.

  ## How it works

  1. Formats the query and documents into a prompt
  2. Sends the prompt to an LLM via the Router
  3. Parses the LLM's scoring response (JSON format)
  4. Updates document scores and sorts by relevance
  5. Optionally limits results with `top_k`

  ## Usage

      # With default router (auto-detected providers)
      reranker = Rag.Reranker.LLM.new()
      {:ok, docs} = Rag.Reranker.rerank(reranker, query, documents)

      # With custom router
      {:ok, router} = Rag.Router.new(providers: [:gemini])
      reranker = Rag.Reranker.LLM.new(router: router)

      # With options
      {:ok, docs} = Rag.Reranker.rerank(reranker, query, documents,
        top_k: 5,
        normalize_scores: true
      )

  ## Options

  - `:top_k` - Limit to top K documents after reranking
  - `:normalize_scores` - Normalize scores to 0-1 range (default: false)

  ## Custom Prompt Template

  You can provide a custom prompt template with placeholders:
  - `{query}` - The search query
  - `{documents}` - Formatted list of documents

      template = \"\"\"
      Rate these documents for the query.
      Query: {query}
      Documents: {documents}
      Return JSON with scores.
      \"\"\"

      reranker = Rag.Reranker.LLM.new(prompt_template: template)
  """

  @behaviour Rag.Reranker

  alias Rag.Router

  defstruct [:router, :prompt_template]

  @type t :: %__MODULE__{
          router: Router.t(),
          prompt_template: String.t()
        }

  @default_prompt_template """
  You are a relevance scoring assistant. Given a query and a list of documents, score each document's relevance to the query on a scale from 1 to 10, where:
  - 1-3: Not relevant or minimally relevant
  - 4-6: Somewhat relevant
  - 7-9: Highly relevant
  - 10: Extremely relevant and directly answers the query

  Query: {query}

  Documents:
  {documents}

  Return ONLY a JSON array with the scores in this exact format:
  [{"doc_index": 0, "score": 8}, {"doc_index": 1, "score": 5}, ...]

  Each object must have:
  - "doc_index": the 0-based index of the document
  - "score": an integer from 1 to 10

  Return the JSON array and nothing else.
  """

  @doc """
  Creates a new LLM-based reranker.

  ## Options

  - `:router` - A configured Router struct. If not provided, creates one with auto-detection
  - `:prompt_template` - Custom prompt template string with {query} and {documents} placeholders

  ## Examples

      # Default configuration
      reranker = Rag.Reranker.LLM.new()

      # With custom router
      {:ok, router} = Rag.Router.new(providers: [:gemini, :claude])
      reranker = Rag.Reranker.LLM.new(router: router)

      # With custom prompt
      template = "Score these docs: {query} - {documents}"
      reranker = Rag.Reranker.LLM.new(prompt_template: template)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    router =
      case Keyword.get(opts, :router) do
        nil ->
          # Create default router with auto-detection
          case Router.new(auto_detect: true) do
            {:ok, router} -> router
            {:error, _} -> raise "Failed to initialize router for LLM reranker"
          end

        router ->
          router
      end

    prompt_template = Keyword.get(opts, :prompt_template, @default_prompt_template)

    %__MODULE__{
      router: router,
      prompt_template: prompt_template
    }
  end

  @doc """
  Reranks documents using LLM-based relevance scoring.

  ## Parameters

  - `reranker` - The LLM reranker struct
  - `query` - The search query
  - `documents` - List of documents to rerank
  - `opts` - Options:
    - `:top_k` - Return only top K documents (default: all)
    - `:normalize_scores` - Normalize scores to 0-1 range (default: false)

  ## Returns

  - `{:ok, reranked_documents}` - Documents sorted by LLM scores
  - `{:error, reason}` - If LLM call fails or response is invalid

  ## Examples

      reranker = Rag.Reranker.LLM.new()
      docs = [
        %{id: 1, content: "Elixir programming", score: 0.7, metadata: %{}},
        %{id: 2, content: "Python basics", score: 0.8, metadata: %{}}
      ]

      {:ok, reranked} = Rag.Reranker.LLM.rerank(
        reranker,
        "What is Elixir?",
        docs,
        top_k: 1
      )
  """
  @impl Rag.Reranker
  @spec rerank(t(), String.t(), [Rag.Reranker.document()], keyword()) ::
          {:ok, [Rag.Reranker.document()]} | {:error, term()}
  def rerank(_reranker, _query, [], _opts), do: {:ok, []}

  def rerank(reranker, query, documents, opts) do
    prompt = build_prompt(reranker.prompt_template, query, documents)

    case Router.execute(reranker.router, :text, prompt, []) do
      {:ok, response, _router} ->
        parse_and_rerank(response, documents, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp build_prompt(template, query, documents) do
    formatted_docs =
      documents
      |> Enum.with_index()
      |> Enum.map(fn {doc, idx} ->
        "#{idx}. #{doc.content}"
      end)
      |> Enum.join("\n")

    template
    |> String.replace("{query}", query)
    |> String.replace("{documents}", formatted_docs)
  end

  defp parse_and_rerank(llm_response, documents, opts) do
    # Strip markdown code blocks if present (LLMs often wrap JSON in ```json ... ```)
    cleaned_response = extract_json(llm_response)

    with {:ok, scores} <- Jason.decode(cleaned_response),
         {:ok, scored_docs} <- apply_scores(documents, scores, opts) do
      top_k = Keyword.get(opts, :top_k)

      reranked =
        scored_docs
        |> Enum.sort_by(& &1.score, :desc)
        |> maybe_limit(top_k)

      {:ok, reranked}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Extract JSON from LLM response, stripping markdown code blocks if present
  defp extract_json(response) do
    response = String.trim(response)

    cond do
      # Handle ```json ... ``` blocks
      String.starts_with?(response, "```json") ->
        response
        |> String.replace_prefix("```json", "")
        |> String.replace_suffix("```", "")
        |> String.trim()

      # Handle ``` ... ``` blocks (without json specifier)
      String.starts_with?(response, "```") ->
        response
        |> String.replace_prefix("```", "")
        |> String.replace_suffix("```", "")
        |> String.trim()

      # Already clean JSON
      true ->
        response
    end
  end

  defp apply_scores(documents, scores, opts) when is_list(scores) do
    normalize? = Keyword.get(opts, :normalize_scores, false)

    # Create a map of index -> score for quick lookup
    score_map =
      scores
      |> Enum.map(fn score ->
        {score["doc_index"], score["score"]}
      end)
      |> Map.new()

    # Normalize scores if requested
    score_map =
      if normalize? do
        normalize_score_map(score_map)
      else
        # Convert scores to floats
        Map.new(score_map, fn {idx, score} -> {idx, score / 1.0} end)
      end

    # Apply scores to documents
    scored_docs =
      documents
      |> Enum.with_index()
      |> Enum.map(fn {doc, idx} ->
        case Map.get(score_map, idx) do
          nil ->
            # Keep original score if LLM didn't score this document
            doc

          new_score ->
            %{doc | score: new_score}
        end
      end)

    {:ok, scored_docs}
  rescue
    e -> {:error, e}
  end

  defp normalize_score_map(score_map) when map_size(score_map) == 0, do: score_map

  defp normalize_score_map(score_map) do
    scores = Map.values(score_map)
    min_score = Enum.min(scores)
    max_score = Enum.max(scores)

    if max_score == min_score do
      # All scores are the same, normalize to 1.0
      Map.new(score_map, fn {idx, _} -> {idx, 1.0} end)
    else
      # Normalize to 0-1 range
      Map.new(score_map, fn {idx, score} ->
        normalized = (score - min_score) / (max_score - min_score)
        {idx, normalized}
      end)
    end
  end

  defp maybe_limit(documents, nil), do: documents
  defp maybe_limit(documents, top_k) when is_integer(top_k), do: Enum.take(documents, top_k)
end
