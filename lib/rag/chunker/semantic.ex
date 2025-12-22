defmodule Rag.Chunker.Semantic do
  @moduledoc """
  Semantic chunking using embedding similarity.

  Groups sentences based on embedding similarity. Starts a new chunk
  when similarity drops below threshold or max_chars is reached.

  ## Options

  - `embedding_fn` - Function `(String.t() -> [float()])` to generate embeddings (required)
  - `threshold` - Similarity threshold for grouping (default: 0.8)
  - `max_chars` - Maximum characters per chunk (default: 500)
  """

  @behaviour Rag.Chunker

  alias Rag.Chunker.Chunk

  @type embedding :: [float()]

  @type t :: %__MODULE__{
          embedding_fn: (String.t() -> embedding()) | nil,
          threshold: float(),
          max_chars: pos_integer()
        }

  @enforce_keys [:embedding_fn]
  defstruct [:embedding_fn, threshold: 0.8, max_chars: 500]

  @doc "Returns default options for the semantic chunker."
  @impl true
  @spec default_opts() :: keyword()
  def default_opts, do: [threshold: 0.8, max_chars: 500]

  @doc "Split text into semantic chunks using embedding similarity."
  @impl true
  @spec chunk(t(), String.t(), keyword()) :: [Chunk.t()]
  def chunk(%__MODULE__{embedding_fn: nil}, _text, _opts) do
    raise ArgumentError, "embedding_fn is required for semantic chunking"
  end

  def chunk(%__MODULE__{} = chunker, text, opts) when is_binary(text) do
    threshold = opts[:threshold] || chunker.threshold
    max_chars = opts[:max_chars] || chunker.max_chars
    embedding_fn = chunker.embedding_fn

    sentence_spans = sentence_spans(text)

    case length(sentence_spans) do
      0 ->
        []

      1 ->
        build_chunks(sentence_spans, text)

      _ ->
        sentence_embeddings =
          Enum.map(sentence_spans, fn {start_byte, end_byte} = span ->
            content = binary_part(text, start_byte, end_byte - start_byte)
            {span, embedding_fn.(content)}
          end)

        sentence_embeddings
        |> group_by_similarity(threshold, max_chars, text, [])
        |> build_chunks(text)
    end
  end

  defp sentence_spans(text) do
    total_bytes = byte_size(text)

    if total_bytes == 0 do
      []
    else
      boundaries =
        Regex.scan(~r/[.!?](?=\s|$)/, text, return: :index)
        |> Enum.map(fn [{start, len}] -> start + len end)

      {spans, last_start} =
        Enum.reduce(boundaries, {[], 0}, fn end_byte, {acc, start_byte} ->
          if end_byte < start_byte do
            {acc, start_byte}
          else
            segment = binary_part(text, start_byte, end_byte - start_byte)
            next_start = skip_whitespace(text, end_byte)

            if String.trim(segment) == "" do
              {acc, next_start}
            else
              {acc ++ [{start_byte, end_byte}], next_start}
            end
          end
        end)

      spans =
        if last_start < total_bytes do
          segment = binary_part(text, last_start, total_bytes - last_start)

          if String.trim(segment) == "" do
            spans
          else
            spans ++ [{last_start, total_bytes}]
          end
        else
          spans
        end

      spans
    end
  end

  defp skip_whitespace(text, start_byte) do
    total_bytes = byte_size(text)

    if start_byte >= total_bytes do
      start_byte
    else
      remaining = binary_part(text, start_byte, total_bytes - start_byte)

      case Regex.run(~r/^\s+/, remaining) do
        [match] -> start_byte + byte_size(match)
        nil -> start_byte
      end
    end
  end

  defp group_by_similarity([], _threshold, _max_chars, _text, acc), do: Enum.reverse(acc)

  defp group_by_similarity([{span, embedding} | rest], threshold, max_chars, text, acc) do
    {group_start, group_end, _group_embedding, remaining} =
      build_semantic_group(rest, span, embedding, threshold, max_chars, text)

    group_by_similarity(remaining, threshold, max_chars, text, [{group_start, group_end} | acc])
  end

  defp build_semantic_group([], {start_byte, end_byte}, embedding, _threshold, _max_chars, _text) do
    {start_byte, end_byte, embedding, []}
  end

  defp build_semantic_group(
         [{next_span, next_embedding} | rest] = all,
         {start_byte, end_byte},
         embedding,
         threshold,
         max_chars,
         text
       ) do
    similarity = cosine_similarity(embedding, next_embedding)
    candidate_span = {start_byte, elem(next_span, 1)}
    candidate_len = span_length(text, candidate_span)

    cond do
      candidate_len > max_chars ->
        {start_byte, end_byte, embedding, all}

      similarity >= threshold ->
        new_embedding = average_embeddings(embedding, next_embedding)

        build_semantic_group(
          rest,
          {start_byte, elem(next_span, 1)},
          new_embedding,
          threshold,
          max_chars,
          text
        )

      true ->
        {start_byte, end_byte, embedding, all}
    end
  end

  defp span_length(text, {start_byte, end_byte}) do
    text
    |> binary_part(start_byte, end_byte - start_byte)
    |> String.length()
  end

  defp cosine_similarity(vec1, vec2) do
    dot_product = Enum.zip(vec1, vec2) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()

    magnitude1 = :math.sqrt(Enum.map(vec1, &(&1 * &1)) |> Enum.sum())
    magnitude2 = :math.sqrt(Enum.map(vec2, &(&1 * &1)) |> Enum.sum())

    if magnitude1 == 0 or magnitude2 == 0 do
      0.0
    else
      dot_product / (magnitude1 * magnitude2)
    end
  end

  defp average_embeddings(vec1, vec2) do
    Enum.zip(vec1, vec2)
    |> Enum.map(fn {a, b} -> (a + b) / 2 end)
  end

  defp build_chunks(spans, text) do
    spans
    |> Enum.with_index()
    |> Enum.map(fn {{start_byte, end_byte}, index} ->
      content = binary_part(text, start_byte, end_byte - start_byte)

      Chunk.new(%{
        content: content,
        start_byte: start_byte,
        end_byte: end_byte,
        index: index,
        metadata: %{chunker: :semantic}
      })
    end)
  end
end
