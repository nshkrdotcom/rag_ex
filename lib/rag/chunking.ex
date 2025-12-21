defmodule Rag.Chunking do
  @moduledoc """
  Text chunking strategies for document processing.

  Provides multiple strategies for splitting text into chunks:
  - `:character` - Fixed character count with overlap
  - `:sentence` - Split on sentence boundaries
  - `:paragraph` - Split on paragraph boundaries
  - `:recursive` - Hierarchical splitting (paragraph -> sentence -> character)
  - `:semantic` - Embedding-based similarity splitting (requires callback)

  ## Examples

      # Character-based chunking
      iex> Chunking.chunk("Long text...", strategy: :character, max_chars: 200)
      [%{content: "Long text...", index: 0, metadata: %{strategy: :character}}]

      # Sentence-based chunking
      iex> Chunking.chunk("First. Second. Third.", strategy: :sentence)
      [%{content: "First. Second. Third.", index: 0, metadata: %{...}}]

      # Semantic chunking with custom embedding function
      iex> embedding_fn = fn text -> [0.1, 0.2, 0.3] end
      iex> Chunking.chunk("Text here.", strategy: :semantic, embedding_fn: embedding_fn)
      [%{content: "Text here.", index: 0, metadata: %{...}}]
  """

  @type chunk :: %{
          content: String.t(),
          index: non_neg_integer(),
          metadata: map()
        }

  @type strategy :: :character | :sentence | :paragraph | :recursive | :semantic

  @default_max_chars 500
  @default_overlap 50
  @default_semantic_threshold 0.8

  @doc """
  Chunk text using the specified strategy.

  ## Options

  - `:strategy` - Chunking strategy (default: `:character`)
  - `:max_chars` - Maximum characters per chunk (default: 500)
  - `:overlap` - Characters to overlap between chunks for :character strategy (default: 50)
  - `:min_chars` - Minimum characters per chunk for :sentence and :paragraph (default: 100)
  - `:embedding_fn` - Function to generate embeddings for :semantic strategy (required for :semantic)
  - `:threshold` - Similarity threshold for :semantic strategy (default: 0.8)

  ## Examples

      iex> Chunking.chunk("Short text", strategy: :character, max_chars: 100)
      [%{content: "Short text", index: 0, metadata: %{strategy: :character}}]
  """
  @spec chunk(text :: String.t(), opts :: keyword()) :: [chunk()]
  def chunk(text, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :character)
    max_chars = Keyword.get(opts, :max_chars, @default_max_chars)
    overlap = Keyword.get(opts, :overlap, @default_overlap)
    # min_chars is only used when explicitly set
    min_chars = Keyword.get(opts, :min_chars)

    chunks =
      case strategy do
        :character ->
          chunk_by_character(text, max_chars, overlap)

        :sentence ->
          chunk_by_sentence(text, max_chars, min_chars)

        :paragraph ->
          chunk_by_paragraph(text, max_chars, min_chars)

        :recursive ->
          chunk_recursive(text, max_chars, min_chars)

        :semantic ->
          embedding_fn = Keyword.get(opts, :embedding_fn)

          if is_nil(embedding_fn) do
            raise ArgumentError,
                  "embedding_fn is required for semantic chunking strategy"
          end

          threshold = Keyword.get(opts, :threshold, @default_semantic_threshold)
          chunk_by_semantic(text, max_chars, embedding_fn, threshold)

        unknown ->
          raise ArgumentError, "Unknown chunking strategy: #{inspect(unknown)}"
      end

    # Add index and metadata
    chunks
    |> Enum.with_index()
    |> Enum.map(fn {content, index} ->
      %{
        content: content,
        index: index,
        metadata: build_metadata(strategy, chunks, index)
      }
    end)
  end

  ## Character-based chunking

  defp chunk_by_character(text, max_chars, overlap) do
    if String.length(text) <= max_chars do
      [text]
    else
      do_chunk_by_character(text, max_chars, overlap, [])
    end
  end

  defp do_chunk_by_character(text, max_chars, overlap, acc) do
    if String.length(text) <= max_chars do
      Enum.reverse([text | acc])
    else
      # Find smart boundary
      chunk = find_chunk_boundary(text, max_chars)
      chunk_len = String.length(chunk)

      # Calculate start of next chunk with overlap
      # Ensure overlap is less than chunk length to avoid infinite loop
      safe_overlap = min(overlap, max(0, chunk_len - 1))
      next_start = max(1, chunk_len - safe_overlap)
      initial_remaining = String.slice(text, next_start, String.length(text))

      # Safety check: if no progress made, force move forward
      remaining =
        if String.length(initial_remaining) >= String.length(text) do
          # Force advance by at least 1 character to prevent infinite loop
          String.slice(text, 1, String.length(text))
        else
          initial_remaining
        end

      do_chunk_by_character(remaining, max_chars, overlap, [chunk | acc])
    end
  end

  defp find_chunk_boundary(text, max_chars) do
    # Handle very small max_chars
    if max_chars < 1 do
      String.slice(text, 0, 1)
    else
      chunk = String.slice(text, 0, max_chars)

      # Try to find last sentence boundary
      case Regex.run(~r/^(.+[.!?])\s/s, chunk, capture: :all_but_first) do
        [match] when byte_size(match) > div(max(max_chars, 2), 2) ->
          match

        _ ->
          # Fall back to word boundary
          case Regex.run(~r/^(.+)\s/, chunk, capture: :all_but_first) do
            [match] -> match
            _ -> chunk
          end
      end
    end
  end

  ## Sentence-based chunking

  defp chunk_by_sentence(text, max_chars, min_chars) do
    sentences = split_sentences(text)

    sentences
    |> combine_sentences(min_chars, max_chars, [])
    |> Enum.reverse()
  end

  defp split_sentences(text) do
    # Split on sentence boundaries (. ! ?)
    # Keep the punctuation with the sentence
    text
    |> String.split(~r/(?<=[.!?])\s+/)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp combine_sentences([], _min_chars, _max_chars, acc), do: acc

  defp combine_sentences([sentence | rest], min_chars, max_chars, acc) do
    # Try to combine sentences to reach min_chars (or just take sentence if min_chars not set)
    {combined, remaining} = build_sentence_chunk([sentence | rest], min_chars, max_chars, "")

    combine_sentences(remaining, min_chars, max_chars, [combined | acc])
  end

  defp build_sentence_chunk([], _min_chars, _max_chars, current) do
    {String.trim(current), []}
  end

  defp build_sentence_chunk([sentence | rest] = all, min_chars, max_chars, current) do
    candidate =
      if current == "" do
        sentence
      else
        current <> " " <> sentence
      end

    candidate_len = String.length(candidate)

    cond do
      # If adding this sentence exceeds max_chars and we have content, stop
      candidate_len > max_chars and current != "" ->
        {String.trim(current), all}

      # If single sentence exceeds max_chars, split it
      candidate_len > max_chars and current == "" ->
        # Fall back to character chunking for this sentence
        chunks = chunk_by_character(sentence, max_chars, 0)
        {hd(chunks), tl(chunks) ++ rest}

      # If we haven't reached min_chars yet (and min_chars is set), keep adding
      min_chars != nil and candidate_len < min_chars ->
        build_sentence_chunk(rest, min_chars, max_chars, candidate)

      # We've reached a good size or min_chars not set
      true ->
        {String.trim(candidate), rest}
    end
  end

  ## Paragraph-based chunking

  defp chunk_by_paragraph(text, max_chars, min_chars) do
    paragraphs = split_paragraphs(text)

    paragraphs
    |> combine_paragraphs(min_chars, max_chars, [])
    |> Enum.reverse()
  end

  defp split_paragraphs(text) do
    # Split on double newlines (or \r\n\r\n for Windows)
    # Also handle multiple consecutive newlines
    text
    |> String.split(~r/(\r?\n\s*){2,}/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp combine_paragraphs([], _min_chars, _max_chars, acc), do: acc

  defp combine_paragraphs([para | rest], min_chars, max_chars, acc) do
    para_len = String.length(para)

    cond do
      # If paragraph is too long, split it using sentence strategy
      para_len > max_chars ->
        sentence_chunks = chunk_by_sentence(para, max_chars, min_chars)
        combine_paragraphs(rest, min_chars, max_chars, Enum.reverse(sentence_chunks) ++ acc)

      # If paragraph is too short and min_chars is set, try to combine with next
      min_chars != nil and para_len < min_chars and rest != [] ->
        {combined, remaining} = build_paragraph_chunk([para | rest], min_chars, max_chars, "")
        combine_paragraphs(remaining, min_chars, max_chars, [combined | acc])

      # Keep as separate chunk - paragraphs are natural boundaries
      true ->
        combine_paragraphs(rest, min_chars, max_chars, [para | acc])
    end
  end

  defp build_paragraph_chunk([], _min_chars, _max_chars, current) do
    {String.trim(current), []}
  end

  defp build_paragraph_chunk([para | rest] = all, min_chars, max_chars, current) do
    candidate =
      if current == "" do
        para
      else
        current <> "\n\n" <> para
      end

    candidate_len = String.length(candidate)

    cond do
      # If adding this paragraph exceeds max_chars and we have content, stop
      candidate_len > max_chars and current != "" ->
        {String.trim(current), all}

      # If single paragraph exceeds max_chars, split it with sentences
      candidate_len > max_chars and current == "" ->
        chunks = chunk_by_sentence(para, max_chars, min_chars)
        {hd(chunks), tl(chunks) ++ rest}

      # If we haven't reached min_chars yet (and min_chars is set), keep adding
      min_chars != nil and candidate_len < min_chars ->
        build_paragraph_chunk(rest, min_chars, max_chars, candidate)

      # We've reached a good size or min_chars not set
      true ->
        {String.trim(candidate), rest}
    end
  end

  ## Recursive chunking

  defp chunk_recursive(text, max_chars, min_chars) do
    # Try paragraph first
    paragraphs = split_paragraphs(text)

    if length(paragraphs) > 1 do
      # Use paragraph-based chunking with hierarchy tracking
      paragraphs
      |> Enum.flat_map(fn para ->
        recursive_chunk_paragraph(para, max_chars, min_chars)
      end)
    else
      # No paragraph breaks, try sentences
      recursive_chunk_paragraph(text, max_chars, min_chars)
    end
  end

  defp recursive_chunk_paragraph(text, max_chars, min_chars) do
    text_len = String.length(text)

    cond do
      # Fits in one chunk
      text_len <= max_chars ->
        [text]

      # Try sentence-based splitting
      true ->
        sentences = split_sentences(text)

        if length(sentences) > 1 do
          chunk_by_sentence(text, max_chars, min_chars)
        else
          # Fall back to character-based
          chunk_by_character(text, max_chars, 0)
        end
    end
  end

  ## Semantic chunking

  defp chunk_by_semantic(text, max_chars, embedding_fn, threshold) do
    sentences = split_sentences(text)

    if length(sentences) <= 1 do
      sentences
    else
      # Generate embeddings for all sentences
      sentence_embeddings =
        Enum.map(sentences, fn sentence ->
          {sentence, embedding_fn.(sentence)}
        end)

      # Group by similarity
      group_by_similarity(sentence_embeddings, threshold, max_chars, [])
      |> Enum.reverse()
      |> Enum.map(&elem(&1, 0))
    end
  end

  defp group_by_similarity([], _threshold, _max_chars, acc), do: acc

  defp group_by_similarity([{sentence, embedding} | rest], threshold, max_chars, acc) do
    # Start a new group with this sentence
    {group_sentences, group_embedding, remaining} =
      build_semantic_group(rest, [sentence], embedding, threshold, max_chars)

    combined = Enum.join(group_sentences, " ")
    group_by_similarity(remaining, threshold, max_chars, [{combined, group_embedding} | acc])
  end

  defp build_semantic_group([], sentences, embedding, _threshold, _max_chars) do
    {Enum.reverse(sentences), embedding, []}
  end

  defp build_semantic_group(
         [{sentence, sent_emb} | rest] = all,
         sentences,
         group_emb,
         threshold,
         max_chars
       ) do
    # Calculate similarity
    similarity = cosine_similarity(group_emb, sent_emb)

    # Check if adding this sentence would exceed max_chars
    current_length = sentences |> Enum.join(" ") |> String.length()
    candidate_length = current_length + String.length(" " <> sentence)

    cond do
      # Too long, stop grouping
      candidate_length > max_chars ->
        {Enum.reverse(sentences), group_emb, all}

      # Similar enough, add to group
      similarity >= threshold ->
        # Update group embedding (average)
        new_group_emb = average_embeddings(group_emb, sent_emb)

        build_semantic_group(
          rest,
          [sentence | sentences],
          new_group_emb,
          threshold,
          max_chars
        )

      # Not similar, stop grouping
      true ->
        {Enum.reverse(sentences), group_emb, all}
    end
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

  ## Metadata helpers

  defp build_metadata(:recursive, chunks, index) do
    # Determine hierarchy level based on chunk characteristics
    chunk_content = Enum.at(chunks, index)

    hierarchy =
      cond do
        String.contains?(chunk_content, "\n\n") -> :paragraph
        Regex.match?(~r/[.!?]\s/, chunk_content) -> :sentence
        true -> :character
      end

    %{strategy: :recursive, hierarchy: hierarchy}
  end

  defp build_metadata(strategy, _chunks, _index) do
    %{strategy: strategy}
  end
end
