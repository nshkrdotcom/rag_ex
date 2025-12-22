defmodule Rag.Chunker.Character do
  @moduledoc """
  Fixed-size chunking with overlap and smart boundaries.

  Attempts to break at sentence boundaries, falls back to word boundaries,
  then to exact character positions.

  ## Options

  - `max_chars` - Maximum characters per chunk (default: 500)
  - `overlap` - Characters to overlap between chunks (default: 50)
  """

  @behaviour Rag.Chunker

  alias Rag.Chunker.Chunk

  @type t :: %__MODULE__{
          max_chars: pos_integer(),
          overlap: non_neg_integer()
        }

  defstruct max_chars: 500, overlap: 50

  @doc "Returns default options for the character chunker."
  @impl true
  @spec default_opts() :: keyword()
  def default_opts, do: [max_chars: 500, overlap: 50]

  @doc "Split text into character-based chunks."
  @impl true
  @spec chunk(t(), String.t(), keyword()) :: [Chunk.t()]
  def chunk(%__MODULE__{} = chunker, text, opts) when is_binary(text) do
    max_chars = opts[:max_chars] || chunker.max_chars
    overlap = opts[:overlap] || chunker.overlap

    text
    |> character_spans(max_chars, overlap)
    |> build_chunks(text)
  end

  defp character_spans(text, max_chars, overlap) do
    if String.length(text) <= max_chars do
      [{0, byte_size(text)}]
    else
      do_character_spans(text, max_chars, overlap, 0, [])
    end
  end

  defp do_character_spans(text, max_chars, overlap, byte_offset, acc) do
    if String.length(text) <= max_chars do
      Enum.reverse([{byte_offset, byte_offset + byte_size(text)} | acc])
    else
      chunk = find_chunk_boundary(text, max_chars)
      chunk_len = String.length(chunk)
      chunk_bytes = byte_size(chunk)

      safe_overlap = min(overlap, max(0, chunk_len - 1))
      next_start = max(1, chunk_len - safe_overlap)

      initial_remaining = String.slice(text, next_start, String.length(text))

      {advance_chars, remaining} =
        if String.length(initial_remaining) >= String.length(text) do
          {1, String.slice(text, 1, String.length(text))}
        else
          {next_start, initial_remaining}
        end

      advance_bytes = byte_size(String.slice(text, 0, advance_chars))
      next_offset = byte_offset + advance_bytes

      do_character_spans(
        remaining,
        max_chars,
        overlap,
        next_offset,
        [{byte_offset, byte_offset + chunk_bytes} | acc]
      )
    end
  end

  defp find_chunk_boundary(text, max_chars) do
    if max_chars < 1 do
      String.slice(text, 0, 1)
    else
      chunk = String.slice(text, 0, max_chars)

      case Regex.run(~r/^(.+[.!?])\s/s, chunk, capture: :all_but_first) do
        [match] when byte_size(match) > div(max(max_chars, 2), 2) ->
          match

        _ ->
          case Regex.run(~r/^(.+)\s/, chunk, capture: :all_but_first) do
            [match] -> match
            _ -> chunk
          end
      end
    end
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
        metadata: %{chunker: :character}
      })
    end)
  end
end
