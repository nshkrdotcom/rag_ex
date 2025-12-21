defmodule Rag.Ai.Gemini do
  @moduledoc """
  Gemini provider implementation using gemini_ex.

  This provider supports both text generation and embeddings, making it
  the primary provider for RAG systems. It also supports tool calling
  via Gemini's function calling API.

  ## Examples

      # Basic text generation
      provider = Gemini.new(%{})
      {:ok, response} = Gemini.generate_text(provider, "Hello!", [])

      # Generate embeddings
      {:ok, embeddings} = Gemini.generate_embeddings(provider, ["text1", "text2"], [])

  """

  @behaviour Rag.Ai.Provider

  defstruct [:model, :config]

  @type t :: %__MODULE__{
          model: String.t(),
          config: map()
        }

  @default_model "gemini-2.0-flash-exp"
  @default_embedding_model "text-embedding-004"
  @embedding_dimensions 768
  @max_context_tokens 1_000_000

  # Pricing per 1M tokens for Gemini 2.0 Flash
  @input_cost 0.075
  @output_cost 0.30

  @impl true
  def new(attrs) do
    %__MODULE__{
      model: attrs[:model] || @default_model,
      config: attrs[:config] || %{}
    }
  end

  @impl true
  # Dialyzer incorrectly infers no_return due to cross-library type mismatch
  # between Gemini.batch_embed_contents/2 spec (returns map()) and the actual
  # BatchEmbedContentsResponse struct returned.
  @dialyzer {:nowarn_function, generate_embeddings: 3}
  def generate_embeddings(_provider, texts, opts) do
    task_type = Keyword.get(opts, :task_type, :retrieval_document)
    model = Keyword.get(opts, :model, @default_embedding_model)

    result =
      Gemini.batch_embed_contents(texts,
        model: model,
        task_type: task_type,
        output_dimensionality: @embedding_dimensions
      )

    case result do
      {:ok, response} ->
        embeddings = Map.get(response, :embeddings, [])
        values = Enum.map(embeddings, &Map.get(&1, :values, []))
        {:ok, values}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def generate_text(provider, prompt, opts) do
    gemini_opts = build_gemini_opts(provider, opts)

    if Keyword.get(opts, :stream, false) do
      {:ok, stream_response(prompt, gemini_opts)}
    else
      case Gemini.text(prompt, gemini_opts) do
        {:ok, response} when is_binary(response) -> {:ok, response}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Returns whether this provider supports tool calling.
  """
  @spec supports_tools?() :: boolean()
  def supports_tools?, do: true

  @doc """
  Returns whether this provider supports embeddings.
  """
  @spec supports_embeddings?() :: boolean()
  def supports_embeddings?, do: true

  @doc """
  Returns the maximum context window in tokens.
  """
  @spec max_context_tokens() :: pos_integer()
  def max_context_tokens, do: @max_context_tokens

  @doc """
  Returns the cost per 1K tokens as {input_cost, output_cost} in USD.
  """
  @spec cost_per_1k_tokens() :: {float(), float()}
  def cost_per_1k_tokens, do: {@input_cost / 1000, @output_cost / 1000}

  # Private functions

  defp build_gemini_opts(provider, opts) do
    base_opts = [
      model: provider.model
    ]

    base_opts
    |> maybe_add_opt(:temperature, Keyword.get(opts, :temperature))
    |> maybe_add_opt(:max_output_tokens, Keyword.get(opts, :max_tokens))
    |> maybe_add_opt(:top_p, Keyword.get(opts, :top_p))
    |> maybe_add_opt(:top_k, Keyword.get(opts, :top_k))
    |> Keyword.merge(Map.to_list(provider.config))
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp stream_response(prompt, opts) do
    Stream.resource(
      fn -> init_stream(prompt, opts) end,
      &next_chunk/1,
      &cleanup_stream/1
    )
  end

  defp init_stream(prompt, opts) do
    case Gemini.stream_generate(prompt, opts) do
      {:ok, stream} -> {:stream, stream}
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_chunk({:stream, stream}) do
    case Enum.take(stream, 1) do
      [chunk] ->
        text = extract_text_from_chunk(chunk)
        {[text], {:stream, Stream.drop(stream, 1)}}

      [] ->
        {:halt, {:stream, stream}}
    end
  end

  defp next_chunk({:error, _} = error), do: {:halt, error}

  defp cleanup_stream(_state), do: :ok

  defp extract_text_from_chunk(chunk) do
    cond do
      is_binary(chunk) ->
        chunk

      is_map(chunk) and Map.has_key?(chunk, :text) ->
        chunk.text

      is_map(chunk) and Map.has_key?(chunk, :candidates) ->
        chunk
        |> Map.get(:candidates, [])
        |> List.first()
        |> case do
          nil -> ""
          candidate -> Map.get(candidate, :content, "") |> extract_content_text()
        end

      true ->
        ""
    end
  end

  defp extract_content_text(content) when is_binary(content), do: content

  defp extract_content_text(content) when is_map(content) do
    content
    |> Map.get(:parts, [])
    |> Enum.map_join("", fn part ->
      if is_map(part), do: Map.get(part, :text, ""), else: ""
    end)
  end

  defp extract_content_text(_), do: ""
end
