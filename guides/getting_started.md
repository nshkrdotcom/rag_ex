# Getting Started with Rag

This guide will help you get started with the Rag library for building RAG (Retrieval-Augmented Generation) systems in Elixir.

## Installation

Add `rag` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rag, "~> 0.3.0"}
  ]
end
```

### Optional Dependencies

For full functionality, you may want to add optional providers:

```elixir
def deps do
  [
    {:rag, "~> 0.3.0"},
    {:codex_sdk, "~> 0.4.2"},        # OpenAI/GPT support
    {:claude_agent_sdk, "~> 0.6.8"}  # Claude support
  ]
end
```

## Prerequisites

### Environment Variables

Configure at least one LLM provider:

```bash
# Gemini (recommended - supports embeddings)
export GEMINI_API_KEY="your-api-key"

# Claude (best for analysis and reasoning)
export ANTHROPIC_API_KEY="your-api-key"

# OpenAI/Codex (best for code generation)
export OPENAI_API_KEY="your-api-key"
```

### Database (Optional)

For vector store features, you need PostgreSQL with pgvector:

```bash
# Install pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;
```

## Quick Start

### 1. Basic LLM Interaction

```elixir
alias Rag.Router

# Create a router with your provider
{:ok, router} = Router.new(providers: [:gemini])

# Simple text generation
{:ok, response, router} = Router.execute(router, :text, "What is Elixir?", [])
IO.puts(response)

# With system prompt
opts = [system_prompt: "You are an Elixir expert."]
{:ok, response, router} = Router.execute(router, :text, "Explain GenServer", opts)
```

### 2. Generate Embeddings

```elixir
# Single text
{:ok, [embedding], router} = Router.execute(router, :embeddings, ["Hello world"], [])

# Multiple texts (batched automatically)
{:ok, embeddings, router} = Router.execute(router, :embeddings, [
  "First document",
  "Second document",
  "Third document"
], [])
```

### 3. Basic RAG Pipeline

```elixir
alias Rag.Router
alias Rag.VectorStore
alias Rag.VectorStore.Chunk
alias Rag.Retriever.Semantic

# 1. Initialize router
{:ok, router} = Router.new(providers: [:gemini])

# 2. Build chunks from documents
documents = [
  %{content: "Elixir is a functional programming language.", source: "intro.md"},
  %{content: "GenServer handles state in OTP applications.", source: "otp.md"}
]
chunks = VectorStore.build_chunks(documents)

# 3. Generate embeddings
contents = Enum.map(chunks, & &1.content)
{:ok, embeddings, router} = Router.execute(router, :embeddings, contents, [])
chunks_with_embeddings = VectorStore.add_embeddings(chunks, embeddings)

# 4. Store in database (using YOUR app's Repo)
prepared = Enum.map(chunks_with_embeddings, &VectorStore.prepare_for_insert/1)
Repo.insert_all(Chunk, prepared)

# 5. Query with semantic search
query = "How do I manage state?"
{:ok, [query_embedding], router} = Router.execute(router, :embeddings, [query], [])

retriever = %Semantic{repo: Repo}
{:ok, results} = Semantic.retrieve(retriever, query_embedding, limit: 3)

# 6. Build RAG prompt and generate answer
context = Enum.map(results, & &1.content) |> Enum.join("\n\n")
rag_prompt = """
Answer the question based on the following context:

#{context}

Question: #{query}
"""

{:ok, answer, _router} = Router.execute(router, :text, rag_prompt, [])
IO.puts(answer)
```

## Database Setup

### Chunks Table Migration

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

    execute """
    CREATE INDEX rag_chunks_embedding_idx
    ON rag_chunks
    USING ivfflat (embedding vector_l2_ops)
    WITH (lists = 100)
    """

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

## Architecture Overview

The library is organized into these main components:

| Component | Purpose |
|-----------|---------|
| **Router** | Multi-LLM orchestration with smart routing |
| **Providers** | Gemini, Claude, Codex implementations |
| **VectorStore** | Document storage with pgvector |
| **Retrievers** | Semantic, fulltext, hybrid, graph search |
| **Chunking** | Text splitting strategies |
| **Rerankers** | LLM-based result reranking |
| **Pipeline** | Composable RAG workflows |
| **GraphRAG** | Knowledge graph construction and retrieval |
| **Agent** | Tool-using agentic workflows |

## Next Steps

- [LLM Providers](providers.md) - Configure multi-provider support
- [Smart Router](router.md) - Learn about routing strategies
- [Vector Store](vector_store.md) - Store and search documents
- [Retrievers](retrievers.md) - Different retrieval strategies
- [Chunking](chunking.md) - Text splitting strategies
- [Pipeline](pipelines.md) - Build complex workflows
- [GraphRAG](graph_rag.md) - Knowledge graph-based RAG
- [Agent Framework](agent_framework.md) - Build tool-using agents

## Examples

The `examples/` directory contains runnable examples:

```bash
# Run a single example
mix run examples/basic_chat.exs

# Run all examples
./examples/run_all.sh

# Run without database examples
./examples/run_all.sh --skip-db
```
