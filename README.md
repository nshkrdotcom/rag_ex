<p align="center">
  <img src="assets/rag.svg" alt="RAG Logo" width="200">
</p>

<h1 align="center">Rag</h1>

<p align="center">
  <a href="https://hex.pm/packages/rag_ex"><img src="https://img.shields.io/hexpm/v/rag_ex.svg?style=flat-square" alt="Hex.pm Version"></a>
  <a href="https://hexdocs.pm/rag_ex"><img src="https://img.shields.io/badge/hex-docs-blue.svg?style=flat-square" alt="Hex Docs"></a>
  <a href="https://github.com/bitcrowd/rag/blob/main/LICENSE"><img src="https://img.shields.io/hexpm/l/rag.svg?style=flat-square" alt="License"></a>
</p>

<!-- README START -->

> **Note:** This is a fork of [bitcrowd/rag](https://github.com/bitcrowd/rag). Credit to [bitcrowd](https://bitcrowd.net/en) for the original implementation.

<p align="center">
A library to build RAG (Retrieval Augmented Generation) systems in Elixir with multi-LLM support and agentic capabilities.
</p>

## Features

### Core LLM Capabilities
- **Multi-LLM Provider Support**: Gemini, Claude, Codex (OpenAI-compatible), and Ollama
- **Smart Routing**: Fallback, round-robin, and specialist routing strategies
- **Streaming Responses**: Real-time streaming for supported providers

### Modular RAG Architecture (v0.3.0)
- **Retriever Behaviours**: Pluggable retrieval with Semantic, FullText, Hybrid, and Graph implementations
- **VectorStore Behaviours**: Pluggable vector backends with pgvector implementation
- **Reranker Behaviours**: LLM-based and passthrough reranking
- **Pipeline System**: Composable RAG pipelines with parallel execution and caching

### GraphRAG Support (v0.3.0)
- **Entity Extraction**: LLM-based entity and relationship extraction
- **Knowledge Graph Storage**: PostgreSQL-based graph with Entity, Edge, Community schemas
- **Community Detection**: Label propagation algorithm for entity clustering
- **Graph Retrieval**: Local, global, and hybrid graph search modes

## Graph Storage Backends

rag_ex supports multiple graph storage backends:

### PostgreSQL (Pgvector)

The default backend using PostgreSQL with pgvector for both graph storage and vector similarity search.

```elixir
store = %Rag.GraphStore.Pgvector{repo: MyApp.Repo}
```

### RocksDB (TripleStore) - NEW in v0.4.0

High-performance graph backend using RocksDB with RDF triple storage. Ideal for large graphs requiring fast traversal.

```elixir
{:ok, store} = Rag.GraphStore.TripleStore.open(data_dir: "data/graph")
```

See [Hybrid RAG Architecture](docs/20251222/hybrid-rag-triplestore/README.md) for details.

### Advanced Chunking (v0.3.4)
- **Behavior-based chunking**: Pluggable `Rag.Chunker` strategies
- **Byte positions**: `start_byte`/`end_byte` on every chunk
- **Character-based**: Fixed-size chunks with smart boundaries
- **Sentence-based**: NLP-aware sentence splitting
- **Paragraph-based**: Preserve document structure
- **Recursive**: Hierarchical splitting for complex documents
- **Semantic**: Embedding-based similarity chunking
- **Format-aware**: TextChunker adapter for code and markup formats

### Agent Framework
- **Tool-using Agents**: Session memory and tool registration
- **Built-in Tools**: Repository search, file reading, context retrieval, code analysis

## Introduction to RAG

RAG enhances the capabilities of language models by combining retrieval-based and generative approaches.
Traditional language models often struggle with the following problems:

- **Knowledge Cutoff**: Their knowledge is limited to a fixed point in time, making it difficult to provide up-to-date information.
- **Hallucinations**: They may generate information that sounds confident but is entirely made up, leading to inaccurate responses.
- **Contextual Relevance**: They struggle to provide responses that are contextually relevant to the user's query.

RAG addresses these issues by retrieving relevant information from an external knowledge source before generating a response.

## Installation

Add `rag_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rag_ex, "~> 0.4.0"}
  ]
end
```

> **Note:** This is a library, not a standalone application. It does not include its own Ecto Repo. For vector store features (semantic search, embeddings storage), your consuming application must provide its own Repo and run the migrations. LLM features (Router, Agents, Embeddings generation) work without a database.

## Quick Start

### 1. Configure a Provider

```elixir
# config/config.exs
config :rag, :providers, %{
  gemini: %{
    module: Rag.Ai.Gemini,
    api_key: System.get_env("GEMINI_API_KEY"),
    model: :flash_lite_latest
  }
}
```

Model keys are resolved via `Gemini.Config`, so you can omit `:model` to use the
auth-aware default or pass other alias keys (e.g., `:flash_2_5`).

### 2. Use the Router for LLM Calls

```elixir
alias Rag.Router

# Create a router with your provider
{:ok, router} = Router.new(providers: [:gemini])

# Simple generation
{:ok, response, router} = Router.execute(router, :text, "What is Elixir?", [])

# With system prompt
opts = [system_prompt: "You are an Elixir expert."]
{:ok, response, router} = Router.execute(router, :text, "Explain GenServer", opts)
```

### 3. Generate Embeddings

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

## Multi-Provider Routing

Configure multiple providers and route between them:

```elixir
config :rag, :providers, %{
  gemini: %{
    module: Rag.Ai.Gemini,
    api_key: System.get_env("GEMINI_API_KEY"),
    model: :flash_lite_latest
  },
  claude: %{
    module: Rag.Ai.Claude,
    api_key: System.get_env("ANTHROPIC_API_KEY"),
    model: "claude-sonnet-4-20250514"
  },
  codex: %{
    module: Rag.Ai.Codex,
    api_key: System.get_env("OPENAI_API_KEY"),
    model: "gpt-4o"
  }
}
```

### Routing Strategies

```elixir
alias Rag.Router

# Fallback: Try providers in order until one succeeds
{:ok, router} = Router.new(providers: [:gemini, :claude, :codex], strategy: :fallback)
{:ok, response, router} = Router.execute(router, :text, "Hello", [])

# Round Robin: Distribute load across providers
{:ok, router} = Router.new(providers: [:gemini, :claude], strategy: :round_robin)
{:ok, response, router} = Router.execute(router, :text, "Hello", [])

# Specialist: Route based on task type (auto-selected with 3+ providers)
{:ok, router} = Router.new(providers: [:gemini, :claude, :codex], strategy: :specialist)
{:ok, response, router} = Router.execute(router, :text, "Write a function", [])
```

## Vector Store

Store and search document chunks with pgvector:

```elixir
alias Rag.Router
alias Rag.VectorStore
alias Rag.VectorStore.Chunk

{:ok, router} = Router.new(providers: [:gemini])

# Build chunks from documents
chunks = VectorStore.build_chunks([
  %{content: "Elixir is a functional language", source: "intro.md"},
  %{content: "GenServer handles state", source: "otp.md"}
])

# Add embeddings
contents = Enum.map(chunks, & &1.content)
{:ok, embeddings, router} = Router.execute(router, :embeddings, contents, [])
chunks_with_embeddings = VectorStore.add_embeddings(chunks, embeddings)

# Insert into database (using YOUR app's Repo)
Repo.insert_all(Chunk, Enum.map(chunks_with_embeddings, &VectorStore.prepare_for_insert/1))

# Semantic search
{:ok, [query_embedding], router} = Router.execute(router, :embeddings, ["functional programming"], [])
query = VectorStore.semantic_search_query(query_embedding, limit: 5)
results = Repo.all(query)

# Full-text search
query = VectorStore.fulltext_search_query("GenServer state", limit: 5)
results = Repo.all(query)

# Hybrid search with RRF
semantic_results = Repo.all(VectorStore.semantic_search_query(embedding, limit: 20))
fulltext_results = Repo.all(VectorStore.fulltext_search_query(text, limit: 20))
ranked = VectorStore.calculate_rrf_score(semantic_results, fulltext_results)
```

### Text Chunking

```elixir
alias Rag.Chunker
alias Rag.Chunker.Character

# Chunk text with overlap and byte positions
long_text = File.read!("large_document.md")
chunker = %Character{max_chars: 500, overlap: 50}
chunks = Chunker.chunk(chunker, long_text)

# Convert to VectorStore chunks with byte metadata
vector_chunks = VectorStore.from_chunker_chunks(chunks, "large_document.md")
```

## Advanced Chunking Strategies

Use the `Rag.Chunker` behavior for flexible text splitting:

```elixir
alias Rag.Chunker
alias Rag.Chunker.{Character, Sentence, Paragraph, Recursive, Semantic, FormatAware}

text = File.read!("document.md")

# Character-based chunking with smart boundaries
chunks = Chunker.chunk(%Character{max_chars: 500, overlap: 50}, text)

# Sentence-based chunking
chunks = Chunker.chunk(%Sentence{max_chars: 500, min_chars: 100}, text)

# Paragraph-based chunking
chunks = Chunker.chunk(%Paragraph{max_chars: 800}, text)

# Recursive chunking (paragraph -> sentence -> character)
chunks = Chunker.chunk(%Recursive{max_chars: 500, min_chars: 100}, text)

# Semantic chunking (requires embeddings)
embedding_fn = fn text ->
  {:ok, [embedding], _} = Router.execute(router, :embeddings, [text], [])
  embedding
end
chunks = Chunker.chunk(%Semantic{embedding_fn: embedding_fn, threshold: 0.8}, text)

# Format-aware chunking (TextChunker)
# Requires {:text_chunker, "~> 0.5.2"}
chunks = Chunker.chunk(%FormatAware{format: :markdown, chunk_size: 1000}, text)
```

## Retriever Behaviours

Pluggable retrieval strategies using the `Rag.Retriever` behaviour:

```elixir
alias Rag.Retriever
alias Rag.Retriever.{Semantic, FullText, Hybrid}

# Semantic retrieval (vector similarity)
retriever = %Semantic{repo: MyApp.Repo}
{:ok, results} = Retriever.retrieve(retriever, embedding: query_embedding, limit: 10)

# Full-text retrieval (PostgreSQL tsvector)
retriever = %FullText{repo: MyApp.Repo}
{:ok, results} = Retriever.retrieve(retriever, query: "elixir genserver", limit: 10)

# Hybrid retrieval (RRF fusion)
retriever = %Hybrid{
  semantic: %Semantic{repo: MyApp.Repo},
  fulltext: %FullText{repo: MyApp.Repo},
  semantic_weight: 0.7,
  fulltext_weight: 0.3
}
{:ok, results} = Retriever.retrieve(retriever,
  query: "elixir genserver",
  embedding: query_embedding,
  limit: 10
)
```

## Reranking

Improve retrieval quality with LLM-based reranking:

```elixir
alias Rag.Reranker
alias Rag.Reranker.LLM

# Create an LLM reranker
reranker = %LLM{router: router}

# Rerank retrieved documents
{:ok, reranked} = Reranker.rerank(reranker, query, documents, top_k: 5)

# Passthrough reranker (no-op, for testing)
reranker = %Rag.Reranker.Passthrough{}
{:ok, same_docs} = Reranker.rerank(reranker, query, documents, top_k: 5)
```

## Pipeline System

Build composable RAG pipelines with the `Rag.Pipeline` module:

```elixir
alias Rag.Pipeline
alias Rag.Pipeline.{Context, Executor}
alias Rag.Chunker
alias Rag.Chunker.Sentence

# Define pipeline steps
pipeline = %Pipeline{
  name: "rag_pipeline",
  steps: [
    %Pipeline.Step{
      name: :chunk,
      function: fn ctx ->
        chunks = Chunker.chunk(%Sentence{max_chars: 500, min_chars: 100}, ctx.input)
        {:ok, Context.put(ctx, :chunks, chunks)}
      end
    },
    %Pipeline.Step{
      name: :embed,
      function: fn ctx ->
        chunks = Context.get(ctx, :chunks)
        texts = Enum.map(chunks, & &1.content)
        {:ok, embeddings, _} = Router.execute(router, :embeddings, texts, [])
        {:ok, Context.put(ctx, :embeddings, embeddings)}
      end,
      depends_on: [:chunk]
    },
    %Pipeline.Step{
      name: :retrieve,
      function: fn ctx ->
        {:ok, results} = Retriever.retrieve(retriever, embedding: ctx.query_embedding, limit: 10)
        {:ok, Context.put(ctx, :results, results)}
      end
    },
    %Pipeline.Step{
      name: :generate,
      function: fn ctx ->
        results = Context.get(ctx, :results)
        prompt = build_prompt(ctx.query, results)
        {:ok, response, _} = Router.execute(router, :text, prompt, [])
        {:ok, Context.put(ctx, :response, response)}
      end,
      depends_on: [:retrieve]
    }
  ]
}

# Execute the pipeline
context = Context.new(input: document, query: "What is GenServer?")
{:ok, result_ctx} = Executor.run(pipeline, context)
response = Context.get(result_ctx, :response)
```

### Pipeline Features

- **Parallel Execution**: Independent steps run concurrently
- **ETS Caching**: Cache step results for reuse
- **Retry Logic**: Configurable retries with backoff
- **Telemetry**: Built-in observability hooks

## GraphRAG

Build knowledge graphs from documents for enhanced retrieval:

### Entity & Relationship Extraction

```elixir
alias Rag.GraphRAG.Extractor
alias Rag.GraphStore
alias Rag.GraphStore.Pgvector

{:ok, router} = Router.new(providers: [:gemini])

# Extract entities and relationships from text
text = "Alice works for Acme Corp in New York. Bob reports to Alice."
{:ok, result} = Extractor.extract(text, router: router)

# result contains:
# - entities: [%{name: "Alice", type: "person", ...}, ...]
# - relationships: [%{source: "Bob", target: "Alice", type: "reports_to", ...}, ...]
```

### Graph Storage

```elixir
# Initialize graph store
store = %Pgvector{repo: MyApp.Repo}

# Create entities
{:ok, alice} = GraphStore.create_node(store, %{
  type: :person,
  name: "Alice",
  properties: %{role: "manager"},
  embedding: alice_embedding
})

{:ok, acme} = GraphStore.create_node(store, %{
  type: :organization,
  name: "Acme Corp",
  properties: %{industry: "tech"}
})

# Create relationships
{:ok, edge} = GraphStore.create_edge(store, %{
  from_id: alice.id,
  to_id: acme.id,
  type: :works_for,
  weight: 1.0
})

# Graph traversal
{:ok, nodes} = GraphStore.traverse(store, alice.id, max_depth: 2, algorithm: :bfs)

# Vector search on entities
{:ok, similar} = GraphStore.vector_search(store, query_embedding, limit: 5)
```

### Community Detection

```elixir
alias Rag.GraphRAG.CommunityDetector

# Detect communities using label propagation
{:ok, communities} = CommunityDetector.detect(store, max_iterations: 10)

# Create community with summary
{:ok, community} = GraphStore.create_community(store, %{
  level: 0,
  entity_ids: [alice.id, bob.id, carol.id],
  summary: "Engineering team members"
})
```

### Graph-based Retrieval

```elixir
alias Rag.Retriever.Graph

# Local search (entity neighborhood)
retriever = %Graph{store: store, mode: :local}
{:ok, results} = Retriever.retrieve(retriever,
  embedding: query_embedding,
  limit: 10
)

# Global search (community summaries)
retriever = %Graph{store: store, mode: :global}
{:ok, results} = Retriever.retrieve(retriever, query: "engineering team", limit: 5)

# Hybrid (combines local + global)
retriever = %Graph{store: store, mode: :hybrid}
{:ok, results} = Retriever.retrieve(retriever,
  query: "engineering team",
  embedding: query_embedding,
  limit: 10
)
```

## Embedding Service

Use the GenServer for managed embedding operations:

```elixir
alias Rag.Embedding.Service

# Start the service
{:ok, pid} = Service.start_link(provider: :gemini)

# Embed single text
{:ok, embedding} = Service.embed_text(pid, "Hello world")

# Embed multiple texts (auto-batched)
{:ok, embeddings} = Service.embed_texts(pid, ["Text 1", "Text 2", "Text 3"])

# Embed chunks directly
{:ok, chunks_with_embeddings} = Service.embed_chunks(pid, chunks)

# Embed and prepare for database insert
{:ok, insert_ready} = Service.embed_and_prepare(pid, chunks)
Repo.insert_all(Chunk, insert_ready)
```

## Agent Framework

Build tool-using agents for complex tasks:

```elixir
alias Rag.Agent
alias Rag.Agent.Registry

# Register tools
Registry.start_link(name: MyRegistry)
Registry.register(MyRegistry, Rag.Agent.Tools.SearchRepos)
Registry.register(MyRegistry, Rag.Agent.Tools.ReadFile)

# Create an agent
agent = Agent.new(
  provider: :gemini,
  registry: MyRegistry,
  system_prompt: "You are a helpful code assistant."
)

# Process with tool use (agent loop)
{:ok, response, updated_agent} = Agent.process_with_tools(agent,
  "Find all GenServer modules in the codebase"
)
```

### Built-in Tools

| Tool | Description |
|------|-------------|
| `SearchRepos` | Semantic search over indexed repositories |
| `ReadFile` | Read file contents with optional line ranges |
| `GetRepoContext` | Get repository structure and metadata |
| `AnalyzeCode` | Parse and analyze code structure |

### Custom Tools

Implement the `Rag.Agent.Tool` behaviour:

```elixir
defmodule MyApp.Tools.CustomTool do
  @behaviour Rag.Agent.Tool

  @impl true
  def name, do: "custom_tool"

  @impl true
  def description, do: "Does something useful"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        input: %{type: "string", description: "The input"}
      },
      required: ["input"]
    }
  end

  @impl true
  def execute(args, context) do
    # Your implementation
    {:ok, result}
  end
end
```

## Session Memory

Agents maintain conversation context:

```elixir
alias Rag.Agent.Session

# Create a session
session = Session.new(system_prompt: "You are helpful.")

# Add messages
session = session
|> Session.add_user_message("Hello")
|> Session.add_assistant_message("Hi there!")

# Check context usage
{:ok, count} = Session.estimate_tokens(session)

# Get formatted messages for LLM
messages = Session.to_messages(session)
```

## Database Migrations

### Chunks Table (Vector Store)

```bash
mix ecto.gen.migration create_rag_chunks
```

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

### GraphRAG Tables

```bash
mix ecto.gen.migration create_graph_tables
```

```elixir
defmodule MyApp.Repo.Migrations.CreateGraphTables do
  use Ecto.Migration

  def up do
    # Entities (nodes)
    create table(:graph_entities) do
      add :type, :string, null: false
      add :name, :string, null: false
      add :properties, :map, default: %{}
      add :embedding, :vector, size: 768
      add :source_chunk_ids, {:array, :integer}, default: []
      timestamps()
    end

    create index(:graph_entities, [:type])
    create index(:graph_entities, [:name])

    execute """
    CREATE INDEX graph_entities_embedding_idx
    ON graph_entities
    USING ivfflat (embedding vector_l2_ops)
    WITH (lists = 100)
    """

    # Edges (relationships)
    create table(:graph_edges) do
      add :from_id, references(:graph_entities, on_delete: :delete_all), null: false
      add :to_id, references(:graph_entities, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :weight, :float, default: 1.0
      add :properties, :map, default: %{}
      timestamps()
    end

    create index(:graph_edges, [:from_id])
    create index(:graph_edges, [:to_id])
    create index(:graph_edges, [:type])

    # Communities (clusters)
    create table(:graph_communities) do
      add :level, :integer, default: 0
      add :summary, :text
      add :entity_ids, {:array, :integer}, default: []
      timestamps()
    end

    create index(:graph_communities, [:level])
  end

  def down do
    drop table(:graph_communities)
    drop table(:graph_edges)
    drop table(:graph_entities)
  end
end
```

## Pipeline Building

Build custom RAG pipelines:

```elixir
# Using the pipeline functions
import Rag

text
|> Rag.build_generation(model: Gemini.Config.default_model())
|> Rag.build_context(context_documents)
|> Rag.generate(&Gemini.generate/1)
```

## Provider Capabilities

Check what each provider supports:

```elixir
alias Rag.Router.Capabilities

Capabilities.supports?(:gemini, :embeddings)  # true
Capabilities.supports?(:gemini, :streaming)   # true
Capabilities.get_models(:claude)              # ["claude-sonnet-4-20250514", ...]
```

## Examples

The `examples/` directory contains runnable examples for all major features:

| Example | Description |
|---------|-------------|
| `basic_chat.exs` | Simple LLM interaction with Router |
| `routing_strategies.exs` | Multi-provider routing strategies |
| `multi_llm_router.exs` | Comprehensive Router demonstration |
| `agent.exs` | Agent framework with tool usage |
| `chunking_strategies.exs` | All chunking strategies |
| `vector_store.exs` | In-memory vector store |
| `basic_rag.exs` | Complete RAG workflow with DB |
| `hybrid_search.exs` | Semantic + full-text + RRF fusion |
| `graph_rag.exs` | GraphRAG with entity extraction |
| `pipeline_example.exs` | Pipeline system with parallel execution |

```bash
# Run a single example
mix run examples/basic_chat.exs

# Run all examples
./examples/run_all.sh

# Run without database examples
./examples/run_all.sh --skip-db
```

See [examples/README.md](examples/README.md) for detailed documentation.

## Guides

Comprehensive guides are available for all major features:

| Guide | Description |
|-------|-------------|
| [Getting Started](guides/getting_started.md) | Installation and first steps |
| [LLM Providers](guides/providers.md) | Gemini, Claude, Codex, and more |
| [Smart Router](guides/router.md) | Multi-provider routing strategies |
| [Vector Store](guides/vector_store.md) | Document storage with pgvector |
| [Embeddings](guides/embeddings.md) | Embedding generation service |
| [Chunking Strategies](guides/chunking.md) | Text splitting approaches |
| [Retrievers](guides/retrievers.md) | Semantic, fulltext, hybrid, graph |
| [Rerankers](guides/rerankers.md) | LLM-based result reranking |
| [Pipelines](guides/pipelines.md) | Composable RAG workflows |
| [GraphRAG](guides/graph_rag.md) | Knowledge graph-based RAG |
| [Agent Framework](guides/agent_framework.md) | Tool-using agents |

## Links

- [HexDocs](https://hexdocs.pm/rag_ex)
- [Getting Started Notebook](/notebooks/getting_started.livemd)
- [Guides](/guides/getting_started.md)
