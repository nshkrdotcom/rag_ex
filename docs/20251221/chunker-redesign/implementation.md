# Implementation Checklist

## Files to Create

### Core

- [ ] `lib/rag/chunker.ex` - Behavior definition + dispatch
- [ ] `lib/rag/chunker/chunk.ex` - Chunk struct

### Built-in Chunkers

- [ ] `lib/rag/chunker/character.ex`
- [ ] `lib/rag/chunker/sentence.ex`
- [ ] `lib/rag/chunker/paragraph.ex`
- [ ] `lib/rag/chunker/recursive.ex`
- [ ] `lib/rag/chunker/semantic.ex`
- [ ] `lib/rag/chunker/format_aware.ex` (TextChunker adapter)

### Tests

- [ ] `test/rag/chunker_test.exs` - Behavior dispatch tests
- [ ] `test/rag/chunker/chunk_test.exs` - Chunk struct tests
- [ ] `test/rag/chunker/character_test.exs`
- [ ] `test/rag/chunker/sentence_test.exs`
- [ ] `test/rag/chunker/paragraph_test.exs`
- [ ] `test/rag/chunker/recursive_test.exs`
- [ ] `test/rag/chunker/semantic_test.exs`
- [ ] `test/rag/chunker/format_aware_test.exs`

## Files to Delete

- [ ] `lib/rag/chunking.ex`
- [ ] `test/rag/chunking_test.exs`

## Files to Update

### VectorStore Integration

- [ ] `lib/rag/vector_store.ex`
  - Add `from_chunker_chunks/2` function
  - Update any references to old chunking format

### VectorStore Chunk Schema

- [ ] `lib/rag/vector_store/chunk.ex`
  - Ensure metadata can store `start_byte`, `end_byte`, `chunk_index`

### Pipeline Examples

- [ ] Update any pipeline examples in README or docs

### Mix.exs (Optional)

- [ ] Add `text_chunker` to deps if making FormatAware a first-class feature

```elixir
{:text_chunker, "~> 0.5", optional: true}
```

---

## Implementation Order

### Phase 1: Core Infrastructure

```elixir
# 1. Chunk struct
defmodule Rag.Chunker.Chunk do
  @enforce_keys [:content, :start_byte, :end_byte, :index]
  defstruct [:content, :start_byte, :end_byte, :index, metadata: %{}]

  def new(attrs), do: struct!(__MODULE__, attrs)

  def extract_from_source(%{start_byte: s, end_byte: e}, source) do
    binary_part(source, s, e - s)
  end

  def valid?(%{content: c, start_byte: s, end_byte: e}, source) do
    byte_size(c) == e - s and binary_part(source, s, e - s) == c
  end
end

# 2. Behavior
defmodule Rag.Chunker do
  alias Rag.Chunker.Chunk

  @callback chunk(chunker :: struct(), text :: String.t(), opts :: keyword()) :: [Chunk.t()]
  @callback default_opts() :: keyword()
  @optional_callbacks default_opts: 0

  def chunk(%module{} = chunker, text, opts \\ []) do
    defaults = if function_exported?(module, :default_opts, 0), do: module.default_opts(), else: []
    module.chunk(chunker, text, Keyword.merge(defaults, opts))
  end

  def chunk_ingestion(%module{} = chunker, %{document: text} = ingestion, opts \\ []) do
    Map.put(ingestion, :chunks, chunk(chunker, text, opts))
  end
end
```

### Phase 2: Character Chunker (Reference Implementation)

Port logic from `Rag.Chunking.chunk_by_character/3` with byte tracking:

```elixir
defmodule Rag.Chunker.Character do
  @behaviour Rag.Chunker
  alias Rag.Chunker.Chunk

  defstruct max_chars: 500, overlap: 50

  @impl true
  def default_opts, do: [max_chars: 500, overlap: 50]

  @impl true
  def chunk(%__MODULE__{} = chunker, text, opts) do
    max_chars = opts[:max_chars] || chunker.max_chars
    overlap = opts[:overlap] || chunker.overlap

    if String.length(text) <= max_chars do
      [Chunk.new(%{
        content: text,
        start_byte: 0,
        end_byte: byte_size(text),
        index: 0,
        metadata: %{chunker: :character}
      })]
    else
      do_chunk(text, max_chars, overlap, 0, 0, [])
    end
  end

  defp do_chunk(text, max_chars, overlap, byte_offset, index, acc) do
    if String.length(text) <= max_chars do
      chunk = Chunk.new(%{
        content: text,
        start_byte: byte_offset,
        end_byte: byte_offset + byte_size(text),
        index: index,
        metadata: %{chunker: :character}
      })
      Enum.reverse([chunk | acc])
    else
      {content, rest, content_bytes} = find_chunk_boundary(text, max_chars, overlap)

      chunk = Chunk.new(%{
        content: content,
        start_byte: byte_offset,
        end_byte: byte_offset + content_bytes,
        index: index,
        metadata: %{chunker: :character}
      })

      # Calculate next byte offset (accounting for overlap)
      next_offset = byte_offset + content_bytes - overlap_bytes(content, overlap)

      do_chunk(rest, max_chars, overlap, next_offset, index + 1, [chunk | acc])
    end
  end

  defp find_chunk_boundary(text, max_chars, _overlap) do
    chunk = String.slice(text, 0, max_chars)
    chunk_bytes = byte_size(chunk)

    # Try sentence boundary
    case Regex.run(~r/^(.+[.!?])\s/s, chunk, capture: :all_but_first) do
      [match] when byte_size(match) > div(max_chars, 2) ->
        rest_start = String.length(match)
        {match, String.slice(text, rest_start, String.length(text)), byte_size(match)}

      _ ->
        # Try word boundary
        case Regex.run(~r/^(.+)\s/, chunk, capture: :all_but_first) do
          [match] ->
            rest_start = String.length(match)
            {match, String.slice(text, rest_start, String.length(text)), byte_size(match)}

          _ ->
            rest = String.slice(text, max_chars, String.length(text))
            {chunk, rest, chunk_bytes}
        end
    end
  end

  defp overlap_bytes(content, overlap_chars) do
    overlap_text = String.slice(content, -overlap_chars, overlap_chars)
    byte_size(overlap_text)
  end
end
```

### Phase 3: Other Built-in Chunkers

Port remaining strategies, adding byte tracking to each:
- `Sentence` - from `chunk_by_sentence/3`
- `Paragraph` - from `chunk_by_paragraph/3`
- `Recursive` - from `chunk_recursive/3`
- `Semantic` - from `chunk_by_semantic/4`

### Phase 4: FormatAware Chunker

```elixir
defmodule Rag.Chunker.FormatAware do
  @behaviour Rag.Chunker
  alias Rag.Chunker.Chunk

  defstruct format: :plaintext,
            chunk_size: 2000,
            chunk_overlap: 200,
            size_fn: nil

  @impl true
  def default_opts do
    [format: :plaintext, chunk_size: 2000, chunk_overlap: 200]
  end

  @impl true
  def chunk(%__MODULE__{} = chunker, text, opts) do
    # Check TextChunker is available
    unless Code.ensure_loaded?(TextChunker) do
      raise "TextChunker is required for FormatAware chunker. Add {:text_chunker, \"~> 0.5\"} to deps."
    end

    tc_opts = [
      format: opts[:format] || chunker.format,
      chunk_size: opts[:chunk_size] || chunker.chunk_size,
      chunk_overlap: opts[:chunk_overlap] || chunker.chunk_overlap
    ]

    tc_opts =
      if size_fn = chunker.size_fn || opts[:size_fn] do
        Keyword.put(tc_opts, :get_chunk_size, size_fn)
      else
        tc_opts
      end

    case TextChunker.split(text, tc_opts) do
      {:error, msg} ->
        raise ArgumentError, "TextChunker error: #{msg}"

      tc_chunks ->
        tc_chunks
        |> Enum.with_index()
        |> Enum.map(fn {tc, idx} ->
          Chunk.new(%{
            content: tc.text,
            start_byte: tc.start_byte,
            end_byte: tc.end_byte,
            index: idx,
            metadata: %{chunker: :format_aware, format: tc_opts[:format]}
          })
        end)
    end
  end
end
```

### Phase 5: VectorStore Integration

```elixir
# In lib/rag/vector_store.ex

@doc """
Convert Chunker.Chunk structs to VectorStore format.

Preserves byte positions in metadata for source highlighting.
"""
def from_chunker_chunks(chunks, source) when is_list(chunks) do
  Enum.map(chunks, fn %Rag.Chunker.Chunk{} = chunk ->
    build_chunk(%{
      content: chunk.content,
      source: source,
      metadata: Map.merge(chunk.metadata, %{
        start_byte: chunk.start_byte,
        end_byte: chunk.end_byte,
        chunk_index: chunk.index
      })
    })
  end)
end
```

### Phase 6: Update Tests

Migrate tests from `chunking_test.exs` to individual chunker test files.

Key test patterns:
```elixir
defmodule Rag.Chunker.CharacterTest do
  use ExUnit.Case
  alias Rag.Chunker
  alias Rag.Chunker.{Character, Chunk}

  describe "chunk/3" do
    test "returns Chunk structs" do
      chunker = %Character{}
      [chunk | _] = Chunker.chunk(chunker, "Hello world")

      assert %Chunk{} = chunk
      assert is_binary(chunk.content)
      assert is_integer(chunk.start_byte)
      assert is_integer(chunk.end_byte)
      assert is_integer(chunk.index)
      assert is_map(chunk.metadata)
    end

    test "respects max_chars" do
      chunker = %Character{max_chars: 50}
      text = String.duplicate("word ", 100)

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn c -> String.length(c.content) <= 50 end)
    end

    test "byte positions are accurate" do
      chunker = %Character{max_chars: 30, overlap: 0}
      text = "Hello world. This is a test."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn c -> Chunk.valid?(c, text) end)
    end

    test "handles Unicode" do
      chunker = %Character{max_chars: 20}
      text = "Hello 世界 Привет"

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn c -> Chunk.valid?(c, text) end)
    end

    test "handles empty text" do
      chunker = %Character{}

      [chunk] = Chunker.chunk(chunker, "")

      assert chunk.content == ""
      assert chunk.start_byte == 0
      assert chunk.end_byte == 0
    end
  end
end
```

### Phase 7: Cleanup

- Delete `lib/rag/chunking.ex`
- Delete `test/rag/chunking_test.exs`
- Update README if it references old API
- Update any example code

---

## TextChunker Dependency

### Option A: Optional Dependency

```elixir
# mix.exs
defp deps do
  [
    {:text_chunker, "~> 0.5", optional: true}
  ]
end
```

```elixir
# In FormatAware
def chunk(%__MODULE__{} = chunker, text, opts) do
  unless Code.ensure_loaded?(TextChunker) do
    raise """
    FormatAware chunker requires TextChunker.
    Add to your deps: {:text_chunker, "~> 0.5"}
    """
  end
  # ...
end
```

### Option B: Inline TextChunker

If you want to avoid the external dependency, the TextChunker logic could be vendored into `lib/rag/chunker/format_aware/` with:
- `separators.ex` - Format-specific separator lists
- `recursive_split.ex` - Core algorithm

This gives full control but requires maintenance.

### Recommendation

**Option A (optional dep)** is cleaner. Users who need format-aware chunking add the dep; others use built-in chunkers.

---

## Migration Guide for Existing Code

| Before | After |
|--------|-------|
| `Rag.Chunking.chunk(text, strategy: :character, max_chars: 500)` | `Rag.Chunker.chunk(%Rag.Chunker.Character{max_chars: 500}, text)` |
| `Rag.Chunking.chunk(text, strategy: :sentence)` | `Rag.Chunker.chunk(%Rag.Chunker.Sentence{}, text)` |
| `Rag.Chunking.chunk(text, strategy: :paragraph)` | `Rag.Chunker.chunk(%Rag.Chunker.Paragraph{}, text)` |
| `Rag.Chunking.chunk(text, strategy: :recursive)` | `Rag.Chunker.chunk(%Rag.Chunker.Recursive{}, text)` |
| `Rag.Chunking.chunk(text, strategy: :semantic, embedding_fn: fn)` | `Rag.Chunker.chunk(%Rag.Chunker.Semantic{embedding_fn: fn}, text)` |
| `chunk.content` | `chunk.content` (unchanged) |
| `chunk.index` | `chunk.index` (unchanged) |
| `chunk.metadata.strategy` | `chunk.metadata.chunker` |
| N/A | `chunk.start_byte` (new) |
| N/A | `chunk.end_byte` (new) |
