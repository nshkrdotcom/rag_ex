# Basic RAG Example
#
# This example demonstrates a complete RAG (Retrieval Augmented Generation) workflow:
# 1. Text chunking with Rag.Chunking
# 2. Embedding generation using Router with Gemini or OpenAI
# 3. Storing chunks in PostgreSQL with pgvector using Rag.VectorStore.Pgvector
# 4. Semantic search/retrieval with Rag.Retriever.Semantic
# 5. RAG query flow: retrieve context -> augment prompt -> generate answer
#
# QUICK START (First Time Setup):
# --------------------------------
# 1. Install PostgreSQL with pgvector:
#      brew install postgresql pgvector  # macOS
#      # or: apt-get install postgresql postgresql-14-pgvector  # Ubuntu
#
# 2. Create database and run migrations:
#      createdb rag_example_dev
#      mix ecto.migrate
#
# 3. Set your API key:
#      export GEMINI_API_KEY="your-key-here"
#      # or: export OPENAI_API_KEY="your-key-here"
#
# 4. Run the example:
#      mix run examples/basic_rag.exs
#
# USING YOUR OWN REPO:
# --------------------
# If you're integrating into your Phoenix/Ecto app:
#   - Replace "ExampleRepo" with your app's Repo (e.g., MyApp.Repo)
#   - Remove the ExampleRepo definition below
#   - Ensure your Repo is started (Phoenix does this automatically)
#
# Prerequisites:
#   - PostgreSQL with pgvector extension installed
#   - rag_chunks table created (run migrations)
#   - Set GEMINI_API_KEY or OPENAI_API_KEY environment variable
#   - Configure your Repo in this script (see SETUP section below)

# ============================================================================
# SETUP: Configure your application's Repo
# ============================================================================
#
# IMPORTANT: This library does not include its own Repo. You must provide one.
#
# Option 1: If you're running this in your Phoenix/Ecto app, use your app's Repo:
#   alias MyApp.Repo
#
# Option 2: For standalone testing, define a minimal Repo here:

# Database configuration
db_name = System.get_env("POSTGRES_DB") || "rag_example_dev"
db_user = System.get_env("POSTGRES_USER") || "postgres"
db_pass = System.get_env("POSTGRES_PASSWORD") || "postgres"
db_host = System.get_env("POSTGRES_HOST") || "localhost"
db_port = String.to_integer(System.get_env("POSTGRES_PORT") || "5432")

# PostgreSQL types configuration for pgvector
Postgrex.Types.define(
  BasicRagExample.PostgresTypes,
  [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  []
)

# Helper to create database if it doesn't exist
defmodule BasicRagExample.DbSetup do
  def ensure_database!(db_name, db_user, db_pass, db_host, db_port) do
    admin_opts = [
      hostname: db_host,
      port: db_port,
      username: db_user,
      password: db_pass,
      database: "postgres"
    ]

    case Postgrex.start_link(admin_opts) do
      {:ok, conn} ->
        case Postgrex.query(conn, "CREATE DATABASE #{db_name}", []) do
          {:ok, _} ->
            IO.puts("✓ Created database '#{db_name}'")

          {:error, %Postgrex.Error{postgres: %{code: :duplicate_database}}} ->
            IO.puts("✓ Database '#{db_name}' exists")

          {:error, _err} ->
            :ok
        end

        GenServer.stop(conn)
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :invalid_password}}} ->
        {:error, :invalid_credentials}

      {:error, %DBConnection.ConnectionError{reason: :econnrefused}} ->
        {:error, :connection_refused}

      {:error, err} ->
        {:error, err}
    end
  end
end

IO.puts("Setting up database...")

case BasicRagExample.DbSetup.ensure_database!(db_name, db_user, db_pass, db_host, db_port) do
  :ok ->
    :ok

  {:error, :connection_refused} ->
    IO.puts("""

    ✗ Cannot connect to PostgreSQL.

    PostgreSQL doesn't appear to be running at #{db_host}:#{db_port}.

    To fix this:
    ┌─────────────────────────────────────────────────────────────────┐
    │  # Start PostgreSQL                                             │
    │  sudo systemctl start postgresql    # Linux                     │
    │  brew services start postgresql     # macOS                     │
    │                                                                 │
    │  # Or use Docker:                                               │
    │  docker run -d --name postgres -p 5432:5432 \\                  │
    │    -e POSTGRES_PASSWORD=postgres pgvector/pgvector:pg16         │
    └─────────────────────────────────────────────────────────────────┘
    """)

    System.halt(1)

  {:error, :invalid_credentials} ->
    IO.puts("""

    ✗ Invalid PostgreSQL credentials.

    To fix this, set the correct credentials:
      export POSTGRES_USER="your_username"
      export POSTGRES_PASSWORD="your_password"
    """)

    System.halt(1)

  {:error, err} ->
    IO.puts("✗ Database setup failed: #{inspect(err)}")
    System.halt(1)
end

defmodule ExampleRepo do
  use Ecto.Repo,
    otp_app: :rag,
    adapter: Ecto.Adapters.Postgres
end

# Start the Repo with our configuration
repo_config = [
  database: db_name,
  username: db_user,
  password: db_pass,
  hostname: db_host,
  port: db_port,
  pool_size: 5,
  types: BasicRagExample.PostgresTypes,
  log: false
]

case ExampleRepo.start_link(repo_config) do
  {:ok, _pid} ->
    try do
      Ecto.Adapters.SQL.query!(ExampleRepo, "CREATE EXTENSION IF NOT EXISTS vector", [])
      IO.puts("✓ Connected to PostgreSQL (pgvector enabled)\n")
    rescue
      e in Postgrex.Error ->
        IO.puts("""

        ✗ Failed to enable pgvector extension.

        Error: #{Exception.message(e)}

        pgvector extension is required. To install:
        ┌─────────────────────────────────────────────────────────────────┐
        │  # Ubuntu/Debian:                                               │
        │  sudo apt install postgresql-16-pgvector                        │
        │                                                                 │
        │  # macOS with Homebrew:                                         │
        │  brew install pgvector                                          │
        │                                                                 │
        │  # Or use Docker with pgvector pre-installed:                   │
        │  docker run -d --name postgres -p 5432:5432 \\                  │
        │    -e POSTGRES_PASSWORD=postgres pgvector/pgvector:pg16         │
        └─────────────────────────────────────────────────────────────────┘
        """)

        System.halt(1)
    end

  {:error, {:already_started, _pid}} ->
    IO.puts("✓ Database connection already active\n")

  {:error, error} ->
    IO.puts("✗ Failed to connect to database: #{inspect(error)}")
    System.halt(1)
end

# Alias the Repo for easier use
alias ExampleRepo, as: Repo

# Create rag_chunks table if it doesn't exist
IO.puts("Creating rag_chunks table if needed...")

try do
  Ecto.Adapters.SQL.query!(Repo, """
  CREATE TABLE IF NOT EXISTS rag_chunks (
    id BIGSERIAL PRIMARY KEY,
    content TEXT NOT NULL,
    source TEXT,
    embedding vector(768),
    metadata JSONB DEFAULT '{}',
    inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
  )
  """)

  # Create index for vector similarity search (ignore if exists)
  Ecto.Adapters.SQL.query!(Repo, """
  CREATE INDEX IF NOT EXISTS rag_chunks_embedding_idx
  ON rag_chunks USING ivfflat (embedding vector_l2_ops) WITH (lists = 100)
  """)

  IO.puts("✓ Table rag_chunks ready\n")
rescue
  e ->
    IO.puts("  Note: Table setup issue (may already exist): #{Exception.message(e)}\n")
end

# ============================================================================
# Helper Functions
# ============================================================================

defmodule ExampleHelpers do
  def get_category(idx) do
    categories = ["Language", "Framework", "Concurrency", "Database", "UI"]
    Enum.at(categories, idx, "General")
  end
end

# ============================================================================
# Main Example Code
# ============================================================================

alias Rag.Router
alias Rag.Chunking
alias Rag.VectorStore
alias Rag.VectorStore.Pgvector
alias Rag.VectorStore.Chunk
alias Rag.Retriever.Semantic

IO.puts("=== Basic RAG Example ===\n")

# ----------------------------------------------------------------------------
# Step 1: Check API Keys and Initialize Router
# ----------------------------------------------------------------------------

IO.puts("Step 1: Checking API keys and initializing router")
IO.puts(String.duplicate("-", 60))

provider =
  cond do
    System.get_env("GEMINI_API_KEY") ->
      IO.puts("Using Gemini provider (GEMINI_API_KEY found)")
      :gemini

    System.get_env("OPENAI_API_KEY") ->
      IO.puts("Using OpenAI provider (OPENAI_API_KEY found)")
      :codex

    true ->
      IO.puts("""

      ================================
      NO API KEY FOUND
      ================================

      Please set one of the following environment variables:
        - GEMINI_API_KEY (for Gemini - recommended, supports embeddings)
        - OPENAI_API_KEY (for OpenAI)

      Example:
        export GEMINI_API_KEY="your-api-key-here"
        mix run examples/basic_rag.exs

      ================================
      """)

      System.halt(1)
  end

{:ok, router} = Router.new(providers: [provider])
IO.puts("Router initialized with #{provider} provider\n")

# ----------------------------------------------------------------------------
# Step 2: Prepare Sample Documents
# ----------------------------------------------------------------------------

IO.puts("Step 2: Preparing sample documents")
IO.puts(String.duplicate("-", 60))

# Sample documents about Elixir and Phoenix
documents = [
  """
  Elixir is a dynamic, functional programming language designed for building
  scalable and maintainable applications. It leverages the Erlang VM, known
  for running low-latency, distributed, and fault-tolerant systems. Elixir
  was created by José Valim in 2011.
  """,
  """
  Phoenix is a web development framework written in Elixir which implements
  the server-side Model View Controller (MVC) pattern. It was created by
  Chris McCord and is built on top of the Plug library and the Cowboy web
  server. Phoenix provides high developer productivity and high application
  performance.
  """,
  """
  GenServer is a generic server behavior in Elixir/Erlang that implements
  the server of a client-server relationship. It provides a standard set of
  interface functions and includes functionality for tracing and error reporting.
  GenServers are the foundation for building concurrent applications in Elixir.
  """,
  """
  Ecto is a database wrapper and language integrated query library for Elixir.
  It provides a standardized API for communicating with different databases,
  with support for PostgreSQL, MySQL, and others. Ecto includes changesets
  for filtering and casting parameters, as well as migrations for managing
  database schemas.
  """,
  """
  LiveView is a library for Phoenix that enables rich, real-time user experiences
  with server-rendered HTML. LiveView provides a compelling alternative to
  JavaScript-heavy client frameworks by allowing developers to build interactive
  applications entirely in Elixir. Events from the client are sent to the server
  over WebSockets, processed, and the UI is updated automatically.
  """
]

IO.puts("Loaded #{length(documents)} documents\n")

# ----------------------------------------------------------------------------
# Step 3: Chunk Text Using Different Strategies
# ----------------------------------------------------------------------------

IO.puts("Step 3: Chunking text")
IO.puts(String.duplicate("-", 60))

# Combine documents with metadata
docs_with_metadata =
  documents
  |> Enum.with_index()
  |> Enum.map(fn {text, idx} ->
    %{
      text: text,
      source: "doc_#{idx + 1}.md",
      category: ExampleHelpers.get_category(idx)
    }
  end)

# Chunk each document using character-based strategy
all_chunks =
  Enum.flat_map(docs_with_metadata, fn doc ->
    # Use Rag.Chunking for more sophisticated chunking
    chunks =
      Chunking.chunk(doc.text,
        strategy: :character,
        max_chars: 200,
        overlap: 30
      )

    # Add source and category metadata to each chunk
    Enum.map(chunks, fn chunk ->
      %{
        content: chunk.content,
        source: doc.source,
        metadata: Map.merge(chunk.metadata, %{category: doc.category})
      }
    end)
  end)

IO.puts("Created #{length(all_chunks)} chunks using character-based chunking")
IO.puts("Strategy: max_chars=200, overlap=30")

# Show a sample chunk
sample_chunk = Enum.at(all_chunks, 0)

IO.puts("\nSample chunk:")
IO.puts("  Source: #{sample_chunk.source}")
IO.puts("  Metadata: #{inspect(sample_chunk.metadata)}")
IO.puts("  Content: #{String.slice(sample_chunk.content, 0, 80)}...")
IO.puts("")

# ----------------------------------------------------------------------------
# Step 4: Generate Embeddings
# ----------------------------------------------------------------------------

IO.puts("Step 4: Generating embeddings")
IO.puts(String.duplicate("-", 60))

# Build chunk structs
chunk_structs = VectorStore.build_chunks(all_chunks)

# Extract content for embedding
contents = Enum.map(chunk_structs, & &1.content)

IO.puts("Generating embeddings for #{length(contents)} chunks...")

case Router.execute(router, :embeddings, contents, []) do
  {:ok, embeddings, router} ->
    IO.puts("Successfully generated #{length(embeddings)} embeddings")
    IO.puts("Embedding dimension: #{length(hd(embeddings))}")

    # Add embeddings to chunks
    chunks_with_embeddings = VectorStore.add_embeddings(chunk_structs, embeddings)
    IO.puts("Added embeddings to chunk structs\n")

    # ----------------------------------------------------------------------------
    # Step 5: Store Chunks in Vector Database
    # ----------------------------------------------------------------------------

    IO.puts("Step 5: Storing chunks in PostgreSQL with pgvector")
    IO.puts(String.duplicate("-", 60))

    # Clear existing data for clean demo
    IO.puts("Clearing existing chunks...")

    try do
      Repo.delete_all(Chunk)
    rescue
      e ->
        IO.puts("""
        ⚠ Could not clear existing chunks: #{Exception.message(e)}

        Please ensure:
          1. PostgreSQL is running
          2. Database 'rag_example_dev' exists (or set DATABASE_URL)
          3. The rag_chunks table has been created via migrations

        To set up:
          createdb rag_example_dev
          mix ecto.migrate

        Continuing anyway...
        """)
    end

    # Create a Pgvector store instance
    vector_store = Pgvector.new(repo: Repo)

    # Prepare chunks for insertion
    chunk_maps = Enum.map(chunks_with_embeddings, &Chunk.to_map/1)

    # Insert using the VectorStore.Store behavior
    case VectorStore.Store.insert(vector_store, chunk_maps) do
      {:ok, count} ->
        IO.puts("Successfully inserted #{count} chunks into database")
        IO.puts("Table: rag_chunks")
        IO.puts("Index: pgvector IVFFlat for semantic search\n")

        # ----------------------------------------------------------------------------
        # Step 6: Semantic Search / Retrieval
        # ----------------------------------------------------------------------------

        IO.puts("Step 6: Semantic search and retrieval")
        IO.puts(String.duplicate("-", 60))

        # Example query
        query = "How do I build real-time web applications?"
        IO.puts("Query: \"#{query}\"\n")

        # Generate query embedding
        IO.puts("Generating query embedding...")

        case Router.execute(router, :embeddings, [query], []) do
          {:ok, [query_embedding], _router} ->
            IO.puts("Query embedding generated (dimension: #{length(query_embedding)})")

            # Method 1: Using Retriever.Semantic (recommended)
            IO.puts("\nMethod 1: Using Rag.Retriever.Semantic")

            retriever = %Semantic{repo: Repo}

            case Semantic.retrieve(retriever, query_embedding, limit: 3) do
              {:ok, results} ->
                IO.puts("Found #{length(results)} relevant chunks:\n")

                Enum.each(Enum.with_index(results, 1), fn {result, idx} ->
                  # Metadata from DB has string keys, not atom keys
                  category =
                    result.metadata["category"] || Map.get(result.metadata, :category, "unknown")

                  IO.puts("  #{idx}. [Score: #{Float.round(result.score, 3)}] #{category}")
                  IO.puts("     Source: #{result.source}")
                  IO.puts("     #{String.slice(result.content, 0, 100)}...")
                  IO.puts("")
                end)

                # Method 2: Direct VectorStore query (alternative)
                IO.puts("\nMethod 2: Using VectorStore.semantic_search_query (alternative)")

                query_result =
                  query_embedding
                  |> VectorStore.semantic_search_query(limit: 3)
                  |> Repo.all()

                IO.puts("Retrieved #{length(query_result)} results using direct query\n")

                # Method 3: Using VectorStore.Store behavior
                IO.puts("Method 3: Using VectorStore.Store.search (alternative)")

                case VectorStore.Store.search(vector_store, query_embedding, limit: 3) do
                  {:ok, store_results} ->
                    IO.puts("Retrieved #{length(store_results)} results using Store behavior\n")

                  {:error, reason} ->
                    IO.puts("Store search failed: #{inspect(reason)}\n")
                end

                # ----------------------------------------------------------------------------
                # Step 7: RAG Query Flow - Generate Answer with Context
                # ----------------------------------------------------------------------------

                IO.puts("Step 7: RAG query flow - Generate answer with retrieved context")
                IO.puts(String.duplicate("-", 60))

                # Build context from retrieved chunks
                context =
                  results
                  |> Enum.map_join("\n\n", fn result ->
                    """
                    [Source: #{result.source}]
                    #{result.content}
                    """
                  end)

                IO.puts("Built context from #{length(results)} chunks\n")

                # Build RAG prompt
                rag_prompt = """
                You are a helpful assistant. Answer the following question using ONLY the context provided below.
                If the context doesn't contain enough information to answer the question, say so.

                CONTEXT:
                #{context}

                QUESTION:
                #{query}

                ANSWER:
                """

                IO.puts("Generating answer using RAG...")

                case Router.execute(router, :text, rag_prompt, []) do
                  {:ok, answer, _router} ->
                    IO.puts("\nGenerated Answer:")
                    IO.puts(String.duplicate("=", 60))
                    IO.puts(answer)
                    IO.puts(String.duplicate("=", 60))

                    IO.puts("\n\nSources used:")

                    results
                    |> Enum.map(& &1.source)
                    |> Enum.uniq()
                    |> Enum.each(&IO.puts("  - #{&1}"))

                  {:error, reason} ->
                    IO.puts("Error generating answer: #{inspect(reason)}")
                end

              {:error, reason} ->
                IO.puts("Retrieval failed: #{inspect(reason)}")
            end

          {:error, reason} ->
            IO.puts("Error generating query embedding: #{inspect(reason)}")
        end

      {:error, reason} ->
        IO.puts("Error inserting chunks: #{inspect(reason)}")
    end

  {:error, reason} ->
    IO.puts("Error generating embeddings: #{inspect(reason)}")
    IO.puts("\nPlease check:")
    IO.puts("  1. Your API key is valid")
    IO.puts("  2. You have internet connectivity")
    IO.puts("  3. The provider service is available")
end

# ----------------------------------------------------------------------------
# Additional Examples: Different Chunking Strategies
# ----------------------------------------------------------------------------

IO.puts("\n\n" <> String.duplicate("=", 60))
IO.puts("BONUS: Different Chunking Strategies")
IO.puts(String.duplicate("=", 60) <> "\n")

sample_text = """
Elixir is a dynamic language. It was created by José Valim.
The language runs on the Erlang VM. This provides excellent concurrency support.

Phoenix is a web framework. It is written in Elixir.
LiveView is a Phoenix library. It enables real-time features without JavaScript.
"""

IO.puts("Sample text for chunking demonstration:")
IO.puts(String.duplicate("-", 60))
IO.puts(sample_text)
IO.puts("")

# Sentence-based chunking
IO.puts("1. Sentence-based chunking:")

sentence_chunks =
  Chunking.chunk(sample_text,
    strategy: :sentence,
    max_chars: 150
  )

Enum.each(Enum.with_index(sentence_chunks, 1), fn {chunk, idx} ->
  IO.puts("  #{idx}. #{chunk.content}")
end)

IO.puts("")

# Paragraph-based chunking
IO.puts("2. Paragraph-based chunking:")

para_chunks =
  Chunking.chunk(sample_text,
    strategy: :paragraph,
    max_chars: 300
  )

Enum.each(Enum.with_index(para_chunks, 1), fn {chunk, idx} ->
  IO.puts(
    "  #{idx}. [#{String.length(chunk.content)} chars] #{String.slice(chunk.content, 0, 50)}..."
  )
end)

IO.puts("")

# Recursive chunking (hierarchical)
IO.puts("3. Recursive chunking (tries paragraph -> sentence -> character):")

recursive_chunks =
  Chunking.chunk(sample_text,
    strategy: :recursive,
    max_chars: 100
  )

Enum.each(Enum.with_index(recursive_chunks, 1), fn {chunk, idx} ->
  IO.puts("  #{idx}. [#{chunk.metadata.hierarchy}] #{String.slice(chunk.content, 0, 60)}...")
end)

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("=== Basic RAG Example Complete ===")
IO.puts(String.duplicate("=", 60))

IO.puts("""

Summary:
--------
✓ Chunked documents using multiple strategies
✓ Generated embeddings using #{provider}
✓ Stored chunks with embeddings in PostgreSQL/pgvector
✓ Performed semantic search to retrieve relevant context
✓ Generated RAG-enhanced answers using retrieved context

This demonstrates a complete RAG pipeline:
  Query -> Embed -> Search -> Retrieve -> Augment -> Generate
""")
