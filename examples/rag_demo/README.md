# RAG Demo

A complete demo application showcasing all features of the RAG library.

## Prerequisites

1. **PostgreSQL** with pgvector extension installed
2. **Gemini API key** (set as `GEMINI_API_KEY` environment variable)

### Installing pgvector

```bash
# Ubuntu/Debian
sudo apt install postgresql-16-pgvector

# macOS with Homebrew
brew install pgvector

# Or build from source
git clone https://github.com/pgvector/pgvector.git
cd pgvector
make && sudo make install
```

## Setup

```bash
# Set your API key
export GEMINI_API_KEY="your-api-key-here"

# Install dependencies and setup database
mix setup
```

This will:
- Fetch dependencies
- Create the `rag_demo_dev` database
- Run migrations (creates `rag_chunks` table with pgvector)

## Run the Demo

```bash
mix demo
```

This runs a comprehensive demo showcasing:

1. **Basic LLM Interaction** - Generation and streaming
2. **Embeddings & Vector Store** - Store and search documents
3. **Semantic Search** - Find similar content by meaning
4. **Full-text Search** - Keyword-based search
5. **Hybrid Search (RRF)** - Combines semantic + fulltext
6. **Embedding Service** - GenServer for managed embeddings
7. **Agent Framework** - Tools, registry, sessions
8. **Routing Strategies** - Fallback, specialist routing
9. **Text Chunking** - Split documents with overlap
10. **Complete RAG Pipeline** - End-to-end example

## Interactive Usage

```bash
iex -S mix
```

```elixir
# Simple RAG query (uses the helper in RagDemo module)
{:ok, response, sources} = RagDemo.query("How does Elixir handle concurrency?")
IO.puts(response)

# Direct router usage
{:ok, router} = Rag.Router.new(providers: [:gemini])
{:ok, text, _router} = Rag.Router.execute(router, :text, "Hello!", [])
IO.puts(text)
```

## Database

Reset the database:

```bash
mix ecto.reset
```

Check stored chunks:

```elixir
iex> RagDemo.Repo.aggregate(Rag.VectorStore.Chunk, :count)
6
```

## Configuration

Edit `config/config.exs` to:
- Change database credentials
- Add additional LLM providers (Claude, OpenAI, Ollama)

```elixir
config :rag, :providers, %{
  gemini: %{...},
  claude: %{
    module: Rag.Ai.Claude,
    api_key: System.get_env("ANTHROPIC_API_KEY"),
    model: "claude-sonnet-4-20250514"
  }
}
```

## Project Structure

```
rag_demo/
├── config/
│   └── config.exs          # Database + provider config
├── lib/
│   └── rag_demo/
│       ├── application.ex  # Starts Repo
│       ├── repo.ex         # Ecto Repo
│       └── postgrex_types.ex
├── priv/
│   ├── demo.exs            # Main demo script
│   └── repo/migrations/    # Database migrations
└── mix.exs
```
