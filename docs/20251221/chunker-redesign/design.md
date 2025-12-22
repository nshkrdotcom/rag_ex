# Chunker Design

## Motivation

### Problem: Architectural Inconsistency

The current `Rag.Chunking` module uses a case-statement dispatch:

```elixir
def chunk(text, opts \\ []) do
  strategy = Keyword.get(opts, :strategy, :character)
  case strategy do
    :character -> chunk_by_character(text, max_chars, overlap)
    :sentence -> chunk_by_sentence(text, max_chars, min_chars)
    :paragraph -> chunk_by_paragraph(text, max_chars, min_chars)
    :recursive -> chunk_recursive(text, max_chars, min_chars)
    :semantic -> chunk_by_semantic(text, max_chars, embedding_fn, threshold)
  end
end
```

Every other major component in rag_ex uses behaviors:

| Component | Behavior | Implementations |
|-----------|----------|-----------------|
| Retrieval | `Rag.Retriever` | Semantic, FullText, Hybrid, Graph |
| Reranking | `Rag.Reranker` | Passthrough, LLM |
| Providers | `Rag.Ai.Provider` | Gemini, Claude, Ollama, Codex, etc. |
| Vector Store | `Rag.VectorStore.Store` | Pgvector |
| Routing | `Rag.Router.Strategy` | Fallback, RoundRobin, Specialist |

Chunking should follow the same pattern.

### Problem: No Position Tracking

Current output format:
```elixir
%{content: "chunk text", index: 0, metadata: %{strategy: :character}}
```

Missing `start_byte` and `end_byte` means:
- Cannot highlight source locations in UI
- Cannot reconstruct original document with gaps
- Cannot correlate retrieved chunks back to source positions

### Problem: No External Chunker Support

TextChunker provides format-aware chunking (19 formats including Elixir, Python, Markdown, HTML) with proper byte tracking. Currently no clean way to integrate it.

---

## Architecture

### Core Behavior

```elixir
defmodule Rag.Chunker do
  @moduledoc """
  Behavior for text chunking strategies.

  Chunkers split text into smaller pieces suitable for embedding and retrieval.
  Each chunk includes byte positions for source reconstruction.
  """

  alias Rag.Chunker.Chunk

  @type t :: struct()

  @doc """
  Split text into chunks.

  Returns a list of Chunk structs with content, positions, and metadata.
  """
  @callback chunk(chunker :: t(), text :: String.t(), opts :: keyword()) :: [Chunk.t()]

  @doc """
  Returns default options for this chunker.
  """
  @callback default_opts() :: keyword()

  @optional_callbacks default_opts: 0

  @doc """
  Dispatch to chunker implementation.
  """
  def chunk(%module{} = chunker, text, opts \\ []) do
    default = if function_exported?(module, :default_opts, 0), do: module.default_opts(), else: []
    merged_opts = Keyword.merge(default, opts)
    module.chunk(chunker, text, merged_opts)
  end
end
```

### Chunk Struct

```elixir
defmodule Rag.Chunker.Chunk do
  @moduledoc """
  Represents a chunk of text with position information.

  ## Fields

  - `content` - The text content of the chunk
  - `start_byte` - Byte offset where chunk begins in source text
  - `end_byte` - Byte offset where chunk ends in source text
  - `index` - Sequential index (0-based) among sibling chunks
  - `metadata` - Additional information (chunker type, hierarchy level, etc.)
  """

  @type t :: %__MODULE__{
    content: String.t(),
    start_byte: non_neg_integer(),
    end_byte: non_neg_integer(),
    index: non_neg_integer(),
    metadata: map()
  }

  @enforce_keys [:content, :start_byte, :end_byte, :index]
  defstruct [
    :content,
    :start_byte,
    :end_byte,
    :index,
    metadata: %{}
  ]

  @doc """
  Create a new chunk.
  """
  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Extract the chunk's content from the original text using byte positions.

  Useful for verifying chunk accuracy.
  """
  def extract_from_source(%__MODULE__{start_byte: s, end_byte: e}, source_text) do
    binary_part(source_text, s, e - s)
  end

  @doc """
  Check if chunk positions correctly match the content.
  """
  def valid?(%__MODULE__{content: content, start_byte: s, end_byte: e}, source_text) do
    byte_size(content) == e - s and
      binary_part(source_text, s, e - s) == content
  end
end
```

---

## Built-in Chunkers

### 1. Character Chunker

Fixed-size chunks with smart boundary detection (sentence, then word).

```elixir
defmodule Rag.Chunker.Character do
  @behaviour Rag.Chunker

  @moduledoc """
  Fixed-size chunking with overlap and smart boundaries.

  Attempts to break at sentence boundaries, falls back to word boundaries,
  then to exact character positions.

  ## Options

  - `max_chars` - Maximum characters per chunk (default: 500)
  - `overlap` - Characters to overlap between chunks (default: 50)
  """

  defstruct max_chars: 500, overlap: 50

  @impl true
  def default_opts, do: [max_chars: 500, overlap: 50]

  @impl true
  def chunk(%__MODULE__{} = chunker, text, opts) do
    max_chars = opts[:max_chars] || chunker.max_chars
    overlap = opts[:overlap] || chunker.overlap

    do_chunk(text, max_chars, overlap, 0, [])
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {{content, start_byte, end_byte}, index} ->
      Chunk.new(%{
        content: content,
        start_byte: start_byte,
        end_byte: end_byte,
        index: index,
        metadata: %{chunker: :character}
      })
    end)
  end

  # Implementation details...
end
```

### 2. Sentence Chunker

Split on sentence boundaries, combine to meet size targets.

```elixir
defmodule Rag.Chunker.Sentence do
  @behaviour Rag.Chunker

  @moduledoc """
  Sentence-boundary chunking.

  Splits text at sentence endings (.!?) and combines sentences
  to reach target size while respecting max_chars limit.

  ## Options

  - `max_chars` - Maximum characters per chunk (default: 500)
  - `min_chars` - Minimum characters per chunk, combines small sentences (default: nil)
  """

  defstruct max_chars: 500, min_chars: nil

  @impl true
  def default_opts, do: [max_chars: 500, min_chars: nil]

  @impl true
  def chunk(%__MODULE__{} = chunker, text, opts) do
    max_chars = opts[:max_chars] || chunker.max_chars
    min_chars = opts[:min_chars] || chunker.min_chars

    # Split into sentences, combine as needed, track positions
    # ...
  end
end
```

### 3. Paragraph Chunker

Split on paragraph boundaries (double newlines).

```elixir
defmodule Rag.Chunker.Paragraph do
  @behaviour Rag.Chunker

  @moduledoc """
  Paragraph-boundary chunking.

  Splits on double newlines. Long paragraphs fall back to sentence splitting.
  Short paragraphs can be combined with min_chars.

  ## Options

  - `max_chars` - Maximum characters per chunk (default: 500)
  - `min_chars` - Minimum characters, combines short paragraphs (default: nil)
  """

  defstruct max_chars: 500, min_chars: nil
end
```

### 4. Recursive Chunker

Hierarchical splitting: paragraph -> sentence -> character.

```elixir
defmodule Rag.Chunker.Recursive do
  @behaviour Rag.Chunker

  @moduledoc """
  Hierarchical recursive chunking.

  Tries paragraph boundaries first, falls back to sentence boundaries,
  then to character boundaries. Preserves semantic structure when possible.

  ## Options

  - `max_chars` - Maximum characters per chunk (default: 500)
  - `min_chars` - Minimum characters per chunk (default: nil)

  ## Metadata

  Each chunk's metadata includes `:hierarchy` indicating the level
  at which it was split: `:paragraph`, `:sentence`, or `:character`.
  """

  defstruct max_chars: 500, min_chars: nil

  @impl true
  def chunk(%__MODULE__{} = chunker, text, opts) do
    # Try paragraph -> sentence -> character
    # Track hierarchy level in metadata
  end
end
```

### 5. Semantic Chunker

Embedding-based similarity grouping.

```elixir
defmodule Rag.Chunker.Semantic do
  @behaviour Rag.Chunker

  @moduledoc """
  Semantic chunking using embedding similarity.

  Groups sentences based on embedding similarity. Starts a new chunk
  when similarity drops below threshold or max_chars is reached.

  ## Options

  - `embedding_fn` - Function `(String.t() -> [float()])` to generate embeddings (required)
  - `threshold` - Similarity threshold for grouping (default: 0.8)
  - `max_chars` - Maximum characters per chunk (default: 500)

  ## Example

      chunker = %Rag.Chunker.Semantic{
        embedding_fn: fn text -> MyApp.Embeddings.generate(text) end,
        threshold: 0.85
      }
      chunks = Rag.Chunker.chunk(chunker, text)
  """

  @enforce_keys [:embedding_fn]
  defstruct [:embedding_fn, threshold: 0.8, max_chars: 500]

  @impl true
  def default_opts, do: [threshold: 0.8, max_chars: 500]

  @impl true
  def chunk(%__MODULE__{embedding_fn: nil}, _text, _opts) do
    raise ArgumentError, "embedding_fn is required for semantic chunking"
  end

  def chunk(%__MODULE__{} = chunker, text, opts) do
    threshold = opts[:threshold] || chunker.threshold
    max_chars = opts[:max_chars] || chunker.max_chars
    embedding_fn = chunker.embedding_fn

    # Split into sentences
    # Generate embeddings
    # Group by cosine similarity
    # Track byte positions
  end
end
```

### 6. Format-Aware Chunker (TextChunker Adapter)

Delegates to TextChunker for format-specific separators.

```elixir
defmodule Rag.Chunker.FormatAware do
  @behaviour Rag.Chunker

  @moduledoc """
  Format-aware chunking using TextChunker.

  Provides intelligent splitting for code and markup formats using
  language-specific separators (function definitions, class declarations,
  heading levels, etc.).

  ## Supported Formats

  - Code: `:elixir`, `:python`, `:javascript`, `:typescript`, `:ruby`, `:php`, `:vue`
  - Markup: `:markdown`, `:html`, `:latex`
  - Documents: `:plaintext`, `:doc`, `:docx`, `:pdf`, `:rtf`, `:epub`, `:odt`

  ## Options

  - `format` - Document format (default: `:plaintext`)
  - `chunk_size` - Maximum chunk size in code points (default: 2000)
  - `chunk_overlap` - Overlap between chunks (default: 200)
  - `size_fn` - Custom size function `(String.t() -> integer())` (default: String.length/1)

  ## Example

      # Chunk Elixir source code
      chunker = %Rag.Chunker.FormatAware{format: :elixir, chunk_size: 1500}
      chunks = Rag.Chunker.chunk(chunker, elixir_code)

      # Chunk Markdown with custom token counting
      chunker = %Rag.Chunker.FormatAware{
        format: :markdown,
        chunk_size: 500,
        size_fn: &MyApp.Tokenizer.count_tokens/1
      }
      chunks = Rag.Chunker.chunk(chunker, markdown_text)
  """

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
      {:error, message} ->
        raise ArgumentError, "TextChunker error: #{message}"

      chunks ->
        chunks
        |> Enum.with_index()
        |> Enum.map(fn {tc_chunk, index} ->
          Chunk.new(%{
            content: tc_chunk.text,
            start_byte: tc_chunk.start_byte,
            end_byte: tc_chunk.end_byte,
            index: index,
            metadata: %{
              chunker: :format_aware,
              format: tc_opts[:format]
            }
          })
        end)
    end
  end
end
```

---

## Pipeline Integration

### As a Pipeline Step

```elixir
pipeline = %Pipeline{
  name: :ingest,
  steps: [
    %Step{
      name: :load,
      module: Rag.Loading,
      function: :load_file
    },
    %Step{
      name: :chunk,
      module: Rag.Chunker,
      function: :chunk,
      args: [
        chunker: %Rag.Chunker.Recursive{max_chars: 500}
      ],
      inputs: [:load]  # Gets document from load step
    },
    %Step{
      name: :embed,
      module: Rag.Embedding,
      function: :generate_embeddings_batch,
      inputs: [:chunk]
    }
  ]
}
```

### Helper for Ingestion Flow

```elixir
defmodule Rag.Chunker do
  # ... behavior definition ...

  @doc """
  Chunk an ingestion map, adding chunks to the result.

  Expects input map with `:document` key containing text.
  Returns map with `:chunks` key containing chunk list.
  """
  def chunk_ingestion(%module{} = chunker, %{document: text} = ingestion, opts \\ []) do
    chunks = chunk(chunker, text, opts)
    Map.put(ingestion, :chunks, chunks)
  end
end
```

---

## VectorStore Integration

Update `Rag.VectorStore` to work with new chunk format:

```elixir
defmodule Rag.VectorStore do
  alias Rag.Chunker.Chunk

  @doc """
  Convert Chunker.Chunk structs to VectorStore.Chunk structs.
  """
  def from_chunker_chunks(chunks, source) when is_list(chunks) do
    Enum.map(chunks, fn %Chunk{} = chunk ->
      %Rag.VectorStore.Chunk{
        content: chunk.content,
        source: source,
        metadata: Map.merge(chunk.metadata, %{
          start_byte: chunk.start_byte,
          end_byte: chunk.end_byte,
          chunk_index: chunk.index
        })
      }
    end)
  end
end
```

---

## Custom Chunker Implementation

Users can implement custom chunkers:

```elixir
defmodule MyApp.Chunker.ByHeading do
  @behaviour Rag.Chunker

  @moduledoc """
  Split Markdown by heading levels.
  """

  defstruct max_level: 2  # Split on h1 and h2

  @impl true
  def default_opts, do: [max_level: 2]

  @impl true
  def chunk(%__MODULE__{} = chunker, text, opts) do
    max_level = opts[:max_level] || chunker.max_level

    # Custom implementation
    heading_pattern = Regex.compile!("^(\#{1,#{max_level}})\\s+", [:multiline])

    # Split by headings, track positions, return Chunk structs
    # ...
  end
end
```

---

## Comparison with Prior Design

| Aspect | Old `Rag.Chunking` | New `Rag.Chunker` |
|--------|-------------------|-------------------|
| Pattern | Case-statement dispatch | Behavior + struct dispatch |
| Extensibility | Modify source code | Implement behavior |
| Configuration | Keyword options | Struct fields + options |
| Position tracking | None | `start_byte`/`end_byte` on all chunks |
| External chunkers | Not supported | Adapter pattern |
| Pipeline integration | Manual | First-class support |
| Library consistency | Inconsistent | Matches other behaviors |

---

## Testing Strategy

Each chunker should test:

1. **Basic splitting** - Produces expected number of chunks
2. **Size limits** - All chunks respect max_chars
3. **Position accuracy** - `Chunk.valid?(chunk, source_text)` for all chunks
4. **Reconstruction** - Chunks can be reassembled (accounting for overlaps)
5. **Edge cases** - Empty text, single word, very long words, Unicode
6. **Metadata** - Correct chunker type and hierarchy info

```elixir
defmodule Rag.Chunker.CharacterTest do
  use ExUnit.Case
  alias Rag.Chunker
  alias Rag.Chunker.{Character, Chunk}

  describe "chunk/3" do
    test "respects max_chars limit" do
      chunker = %Character{max_chars: 100}
      text = String.duplicate("word ", 100)

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn c -> String.length(c.content) <= 100 end)
    end

    test "tracks byte positions accurately" do
      chunker = %Character{max_chars: 50, overlap: 0}
      text = "Hello world. This is a test. Another sentence here."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk ->
        Chunk.valid?(chunk, text)
      end)
    end

    test "handles Unicode correctly" do
      chunker = %Character{max_chars: 20}
      text = "Hello 世界. Привет мир."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, &Chunk.valid?(&1, text))
    end
  end
end
```
