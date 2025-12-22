# Embeddings

The Embedding Service provides managed embedding generation with batching and statistics tracking.

## Overview

The `Rag.Embedding.Service` is a GenServer that handles:
- Single and batch text embedding
- Automatic batching for large requests
- Chunk embedding with database preparation
- Statistics tracking

## Starting the Service

```elixir
alias Rag.Embedding.Service

# Basic start
{:ok, pid} = Service.start_link([])

# With options
{:ok, pid} = Service.start_link(
  batch_size: 100,
  provider: :gemini,
  name: :embedding_service
)
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `:batch_size` | 100 | Max texts per batch |
| `:provider` | `Rag.Ai.Gemini` | Embedding provider module |
| `:name` | none | Process name for registration |

## Embedding Text

### Single Text

```elixir
{:ok, embedding} = Service.embed_text(pid, "Hello world")
# embedding: [0.1, 0.2, ...]  # Dimensions follow the configured Gemini embedding model
```

### Multiple Texts

```elixir
{:ok, embeddings} = Service.embed_texts(pid, ["Hello", "World", "Elixir"])
# embeddings: [[0.1, ...], [0.2, ...], [0.3, ...]]
```

Large requests are automatically batched according to `batch_size`.

## Embedding Chunks

### Embed and Return Chunks

```elixir
alias Rag.VectorStore.Chunk

chunks = [
  %Chunk{content: "First document"},
  %Chunk{content: "Second document"}
]

{:ok, embedded_chunks} = Service.embed_chunks(pid, chunks)
# Each chunk now has its embedding field populated
```

### Embed and Prepare for Insert

```elixir
{:ok, insert_ready} = Service.embed_and_prepare(pid, chunks)
# Returns list of maps ready for Ecto insert_all

Repo.insert_all(Chunk, insert_ready)
```

This combines:
1. `embed_chunks/2` - Generate embeddings
2. `VectorStore.prepare_for_insert/1` - Add timestamps and format

## Statistics

Track service usage:

```elixir
stats = Service.get_stats(pid)
# %{
#   texts_embedded: 150,
#   batches_processed: 2,
#   errors: 0
# }
```

## Internal State

```elixir
%Service{
  provider: module(),           # AI provider module
  provider_instance: struct(),  # Provider instance
  batch_size: pos_integer(),    # Max texts per batch
  stats: %{
    texts_embedded: integer(),
    batches_processed: integer(),
    errors: integer()
  }
}
```

## Using with Router

For simpler use cases, you can use the Router directly:

```elixir
alias Rag.Router

{:ok, router} = Router.new(providers: [:gemini])

# Single embedding
{:ok, [embedding], router} = Router.execute(router, :embeddings, ["text"], [])

# Multiple embeddings
{:ok, embeddings, router} = Router.execute(router, :embeddings,
  ["text1", "text2", "text3"],
  []
)
```

The Embedding Service is useful when you need:
- Long-running service with state
- Automatic batching management
- Statistics tracking
- Named process access

## Complete Workflow

```elixir
alias Rag.Embedding.Service
alias Rag.VectorStore
alias Rag.VectorStore.Chunk

# 1. Start service
{:ok, pid} = Service.start_link(batch_size: 50, name: :embeddings)

# 2. Prepare documents
documents = [
  %{content: "Document 1", source: "doc1.md"},
  %{content: "Document 2", source: "doc2.md"}
]
chunks = VectorStore.build_chunks(documents)

# 3. Embed and prepare for insert
{:ok, insert_ready} = Service.embed_and_prepare(pid, chunks)

# 4. Insert into database
{count, _} = Repo.insert_all(Chunk, insert_ready)

# 5. Check stats
stats = Service.get_stats(pid)
IO.puts("Embedded #{stats.texts_embedded} texts in #{stats.batches_processed} batches")
```

## Embedding Dimensions

| Provider | Model | Dimensions |
|----------|-------|------------|
| Gemini | `Gemini.Config.default_embedding_model()` | `Gemini.Config.default_embedding_dimensions(Gemini.Config.default_embedding_model())` |
| OpenAI | text-embedding-3-small | 1536 |
| OpenAI | text-embedding-3-large | 3072 |
| Cohere | embed-english-v3.0 | 1024 |

Ensure your database vector column matches the provider's embedding dimensions.

## Best Practices

1. **Batch requests** - Use `embed_texts/2` for multiple texts
2. **Monitor statistics** - Track embedded count and errors
3. **Use named processes** - Easier access in OTP applications
4. **Configure batch size** - Balance throughput vs. API limits
5. **Handle errors** - Service returns `{:error, reason}` on failure

## Next Steps

- [Vector Store](vector_store.md) - Store and search embeddings
- [Retrievers](retrievers.md) - Use embeddings for retrieval
