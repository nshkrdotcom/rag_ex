# Vector Store

The VectorStore provides document storage and retrieval using PostgreSQL with pgvector for semantic search.

## Overview

The VectorStore supports:
- **Semantic Search**: Vector similarity using L2 distance
- **Full-Text Search**: PostgreSQL tsvector keyword matching
- **Hybrid Search**: Reciprocal Rank Fusion (RRF) combining both
- **Text Chunking**: Intelligent text splitting with overlap

## Database Setup

### Migration

```elixir
defmodule MyApp.Repo.Migrations.CreateRagChunks do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    create table(:rag_chunks) do
      add :content, :text, null: false
      add :source, :string
      add :embedding, :vector, size: 768
      add :metadata, :map, default: %{}
      timestamps()
    end

    # Vector index for semantic search
    execute """
    CREATE INDEX rag_chunks_embedding_idx
    ON rag_chunks
    USING ivfflat (embedding vector_l2_ops)
    WITH (lists = 100)
    """

    # Full-text search index
    execute """
    CREATE INDEX rag_chunks_content_search_idx
    ON rag_chunks
    USING gin (to_tsvector('english', content))
    """
  end

  def down do
    drop table(:rag_chunks)
  end
end
```

## Core API

### Building Chunks

```elixir
alias Rag.VectorStore
alias Rag.VectorStore.Chunk

# Build single chunk
chunk = VectorStore.build_chunk(%{
  content: "Elixir is functional",
  source: "intro.md",
  metadata: %{category: "language"}
})

# Build multiple chunks
documents = [
  %{content: "First document", source: "doc1.md"},
  %{content: "Second document", source: "doc2.md"}
]
chunks = VectorStore.build_chunks(documents)
```

### Adding Embeddings

```elixir
alias Rag.Router

{:ok, router} = Router.new(providers: [:gemini])

# Generate embeddings
contents = Enum.map(chunks, & &1.content)
{:ok, embeddings, router} = Router.execute(router, :embeddings, contents, [])

# Attach to chunks
chunks_with_embeddings = VectorStore.add_embeddings(chunks, embeddings)
```

### Storing Chunks

```elixir
# Prepare for database insert
prepared = Enum.map(chunks_with_embeddings, &VectorStore.prepare_for_insert/1)

# Insert using your Repo
{count, _} = Repo.insert_all(Chunk, prepared)
```

### Using the Store Behaviour

```elixir
alias Rag.VectorStore.Pgvector

# Create store
store = Pgvector.new(repo: MyApp.Repo)

# Insert documents
{:ok, count} = Pgvector.insert(store, [
  %{content: "text", embedding: [0.1, 0.2, ...], source: "doc.md"}
])

# Search
{:ok, results} = Pgvector.search(store, query_embedding, limit: 5)
# results: [%{id: 1, content: "...", score: 0.99, source: "...", metadata: %{}}, ...]

# Delete
{:ok, count} = Pgvector.delete(store, [1, 2, 3])

# Get by IDs
{:ok, documents} = Pgvector.get(store, [1, 2])
```

## Search Methods

### Semantic Search

Vector similarity using L2 distance:

```elixir
# Build query
query = VectorStore.semantic_search_query(query_embedding, limit: 5)

# Execute with your Repo
results = Repo.all(query)
# Returns: [%{id, content, source, metadata, distance}, ...]
```

**Scoring:**
- Score = 1.0 - distance
- Range: 0.0 (dissimilar) to 1.0 (identical)

### Full-Text Search

PostgreSQL tsvector keyword matching:

```elixir
# Build query
query = VectorStore.fulltext_search_query("GenServer state", limit: 5)

# Execute
results = Repo.all(query)
# Returns: [%{id, content, source, metadata, rank}, ...]
```

**Features:**
- Multiple search terms combined with AND
- English text search configuration
- Results ordered by ts_rank

### Hybrid Search with RRF

Combines semantic and full-text using Reciprocal Rank Fusion:

```elixir
# Perform both searches
semantic = Repo.all(VectorStore.semantic_search_query(embedding, limit: 20))
fulltext = Repo.all(VectorStore.fulltext_search_query(text, limit: 20))

# Combine with RRF
hybrid_results = VectorStore.calculate_rrf_score(semantic, fulltext)
# Returns: [%{rrf_score: 0.035, id, content, ...}, ...]
```

**RRF Formula:**
```
RRF(d) = Σ 1 / (k + rank(d))  where k = 60
```

Documents appearing in both result sets get combined scores.

## Text Chunking

Split large documents into smaller chunks:

```elixir
# Basic chunking
long_text = File.read!("large_document.md")
chunks = VectorStore.chunk_text(long_text, max_chars: 500, overlap: 50)
```

**Options:**
- `max_chars` - Maximum chunk size (default: 500)
- `overlap` - Character overlap between chunks (default: 50)

**How it works:**
1. Tries to split at sentence boundaries (`.!?`)
2. Falls back to word boundaries
3. Falls back to hard split at max_chars
4. Creates overlap for context preservation

For more advanced chunking strategies, see the [Chunking Guide](chunking.md).

## Chunk Schema

The `Rag.VectorStore.Chunk` Ecto schema:

```elixir
schema "rag_chunks" do
  field :content, :string
  field :source, :string
  field :embedding, Pgvector.Ecto.Vector
  field :metadata, :map, default: %{}
  timestamps()
end
```

### API

```elixir
# Create chunk struct
chunk = Chunk.new(%{content: "text", source: "file.md"})

# Changeset for insert
changeset = Chunk.changeset(chunk, %{content: "updated"})

# Embedding-only changeset
changeset = Chunk.embedding_changeset(chunk, %{embedding: [0.1, 0.2, ...]})

# Convert to map
map = Chunk.to_map(chunk)
```

## Complete Workflow

```elixir
alias Rag.Router
alias Rag.VectorStore
alias Rag.VectorStore.{Chunk, Pgvector}

# 1. Initialize
{:ok, router} = Router.new(providers: [:gemini])
store = Pgvector.new(repo: MyApp.Repo)

# 2. Prepare documents
documents = [
  %{content: "Elixir is functional", source: "intro.md"},
  %{content: "GenServer handles state", source: "otp.md"}
]

# 3. Build chunks
chunks = VectorStore.build_chunks(documents)

# 4. Generate embeddings
contents = Enum.map(chunks, & &1.content)
{:ok, embeddings, router} = Router.execute(router, :embeddings, contents, [])

# 5. Add embeddings to chunks
chunks_with_embeddings = VectorStore.add_embeddings(chunks, embeddings)

# 6. Store in database
prepared = Enum.map(chunks_with_embeddings, &VectorStore.prepare_for_insert/1)
Repo.insert_all(Chunk, prepared)

# 7. Search
query = "How do I manage state?"
{:ok, [query_embedding], _} = Router.execute(router, :embeddings, [query], [])

# Semantic search
semantic_results = Repo.all(
  VectorStore.semantic_search_query(query_embedding, limit: 5)
)

# Full-text search
fulltext_results = Repo.all(
  VectorStore.fulltext_search_query(query, limit: 5)
)

# Hybrid search
hybrid_results = VectorStore.calculate_rrf_score(semantic_results, fulltext_results)
```

## Best Practices

1. **Use appropriate chunk sizes** - 500-1000 chars works well for most use cases
2. **Add overlap** - 50-100 chars helps maintain context across chunks
3. **Include source metadata** - Helps with result attribution
4. **Create proper indexes** - IVFFlat for vectors, GIN for full-text
5. **Use hybrid search** - Combines semantic understanding with keyword precision

## Next Steps

- [Embeddings](embeddings.md) - Learn about the embedding service
- [Retrievers](retrievers.md) - Higher-level retrieval abstractions
- [Chunking](chunking.md) - Advanced chunking strategies
