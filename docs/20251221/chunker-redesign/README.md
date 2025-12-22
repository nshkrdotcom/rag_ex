# Chunker Redesign

## Overview

Replace the monolithic `Rag.Chunking` module with a behavior-based `Rag.Chunker` system that aligns with the library's existing patterns (`Retriever`, `Reranker`, `Provider`).

## Goals

1. **Consistency** - Match the behavior pattern used throughout rag_ex
2. **Extensibility** - Users can implement custom chunkers
3. **Composability** - Chunkers are first-class structs
4. **Position tracking** - All chunks include byte offsets
5. **External integration** - Adapter pattern for TextChunker and other libraries

## Quick Start

```elixir
# Character-based chunking
chunker = %Rag.Chunker.Character{max_chars: 500, overlap: 50}
chunks = Rag.Chunker.chunk(chunker, text)

# Recursive chunking (paragraph -> sentence -> character)
chunker = %Rag.Chunker.Recursive{max_chars: 500}
chunks = Rag.Chunker.chunk(chunker, text)

# Semantic chunking with embeddings
chunker = %Rag.Chunker.Semantic{
  embedding_fn: &MyApp.Embeddings.generate/1,
  threshold: 0.85
}
chunks = Rag.Chunker.chunk(chunker, text)

# Format-aware chunking (via TextChunker)
chunker = %Rag.Chunker.FormatAware{format: :elixir, chunk_size: 1500}
chunks = Rag.Chunker.chunk(chunker, elixir_source_code)
```

## Documents

- [Design](design.md) - Architecture and rationale
- [API Reference](api.md) - Complete API documentation
- [Examples](examples.md) - Usage patterns and recipes

## File Structure

```
lib/rag/
├── chunker.ex                    # Behavior definition + dispatch
└── chunker/
    ├── chunk.ex                  # Chunk struct definition
    ├── character.ex              # Fixed-size with smart boundaries
    ├── sentence.ex               # Sentence-boundary splitting
    ├── paragraph.ex              # Paragraph-boundary splitting
    ├── recursive.ex              # Hierarchical fallback
    ├── semantic.ex               # Embedding-based grouping
    └── format_aware.ex           # TextChunker adapter
```

## Changes from Rag.Chunking

| Before | After |
|--------|-------|
| `Rag.Chunking.chunk(text, strategy: :character)` | `Rag.Chunker.chunk(%Chunker.Character{}, text)` |
| Keyword-based strategy selection | Struct-based chunker instances |
| No byte position tracking | All chunks include `start_byte`/`end_byte` |
| Closed set of strategies | Open for extension via behavior |
| Inconsistent with library patterns | Matches Retriever/Reranker/Provider |
