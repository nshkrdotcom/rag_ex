defmodule Rag.Chunker.Paragraph do
  @moduledoc """
  Paragraph-boundary chunking.

  Splits on double newlines. Long paragraphs fall back to sentence splitting.
  Short paragraphs can be combined with min_chars.

  ## Options

  - `max_chars` - Maximum characters per chunk (default: 500)
  - `min_chars` - Minimum characters, combines short paragraphs (default: nil)
  """

  @behaviour Rag.Chunker

  alias Rag.Chunker.Chunk

  @type t :: %__MODULE__{
          max_chars: pos_integer(),
          min_chars: pos_integer() | nil
        }

  defstruct max_chars: 500, min_chars: nil

  @doc "Returns default options for the paragraph chunker."
  @impl true
  @spec default_opts() :: keyword()
  def default_opts, do: [max_chars: 500, min_chars: nil]

  @doc "Split text into paragraph-based chunks."
  @impl true
  @spec chunk(t(), String.t(), keyword()) :: [Chunk.t()]
  def chunk(%__MODULE__{} = chunker, text, opts) when is_binary(text) do
    max_chars = opts[:max_chars] || chunker.max_chars
    min_chars = opts[:min_chars] || chunker.min_chars

    text
    |> paragraph_spans()
    |> combine_paragraphs(text, min_chars, max_chars)
    |> build_chunks(text)
  end

  defp paragraph_spans(text) do
    total_bytes = byte_size(text)

    separators =
      Regex.scan(~r/(\r?\n\s*){2,}/, text, return: :index)
      |> Enum.map(fn [{start, len} | _] -> {start, len} end)

    {spans, last_start} =
      Enum.reduce(separators, {[], 0}, fn {sep_start, sep_len}, {acc, start_byte} ->
        span = trimmed_span(text, start_byte, sep_start)
        acc = maybe_add_span(acc, span)
        {acc, sep_start + sep_len}
      end)

    spans
    |> maybe_add_span(trimmed_span(text, last_start, total_bytes))
  end

  defp trimmed_span(text, start_byte, end_byte) when end_byte >= start_byte do
    segment = binary_part(text, start_byte, end_byte - start_byte)
    leading_trimmed = String.trim_leading(segment)
    leading_bytes = byte_size(segment) - byte_size(leading_trimmed)
    trimmed = String.trim_trailing(leading_trimmed)
    trailing_bytes = byte_size(leading_trimmed) - byte_size(trimmed)

    if trimmed == "" do
      nil
    else
      {start_byte + leading_bytes, end_byte - trailing_bytes}
    end
  end

  defp maybe_add_span(spans, nil), do: spans
  defp maybe_add_span(spans, span), do: spans ++ [span]

  defp combine_paragraphs(spans, _text, _min_chars, _max_chars) when spans == [], do: []

  defp combine_paragraphs(spans, text, min_chars, max_chars) do
    do_combine_paragraphs(spans, text, min_chars, max_chars, [])
  end

  defp do_combine_paragraphs([], _text, _min_chars, _max_chars, acc), do: Enum.reverse(acc)

  defp do_combine_paragraphs([para | rest], text, min_chars, max_chars, acc) do
    para_len = span_length(text, para)

    cond do
      para_len > max_chars ->
        sentence_spans = split_paragraph_with_sentences(para, text, min_chars, max_chars)

        do_combine_paragraphs(
          rest,
          text,
          min_chars,
          max_chars,
          Enum.reverse(sentence_spans) ++ acc
        )

      min_chars != nil and para_len < min_chars and rest != [] ->
        {combined, remaining} =
          build_paragraph_chunk([para | rest], text, min_chars, max_chars, nil)

        do_combine_paragraphs(remaining, text, min_chars, max_chars, [combined | acc])

      true ->
        do_combine_paragraphs(rest, text, min_chars, max_chars, [para | acc])
    end
  end

  defp build_paragraph_chunk([], _text, _min_chars, _max_chars, current_span) do
    {current_span, []}
  end

  defp build_paragraph_chunk([para | rest] = all, text, min_chars, max_chars, current_span) do
    candidate_span = merge_span(current_span, para)
    candidate_len = span_length(text, candidate_span)

    cond do
      candidate_len > max_chars and current_span != nil ->
        {current_span, all}

      candidate_len > max_chars and current_span == nil ->
        split_spans = split_paragraph_with_sentences(para, text, min_chars, max_chars)
        [first | remaining] = split_spans
        {first, remaining ++ rest}

      min_chars != nil and candidate_len < min_chars ->
        build_paragraph_chunk(rest, text, min_chars, max_chars, candidate_span)

      true ->
        {candidate_span, rest}
    end
  end

  defp split_paragraph_with_sentences({start_byte, end_byte}, text, min_chars, max_chars) do
    segment = binary_part(text, start_byte, end_byte - start_byte)

    segment
    |> sentence_spans()
    |> combine_sentences(segment, min_chars, max_chars)
    |> Enum.map(fn {seg_start, seg_end} -> {start_byte + seg_start, start_byte + seg_end} end)
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

  defp combine_sentences(spans, _text, _min_chars, _max_chars) when spans == [], do: []

  defp combine_sentences(spans, text, min_chars, max_chars) do
    do_combine_sentences(spans, text, min_chars, max_chars, [])
  end

  defp do_combine_sentences([], _text, _min_chars, _max_chars, acc), do: Enum.reverse(acc)

  defp do_combine_sentences([span | rest], text, min_chars, max_chars, acc) do
    {combined, remaining} = build_sentence_chunk([span | rest], text, min_chars, max_chars, nil)
    do_combine_sentences(remaining, text, min_chars, max_chars, [combined | acc])
  end

  defp build_sentence_chunk([], _text, _min_chars, _max_chars, current_span) do
    {current_span, []}
  end

  defp build_sentence_chunk([span | rest] = all, text, min_chars, max_chars, current_span) do
    candidate_span = merge_span(current_span, span)
    candidate_len = span_length(text, candidate_span)

    cond do
      candidate_len > max_chars and current_span != nil ->
        {current_span, all}

      candidate_len > max_chars and current_span == nil ->
        split_spans = split_span_by_character(span, text, max_chars)
        [first | remaining_spans] = split_spans
        {first, remaining_spans ++ rest}

      min_chars != nil and candidate_len < min_chars ->
        build_sentence_chunk(rest, text, min_chars, max_chars, candidate_span)

      true ->
        {candidate_span, rest}
    end
  end

  defp split_span_by_character({start_byte, end_byte}, text, max_chars) do
    segment = binary_part(text, start_byte, end_byte - start_byte)

    segment
    |> character_spans(max_chars, 0)
    |> Enum.map(fn {seg_start, seg_end} -> {start_byte + seg_start, start_byte + seg_end} end)
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

  defp merge_span(nil, {start_byte, end_byte}), do: {start_byte, end_byte}
  defp merge_span({start_byte, _end_byte}, {_next_start, next_end}), do: {start_byte, next_end}

  defp span_length(text, {start_byte, end_byte}) do
    text
    |> binary_part(start_byte, end_byte - start_byte)
    |> String.length()
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
        metadata: %{chunker: :paragraph}
      })
    end)
  end
end
