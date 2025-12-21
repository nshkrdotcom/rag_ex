<p align="center">
  <img src="assets/rag.svg" alt="RAG Logo" width="200">
</p>

<h1 align="center">Rag</h1>

<p align="center">
  <a href="https://hex.pm/packages/rag"><img src="https://img.shields.io/hexpm/v/rag.svg?style=flat-square" alt="Hex.pm Version"></a>
  <a href="https://hexdocs.pm/rag"><img src="https://img.shields.io/badge/hex-docs-blue.svg?style=flat-square" alt="Hex Docs"></a>
  <a href="https://github.com/bitcrowd/rag/blob/main/LICENSE"><img src="https://img.shields.io/hexpm/l/rag.svg?style=flat-square" alt="License"></a>
</p>

<!-- README START -->

<p align="center">
A library to build RAG (Retrieval Augmented Generation) systems in Elixir with multi-LLM support and agentic capabilities.
</p>

## Features

- **Multi-LLM Provider Support**: Gemini, Claude, Codex (OpenAI-compatible), and Ollama
- **Smart Routing**: Fallback, round-robin, and specialist routing strategies
- **Vector Store**: pgvector integration with semantic, full-text, and hybrid search
- **Embedding Service**: GenServer-based embedding management with batching
- **Agent Framework**: Tool-using agents with session memory
- **Built-in Tools**: Repository search, file reading, context retrieval, code analysis

## Introduction to RAG

RAG enhances the capabilities of language models by combining retrieval-based and generative approaches.
Traditional language models often struggle with the following problems:

- **Knowledge Cutoff**: Their knowledge is limited to a fixed point in time, making it difficult to provide up-to-date information.
- **Hallucinations**: They may generate information that sounds confident but is entirely made up, leading to inaccurate responses.
- **Contextual Relevance**: They struggle to provide responses that are contextually relevant to the user's query.

RAG addresses these issues by retrieving relevant information from an external knowledge source before generating a response.

## Installation

Add `rag` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rag, "~> 0.3.0"}
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
    model: "gemini-2.0-flash"
  }
}
```

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
    model: "gemini-2.0-flash"
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
# Chunk text with overlap for context preservation
long_text = File.read!("large_document.md")
chunks = VectorStore.chunk_text(long_text, max_chars: 500, overlap: 50)
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

## Database Migration

Create the chunks table for pgvector:

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

    # Indexes for search performance
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

## Pipeline Building

Build custom RAG pipelines:

```elixir
# Using the pipeline functions
import Rag

text
|> Rag.build_generation(model: "gemini-2.0-flash")
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

## Links

- [HexDocs](https://hexdocs.pm/rag)
- [Getting Started Notebook](/notebooks/getting_started.livemd)

---

Brought to you by [bitcrowd](https://bitcrowd.net/en).

![bitcrowd logo](https://github.com/bitcrowd/rag/blob/main/.github/images/bitcrowd_logo.png?raw=true "bitcrowd logo")

<!-- README END -->
