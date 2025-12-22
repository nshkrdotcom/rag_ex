# Chunking Strategies

The `Rag.Chunker` behavior provides pluggable strategies for splitting text into chunks optimized for different use cases.

## Overview

```elixir
alias Rag.Chunker
alias Rag.Chunker.{Character, Sentence, Paragraph, Recursive}

chunker = %Recursive{max_chars: 500}
chunks = Chunker.chunk(chunker, text)
```

Each chunk is a `%Rag.Chunker.Chunk{}` struct:

```elixir
%Rag.Chunker.Chunk{
  content: String.t(),      # The chunk text
  start_byte: non_neg_integer(),
  end_byte: non_neg_integer(),
  index: non_neg_integer(),
  metadata: map()           # Chunker-specific metadata
}
```

## Chunkers

### 1. Character (`Rag.Chunker.Character`)

Fixed-size chunks with smart boundary detection.

```elixir
chunker = %Character{max_chars: 500, overlap: 50}
Chunker.chunk(chunker, text)
```

**Options:**
- `max_chars` - Maximum characters per chunk (default: 500)
- `overlap` - Characters to overlap between chunks (default: 50)

**Behavior:**
1. Splits at sentence boundaries (`.!?`) when possible
2. Falls back to word boundaries
3. Falls back to hard split at max_chars
4. Creates overlap for context preservation

**Best for:**
- Consistent embedding sizes
- Unstructured text
- Predictable chunk sizes

### 2. Sentence (`Rag.Chunker.Sentence`)

Preserves complete sentences within chunks.

```elixir
chunker = %Sentence{max_chars: 500, min_chars: 100}
Chunker.chunk(chunker, text)
```

**Options:**
- `max_chars` - Maximum characters per chunk (default: 500)
- `min_chars` - Minimum characters before starting new chunk (optional)

**Behavior:**
1. Splits on sentence boundaries
2. Combines sentences up to max_chars
3. If min_chars specified, continues until reaching minimum
4. Falls back to character-based if a sentence exceeds max_chars

**Best for:**
- Q&A systems
- Well-structured prose
- Semantic coherence

### 3. Paragraph (`Rag.Chunker.Paragraph`)

Preserves paragraph structure and topic boundaries.

```elixir
chunker = %Paragraph{max_chars: 500, min_chars: 100}
Chunker.chunk(chunker, text)
```

**Options:**
- `max_chars` - Maximum characters per chunk (default: 500)
- `min_chars` - Minimum characters before starting new chunk (optional)

**Behavior:**
1. Splits on paragraph boundaries (double newlines)
2. Combines short paragraphs if under min_chars
3. Falls back to sentence-based if paragraph exceeds max_chars

**Best for:**
- Articles and blog posts
- Documentation
- Topic-organized content

### 4. Recursive (`Rag.Chunker.Recursive`)

Hierarchical splitting from paragraph to sentence to character.

```elixir
chunker = %Recursive{max_chars: 500, min_chars: 100}
Chunker.chunk(chunker, text)
```

**Options:**
- `max_chars` - Maximum characters per chunk (default: 500)
- `min_chars` - Minimum characters per chunk (optional)

**Metadata:**
```elixir
%{chunker: :recursive, hierarchy: :paragraph | :sentence | :character}
```

**Best for:**
- Mixed content structures
- Varying document formats
- Smart hierarchy preservation

### 5. Semantic (`Rag.Chunker.Semantic`)

Groups sentences by semantic similarity using embeddings.

```elixir
alias Rag.Router
alias Rag.Chunker.Semantic

{:ok, router} = Router.new(providers: [:gemini])

embedding_fn = fn text ->
  {:ok, [embedding], _} = Router.execute(router, :embeddings, [text], [])
  embedding
end

chunker = %Semantic{embedding_fn: embedding_fn, threshold: 0.8, max_chars: 500}
Chunker.chunk(chunker, text)
```

**Options:**
- `embedding_fn` - **Required** function to generate embeddings
- `threshold` - Similarity threshold for grouping (default: 0.8)
- `max_chars` - Maximum characters per chunk (default: 500)

**Behavior:**
1. Splits text into sentences
2. Generates embedding for each sentence
3. Groups sentences by cosine similarity
4. Continues adding while similarity >= threshold and under max_chars

**Best for:**
- Topic-focused chunks
- High-quality RAG systems
- When API cost is acceptable

### 6. Format-Aware (`Rag.Chunker.FormatAware`)

Format-aware chunking using TextChunker for code and markup formats.

```elixir
alias Rag.Chunker.FormatAware

chunker = %FormatAware{format: :markdown, chunk_size: 500}
Chunker.chunk(chunker, markdown_text)
```

**Options:**
- `format` - Document format (default: :plaintext)
- `chunk_size` - Maximum size in code points (default: 2000)
- `chunk_overlap` - Overlap between chunks (default: 200)
- `size_fn` - Custom size function `(String.t() -> integer())` (optional)

**Note:** This chunker requires TextChunker:

```elixir
{:text_chunker, "~> 0.5.2"}
```

## Strategy Comparison

| Strategy | Chunk Size | Structure | API Calls | Best For |
|----------|-----------|-----------|-----------|----------|
| Character | Consistent | May split thoughts | None | Predictable sizing |
| Sentence | Variable | Complete thoughts | None | Q&A systems |
| Paragraph | Variable | Topic boundaries | None | Structured docs |
| Recursive | Variable | Smart hierarchy | None | Mixed content |
| Semantic | Variable | Semantic groups | Yes | Topic coherence |
| FormatAware | Variable | Format-aware | None | Code and markup |

## Overlap Demonstration

```elixir
text = "First sentence. Second sentence. Third sentence. Fourth sentence."

# No overlap
Chunker.chunk(%Character{max_chars: 40, overlap: 0}, text)

# With overlap
Chunker.chunk(%Character{max_chars: 40, overlap: 20}, text)
```

Overlap helps:
- Preserve context between chunks
- Improve retrieval for information at chunk boundaries
- Reduce information loss during splitting

## Position Validation

```elixir
alias Rag.Chunker.Chunk

chunker = %Character{max_chars: 100}
chunks = Chunker.chunk(chunker, text)

Enum.all?(chunks, fn chunk ->
  Chunk.valid?(chunk, text)
end)
```

## Complete Example

```elixir
alias Rag.Chunker
alias Rag.Chunker.{Character, Sentence, Paragraph, Recursive, Semantic}

# Load document
text = File.read!("document.md")

# Try different strategies
char_chunks = Chunker.chunk(%Character{max_chars: 500, overlap: 50}, text)
sent_chunks = Chunker.chunk(%Sentence{max_chars: 500}, text)
para_chunks = Chunker.chunk(%Paragraph{max_chars: 500}, text)
rec_chunks = Chunker.chunk(%Recursive{max_chars: 500}, text)

# Semantic chunking (requires embedding function)
embedding_fn = fn text ->
  {:ok, [embedding], _} = Rag.Router.execute(router, :embeddings, [text], [])
  embedding
end

sem_chunks = Chunker.chunk(%Semantic{embedding_fn: embedding_fn, threshold: 0.75}, text)

# Compare results
for {name, chunks} <- [
  {"Character", char_chunks},
  {"Sentence", sent_chunks},
  {"Paragraph", para_chunks},
  {"Recursive", rec_chunks},
  {"Semantic", sem_chunks}
] do
  avg_size = if length(chunks) > 0 do
    total = Enum.reduce(chunks, 0, fn c, acc -> acc + String.length(c.content) end)
    round(total / length(chunks))
  else
    0
  end
  IO.puts("#{name}: #{length(chunks)} chunks, avg #{avg_size} chars")
end
```
