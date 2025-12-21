# Chunking Strategies

The Chunking module provides five strategies for splitting text into chunks optimized for different use cases.

## Overview

```elixir
alias Rag.Chunking

chunks = Chunking.chunk(text, strategy: :recursive, max_chars: 500)
```

Each chunk returns:
```elixir
%{
  content: String.t(),      # The chunk text
  index: non_neg_integer(), # Position in sequence
  metadata: map()           # Strategy-specific metadata
}
```

## Chunking Strategies

### 1. Character-Based (`:character`)

Fixed-size chunks with smart boundary detection.

```elixir
Chunking.chunk(text,
  strategy: :character,
  max_chars: 500,
  overlap: 50
)
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

### 2. Sentence-Based (`:sentence`)

Preserves complete sentences within chunks.

```elixir
Chunking.chunk(text,
  strategy: :sentence,
  max_chars: 500,
  min_chars: 100
)
```

**Options:**
- `max_chars` - Maximum characters per chunk (default: 500)
- `min_chars` - Minimum characters before starting new chunk (optional)

**Behavior:**
1. Splits on sentence boundaries using regex `(?<=[.!?])\s+`
2. Combines sentences up to max_chars
3. If min_chars specified, continues until reaching minimum
4. Falls back to character-based if sentence exceeds max_chars

**Best for:**
- Q&A systems
- Well-structured prose
- Semantic coherence

### 3. Paragraph-Based (`:paragraph`)

Preserves paragraph structure and topic boundaries.

```elixir
Chunking.chunk(text,
  strategy: :paragraph,
  max_chars: 500,
  min_chars: 100
)
```

**Options:**
- `max_chars` - Maximum characters per chunk (default: 500)
- `min_chars` - Minimum characters before starting new chunk (optional)

**Behavior:**
1. Splits on paragraph boundaries (double newlines)
2. Combines short paragraphs if under min_chars
3. Falls back to sentence-based if paragraph exceeds max_chars
4. Joins combined paragraphs with `\n\n`

**Best for:**
- Articles and blog posts
- Documentation
- Topic-organized content

### 4. Recursive (`:recursive`)

Hierarchical splitting from paragraph to sentence to character.

```elixir
Chunking.chunk(text,
  strategy: :recursive,
  max_chars: 500,
  min_chars: 100
)
```

**Options:**
- `max_chars` - Maximum characters per chunk (default: 500)
- `min_chars` - Minimum characters per chunk (optional)

**Behavior:**
1. First tries paragraph-based splitting
2. If single paragraph, applies recursive logic within
3. For each unit, checks if it fits
4. Falls back to sentence splitting, then character splitting
5. Tracks hierarchy level in metadata

**Metadata:**
```elixir
%{strategy: :recursive, hierarchy: :paragraph | :sentence | :character}
```

**Best for:**
- Mixed content structures
- Varying document formats
- Smart hierarchy preservation

### 5. Semantic (`:semantic`)

Groups sentences by semantic similarity using embeddings.

```elixir
embedding_fn = fn text ->
  {:ok, [embedding], _} = Router.execute(router, :embeddings, [text], [])
  embedding
end

Chunking.chunk(text,
  strategy: :semantic,
  max_chars: 500,
  embedding_fn: embedding_fn,
  threshold: 0.8
)
```

**Options:**
- `max_chars` - Maximum characters per chunk (default: 500)
- `embedding_fn` - **Required** function to generate embeddings
- `threshold` - Similarity threshold for grouping (default: 0.8)

**Behavior:**
1. Splits text into sentences
2. Generates embedding for each sentence
3. Groups sentences by cosine similarity
4. Continues adding while similarity >= threshold and under max_chars
5. Updates group embedding as average of sentence embeddings

**Best for:**
- Topic-focused chunks
- High-quality RAG systems
- When API cost is acceptable

## Strategy Comparison

| Strategy | Chunk Size | Structure | API Calls | Best For |
|----------|-----------|-----------|-----------|----------|
| Character | Consistent | May split thoughts | None | Predictable sizing |
| Sentence | Variable | Complete thoughts | None | Q&A systems |
| Paragraph | Variable | Topic boundaries | None | Structured docs |
| Recursive | Variable | Smart hierarchy | None | Mixed content |
| Semantic | Variable | Semantic groups | Yes | Topic coherence |

## Overlap Demonstration

```elixir
text = "First sentence. Second sentence. Third sentence. Fourth sentence."

# No overlap
Chunking.chunk(text, strategy: :character, max_chars: 40, overlap: 0)
# ["First sentence. Second", "sentence. Third sent", "ence. Fourth sentence."]

# With overlap
Chunking.chunk(text, strategy: :character, max_chars: 40, overlap: 20)
# ["First sentence. Second", "Second sentence. Third", "Third sentence. Fourth"]
```

Overlap helps:
- Preserve context between chunks
- Improve retrieval for information at chunk boundaries
- Reduce information loss during splitting

## Configuration Defaults

```elixir
@default_max_chars 500
@default_overlap 50
@default_semantic_threshold 0.8
```

## Complete Example

```elixir
alias Rag.Chunking
alias Rag.Router

# Load document
text = File.read!("document.md")

# Try different strategies
char_chunks = Chunking.chunk(text, strategy: :character, max_chars: 500, overlap: 50)
sent_chunks = Chunking.chunk(text, strategy: :sentence, max_chars: 500)
para_chunks = Chunking.chunk(text, strategy: :paragraph, max_chars: 500)
rec_chunks = Chunking.chunk(text, strategy: :recursive, max_chars: 500)

# Semantic chunking (requires embedding function)
{:ok, router} = Router.new(providers: [:gemini])

embedding_fn = fn text ->
  case Router.execute(router, :embeddings, [text], []) do
    {:ok, [embedding], _} -> embedding
    {:error, _} -> List.duplicate(0.0, 768)  # Fallback
  end
end

sem_chunks = Chunking.chunk(text,
  strategy: :semantic,
  max_chars: 500,
  embedding_fn: embedding_fn,
  threshold: 0.75
)

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

## Choosing a Strategy

**Use Character when:**
- You need consistent chunk sizes
- Working with unstructured text
- Embedding model has strict size limits

**Use Sentence when:**
- Building Q&A systems
- Working with well-structured prose
- Semantic coherence matters

**Use Paragraph when:**
- Documents have clear topic boundaries
- Working with articles/papers
- Want to preserve document structure

**Use Recursive when:**
- Documents have varying structures
- Don't know structure in advance
- Want smart fallback behavior

**Use Semantic when:**
- Topic coherence is critical
- API cost is acceptable
- Building high-quality RAG systems

## Next Steps

- [Vector Store](vector_store.md) - Store chunked documents
- [Embeddings](embeddings.md) - Generate embeddings for chunks
- [Retrievers](retrievers.md) - Search chunked documents
