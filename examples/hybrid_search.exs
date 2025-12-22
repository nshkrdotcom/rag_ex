# Hybrid Search Example
#
# This example demonstrates the three retrieval methods in the RAG library:
# 1. Semantic Search - Vector similarity using pgvector
# 2. Full-Text Search - PostgreSQL tsvector keyword matching
# 3. Hybrid Search - Combining both with Reciprocal Rank Fusion (RRF)
# 4. LLM Reranking - Further improving results with LLM-based scoring
#
# Prerequisites:
#   - PostgreSQL with pgvector extension installed
#   - Set GEMINI_API_KEY environment variable (or other provider API key)
#   - Database configured in config/config.exs (see examples/rag_demo for setup)
#
# Run from project root:
#   mix run examples/hybrid_search.exs
#
# For a complete database setup, see examples/rag_demo directory.

# First, check for required dependencies
unless Code.ensure_loaded?(Rag.Router) do
  IO.puts(
    "Error: RAG library not loaded. Run from project root with: mix run examples/hybrid_search.exs"
  )

  System.halt(1)
end

# ============================================================================
# CONFIGURATION & SETUP
# ============================================================================

# Database configuration
db_name = System.get_env("POSTGRES_DB") || "rag_hybrid_search_demo"
db_user = System.get_env("POSTGRES_USER") || "postgres"
db_pass = System.get_env("POSTGRES_PASSWORD") || "postgres"
db_host = System.get_env("POSTGRES_HOST") || "localhost"
db_port = String.to_integer(System.get_env("POSTGRES_PORT") || "5432")

# PostgreSQL types configuration for pgvector
Postgrex.Types.define(
  HybridSearchExample.PostgresTypes,
  [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  []
)

# Helper to create database if it doesn't exist
defmodule HybridSearchExample.DbSetup do
  def ensure_database!(db_name, db_user, db_pass, db_host, db_port) do
    # First, connect to 'postgres' database to create our target database
    admin_opts = [
      hostname: db_host,
      port: db_port,
      username: db_user,
      password: db_pass,
      database: "postgres"
    ]

    case Postgrex.start_link(admin_opts) do
      {:ok, conn} ->
        # Try to create the database (ignore error if exists)
        case Postgrex.query(conn, "CREATE DATABASE #{db_name}", []) do
          {:ok, _} ->
            IO.puts("✓ Created database '#{db_name}'")

          {:error, %Postgrex.Error{postgres: %{code: :duplicate_database}}} ->
            IO.puts("✓ Database '#{db_name}' exists")

          {:error, err} ->
            IO.puts("  Note: Could not create database: #{inspect(err)}")
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

  def ensure_pgvector!(conn) do
    case Postgrex.query(conn, "CREATE EXTENSION IF NOT EXISTS vector", []) do
      {:ok, _} -> :ok
      {:error, err} -> {:error, err}
    end
  end
end

# Try to set up the database
IO.puts("Setting up database...")

case HybridSearchExample.DbSetup.ensure_database!(db_name, db_user, db_pass, db_host, db_port) do
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

    Environment variables (optional):
      POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USER, POSTGRES_PASSWORD
    """)

    System.halt(1)

  {:error, :invalid_credentials} ->
    IO.puts("""

    ✗ Invalid PostgreSQL credentials.

    Cannot authenticate as '#{db_user}' at #{db_host}:#{db_port}.

    To fix this, set the correct credentials:
      export POSTGRES_USER="your_username"
      export POSTGRES_PASSWORD="your_password"
    """)

    System.halt(1)

  {:error, err} ->
    IO.puts("""

    ✗ Database setup failed: #{inspect(err)}

    Please check your PostgreSQL configuration.
    """)

    System.halt(1)
end

# Define a minimal Repo for this example
defmodule HybridSearchExample.Repo do
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
  types: HybridSearchExample.PostgresTypes,
  log: false
]

case HybridSearchExample.Repo.start_link(repo_config) do
  {:ok, _pid} ->
    # Enable pgvector extension
    try do
      Ecto.Adapters.SQL.query!(
        HybridSearchExample.Repo,
        "CREATE EXTENSION IF NOT EXISTS vector",
        []
      )

      IO.puts("✓ Connected to PostgreSQL (pgvector enabled)")
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
    IO.puts("✓ Using existing database connection")

  {:error, error} ->
    IO.puts("""

    ✗ Failed to connect to database '#{db_name}'.

    Error: #{inspect(error)}
    """)

    System.halt(1)
end

alias Rag.Router
alias Rag.VectorStore
alias Rag.VectorStore.Chunk
alias Rag.Retriever.Semantic
alias Rag.Retriever.FullText
alias Rag.Retriever.Hybrid
alias Rag.Reranker.LLM, as: LLMReranker
alias HybridSearchExample.Repo

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

defmodule HybridSearchExample.Helpers do
  @moduledoc """
  Helper functions for formatting output and checking prerequisites.
  """

  def section(title) do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts(title)
    IO.puts(String.duplicate("=", 70) <> "\n")
  end

  def subsection(title) do
    IO.puts("\n#{title}")
    IO.puts(String.duplicate("-", 70))
  end

  def print_results(results, label \\ "Results") do
    if Enum.empty?(results) do
      IO.puts("  No results found.")
    else
      IO.puts("\n#{label}:")

      for {result, idx} <- Enum.with_index(results, 1) do
        score_label = format_score(result.score)
        source = Map.get(result, :source, "unknown")
        content_preview = String.slice(result.content, 0, 80)

        IO.puts("  #{idx}. [#{score_label}] #{source}")
        IO.puts("     #{content_preview}...")
      end
    end
  end

  defp format_score(score) when is_float(score) do
    "score: #{Float.round(score, 4)}"
  end

  def check_api_keys do
    gemini_key = System.get_env("GEMINI_API_KEY")
    claude_key = System.get_env("ANTHROPIC_API_KEY")
    openai_key = System.get_env("OPENAI_API_KEY")

    cond do
      gemini_key && String.length(gemini_key) > 0 ->
        {:ok, :gemini}

      claude_key && String.length(claude_key) > 0 ->
        {:ok, :claude}

      openai_key && String.length(openai_key) > 0 ->
        {:ok, :openai}

      true ->
        {:error, :no_api_key}
    end
  end

  def ensure_table_exists!(repo, embedding_dimensions) when is_integer(embedding_dimensions) do
    current_dim = current_embedding_dimensions(repo)

    if current_dim != nil and current_dim != embedding_dimensions do
      IO.puts(
        "! Existing rag_chunks embedding dimension #{current_dim} does not match #{embedding_dimensions}; recreating table"
      )

      Ecto.Adapters.SQL.query!(repo, "DROP TABLE IF EXISTS rag_chunks CASCADE", [])
    end

    # Create the rag_chunks table if it doesn't exist
    query = """
    CREATE TABLE IF NOT EXISTS rag_chunks (
      id BIGSERIAL PRIMARY KEY,
      content TEXT NOT NULL,
      source TEXT,
      embedding vector(#{embedding_dimensions}),
      metadata JSONB DEFAULT '{}',
      inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW()
    )
    """

    Ecto.Adapters.SQL.query!(repo, query, [])

    # Create index for vector similarity search when dimensions allow
    if embedding_dimensions <= 2000 do
      Ecto.Adapters.SQL.query!(
        repo,
        "CREATE INDEX IF NOT EXISTS rag_chunks_embedding_idx ON rag_chunks USING ivfflat (embedding vector_l2_ops) WITH (lists = 100)",
        []
      )

      IO.puts(
        "✓ Database table ready (embedding dimensions: #{embedding_dimensions}, ivfflat index)"
      )
    else
      Ecto.Adapters.SQL.query!(repo, "DROP INDEX IF EXISTS rag_chunks_embedding_idx", [])

      IO.puts("✓ Database table ready (embedding dimensions: #{embedding_dimensions})")

      IO.puts(
        "! Skipping ivfflat index: pgvector ivfflat supports up to 2000 dimensions. " <>
          "Use output_dimensionality to reduce dims if you want an index."
      )
    end
  end

  defp current_embedding_dimensions(repo) do
    query = """
    SELECT format_type(a.atttypid, a.atttypmod)
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = 'rag_chunks'
      AND n.nspname = 'public'
      AND a.attname = 'embedding'
      AND a.attnum > 0
      AND NOT a.attisdropped
    """

    case Ecto.Adapters.SQL.query(repo, query, []) do
      {:ok, %{rows: [[type]]}} ->
        parse_vector_dimensions(type)

      _ ->
        nil
    end
  end

  defp parse_vector_dimensions(type) when is_binary(type) do
    case Regex.run(~r/vector\((\d+)\)/, type) do
      [_, dims] -> String.to_integer(dims)
      _ -> nil
    end
  end
end

alias HybridSearchExample.Helpers

# ============================================================================
# MAIN DEMO
# ============================================================================

Helpers.section("HYBRID SEARCH DEMONSTRATION")

# Check for API keys
case Helpers.check_api_keys() do
  {:ok, provider} ->
    IO.puts("✓ Using #{provider |> Atom.to_string() |> String.upcase()} provider")

  {:error, :no_api_key} ->
    IO.puts("""
    ✗ No API key found for any supported provider.

    Please set one of the following environment variables:
      - GEMINI_API_KEY (for Google Gemini)
      - ANTHROPIC_API_KEY (for Claude)
      - OPENAI_API_KEY (for OpenAI)

    Example:
      export GEMINI_API_KEY="your-api-key-here"
      mix run examples/hybrid_search.exs
    """)

    System.halt(1)
end

# Create router for embeddings and reranking
IO.puts("Initializing router...")

{:ok, router} =
  case Helpers.check_api_keys() do
    {:ok, :gemini} -> Router.new(providers: [:gemini])
    {:ok, :claude} -> Router.new(providers: [:claude])
    {:ok, :openai} -> Router.new(providers: [:openai])
  end

IO.puts("✓ Router initialized\n")

# ============================================================================
# STEP 1: PREPARE SAMPLE DOCUMENTS
# ============================================================================

Helpers.section("STEP 1: PREPARING SAMPLE DOCUMENTS")

# Sample documents about programming languages and frameworks
documents = [
  %{
    content:
      "Elixir is a functional, concurrent programming language that runs on the Erlang VM (BEAM). It's designed for building scalable and maintainable applications.",
    source: "elixir/intro.md",
    metadata: %{category: "language", topic: "elixir"}
  },
  %{
    content:
      "Phoenix is a web development framework written in Elixir. It provides high developer productivity and application performance with real-time features.",
    source: "phoenix/overview.md",
    metadata: %{category: "framework", topic: "web"}
  },
  %{
    content:
      "LiveView is a library for Phoenix that enables rich, real-time user experiences with server-rendered HTML. No JavaScript framework needed.",
    source: "phoenix/liveview.md",
    metadata: %{category: "library", topic: "web"}
  },
  %{
    content:
      "Ecto is a database wrapper and query generator for Elixir. It provides a standardized API for database operations and migrations.",
    source: "ecto/intro.md",
    metadata: %{category: "library", topic: "database"}
  },
  %{
    content:
      "GenServer is a generic server behavior in Elixir/OTP. It provides a standard interface for implementing servers with state management and message handling.",
    source: "elixir/genserver.md",
    metadata: %{category: "behavior", topic: "concurrency"}
  },
  %{
    content:
      "Supervisors monitor processes and restart them when they crash. This is fundamental to building fault-tolerant systems in Elixir.",
    source: "elixir/supervisors.md",
    metadata: %{category: "behavior", topic: "fault-tolerance"}
  },
  %{
    content:
      "Nerves is a framework for building embedded systems in Elixir. It allows developers to build IoT devices with the BEAM VM's reliability.",
    source: "nerves/intro.md",
    metadata: %{category: "framework", topic: "embedded"}
  },
  %{
    content:
      "Broadway is a library for building concurrent and multi-stage data ingestion and processing pipelines in Elixir. Great for ETL workflows.",
    source: "broadway/intro.md",
    metadata: %{category: "library", topic: "data-processing"}
  },
  %{
    content:
      "Pattern matching is a powerful feature in Elixir that allows you to destructure data and match against specific patterns in function clauses.",
    source: "elixir/pattern-matching.md",
    metadata: %{category: "feature", topic: "syntax"}
  },
  %{
    content:
      "The pipe operator |> in Elixir enables function composition by passing the result of one function as the first argument to the next.",
    source: "elixir/pipe-operator.md",
    metadata: %{category: "feature", topic: "syntax"}
  }
]

IO.puts("Sample documents: #{length(documents)}")

for doc <- documents do
  IO.puts("  • #{doc.source}")
end

# ============================================================================
# STEP 2: GENERATE EMBEDDINGS AND STORE IN DATABASE
# ============================================================================

Helpers.section("STEP 2: GENERATING EMBEDDINGS AND STORING IN DATABASE")

IO.puts("Building chunks...")
chunks = VectorStore.build_chunks(documents)
IO.puts("✓ Created #{length(chunks)} chunks")

IO.puts("\nGenerating embeddings (this may take a few seconds)...")
contents = Enum.map(chunks, & &1.content)

case Router.execute(router, :embeddings, contents, []) do
  {:ok, embeddings, _router} ->
    embedding_dim = length(hd(embeddings))
    IO.puts("✓ Generated #{length(embeddings)} embeddings (dimension: #{embedding_dim})")

    chunks_with_embeddings = VectorStore.add_embeddings(chunks, embeddings)

    Helpers.ensure_table_exists!(Repo, embedding_dim)

    IO.puts("\nStoring chunks in database...")
    # Clear existing data for this demo
    Repo.delete_all(Chunk)

    # Insert chunks
    prepared = Enum.map(chunks_with_embeddings, &VectorStore.prepare_for_insert/1)
    {count, _} = Repo.insert_all(Chunk, prepared)
    IO.puts("✓ Inserted #{count} chunks into database")

  {:error, reason} ->
    IO.puts("✗ Failed to generate embeddings: #{inspect(reason)}")
    System.halt(1)
end

# ============================================================================
# STEP 3: DEMONSTRATE SEMANTIC SEARCH
# ============================================================================

Helpers.section("STEP 3: SEMANTIC SEARCH (Vector Similarity)")

IO.puts("""
Semantic search uses vector embeddings to find documents that are conceptually
similar to the query, even if they don't share exact keywords.
""")

query_1 = "building web applications"
Helpers.subsection("Query: \"#{query_1}\"")

IO.puts("Generating query embedding...")

case Router.execute(router, :embeddings, [query_1], []) do
  {:ok, [query_embedding], _router} ->
    IO.puts("✓ Query embedding generated")

    # Create semantic retriever
    semantic_retriever = %Semantic{repo: Repo}

    # Retrieve results
    IO.puts("Searching with semantic retriever...")

    case Semantic.retrieve(semantic_retriever, query_embedding, limit: 5) do
      {:ok, results} ->
        Helpers.print_results(results, "Top 5 Semantic Search Results")
        IO.puts("\nNote: Semantic search found Phoenix and LiveView (web frameworks)")
        IO.puts("even though the query didn't mention these terms explicitly.")

      {:error, reason} ->
        IO.puts("Error during semantic search: #{inspect(reason)}")
    end

  {:error, reason} ->
    IO.puts("Error generating query embedding: #{inspect(reason)}")
end

# ============================================================================
# STEP 4: DEMONSTRATE FULL-TEXT SEARCH
# ============================================================================

Helpers.section("STEP 4: FULL-TEXT SEARCH (Keyword Matching)")

IO.puts("""
Full-text search uses PostgreSQL's tsvector to find documents containing
specific keywords. It's fast and works well for exact term matching.
""")

query_2 = "server state management"
Helpers.subsection("Query: \"#{query_2}\"")

# Create fulltext retriever
fulltext_retriever = %FullText{repo: Repo}

IO.puts("Searching with full-text retriever...")

case FullText.retrieve(fulltext_retriever, query_2, limit: 5) do
  {:ok, results} ->
    Helpers.print_results(results, "Top 5 Full-Text Search Results")
    IO.puts("\nNote: Full-text search prioritizes documents with exact keyword matches")
    IO.puts("(\"server\", \"state\", \"management\").")

  {:error, reason} ->
    IO.puts("Error during full-text search: #{inspect(reason)}")
end

# ============================================================================
# STEP 5: DEMONSTRATE HYBRID SEARCH WITH RRF
# ============================================================================

Helpers.section("STEP 5: HYBRID SEARCH (Semantic + Full-Text with RRF)")

IO.puts("""
Hybrid search combines semantic and full-text search using Reciprocal Rank
Fusion (RRF). This provides the best of both worlds: semantic understanding
and keyword precision.

RRF Formula: RRF(d) = Σ 1 / (k + rank(d)) where k = 60
""")

query_3 = "fault tolerant concurrent systems"
Helpers.subsection("Query: \"#{query_3}\"")

IO.puts("Generating query embedding for hybrid search...")

case Router.execute(router, :embeddings, [query_3], []) do
  {:ok, [query_embedding], _router} ->
    IO.puts("✓ Query embedding generated")

    # Create hybrid retriever
    hybrid_retriever = %Hybrid{repo: Repo}

    IO.puts("Searching with hybrid retriever (combining both methods)...")

    case Hybrid.retrieve(hybrid_retriever, {query_embedding, query_3}, limit: 5) do
      {:ok, results} ->
        Helpers.print_results(results, "Top 5 Hybrid Search Results (RRF)")

        IO.puts("\nNote: Hybrid search combines results from both methods.")
        IO.puts("Documents appearing in both result sets get higher RRF scores.")

      {:error, reason} ->
        IO.puts("Error during hybrid search: #{inspect(reason)}")
    end

  {:error, reason} ->
    IO.puts("Error generating query embedding: #{inspect(reason)}")
end

# ============================================================================
# STEP 6: COMPARE ALL THREE METHODS SIDE-BY-SIDE
# ============================================================================

Helpers.section("STEP 6: COMPARING ALL THREE RETRIEVAL METHODS")

comparison_query = "real-time web framework"
Helpers.subsection("Query: \"#{comparison_query}\"")

IO.puts("Running all three retrieval methods for comparison...\n")

case Router.execute(router, :embeddings, [comparison_query], []) do
  {:ok, [comp_query_embedding], _router} ->
    # Semantic
    semantic_retriever = %Semantic{repo: Repo}

    {:ok, semantic_results} =
      Semantic.retrieve(semantic_retriever, comp_query_embedding, limit: 3)

    # Full-text
    fulltext_retriever = %FullText{repo: Repo}
    {:ok, fulltext_results} = FullText.retrieve(fulltext_retriever, comparison_query, limit: 3)

    # Hybrid
    hybrid_retriever = %Hybrid{repo: Repo}

    {:ok, hybrid_results} =
      Hybrid.retrieve(hybrid_retriever, {comp_query_embedding, comparison_query}, limit: 3)

    # Display comparison
    IO.puts("=" <> String.duplicate("-", 69))
    IO.puts("| Method          | Rank | Source                    | Score      |")
    IO.puts("|" <> String.duplicate("-", 69) <> "|")

    for {result, idx} <- Enum.with_index(semantic_results, 1) do
      source = String.pad_trailing(Map.get(result, :source, "unknown"), 25)
      score = String.pad_leading("#{Float.round(result.score, 4)}", 10)
      IO.puts("| Semantic        | #{idx}    | #{source} | #{score} |")
    end

    IO.puts("|" <> String.duplicate("-", 69) <> "|")

    for {result, idx} <- Enum.with_index(fulltext_results, 1) do
      source = String.pad_trailing(Map.get(result, :source, "unknown"), 25)
      score = String.pad_leading("#{Float.round(result.score, 4)}", 10)
      IO.puts("| Full-Text       | #{idx}    | #{source} | #{score} |")
    end

    IO.puts("|" <> String.duplicate("-", 69) <> "|")

    for {result, idx} <- Enum.with_index(hybrid_results, 1) do
      source = String.pad_trailing(Map.get(result, :source, "unknown"), 25)
      score = String.pad_leading("#{Float.round(result.score, 4)}", 10)
      IO.puts("| Hybrid (RRF)    | #{idx}    | #{source} | #{score} |")
    end

    IO.puts("=" <> String.duplicate("-", 69))

    IO.puts("""

    Observations:
    • Semantic search captures the concept of "real-time" and "web" frameworks
    • Full-text search matches exact keywords like "real-time" and "web"
    • Hybrid search combines both signals for optimal ranking
    """)

  {:error, reason} ->
    IO.puts("Error generating query embedding: #{inspect(reason)}")
end

# ============================================================================
# STEP 7: LLM RERANKING
# ============================================================================

Helpers.section("STEP 7: LLM-BASED RERANKING")

IO.puts("""
After retrieving results with hybrid search, we can use an LLM to rerank
them based on actual relevance to the query. This provides the highest
quality results but is slower and more expensive.
""")

rerank_query = "How do I handle process crashes in production?"
Helpers.subsection("Query: \"#{rerank_query}\"")

IO.puts("Step 1: Retrieve initial results with hybrid search...")

case Router.execute(router, :embeddings, [rerank_query], []) do
  {:ok, [rerank_query_embedding], _router} ->
    hybrid_retriever = %Hybrid{repo: Repo}

    {:ok, initial_results} =
      Hybrid.retrieve(hybrid_retriever, {rerank_query_embedding, rerank_query}, limit: 5)

    Helpers.print_results(initial_results, "Initial Hybrid Search Results")

    IO.puts("\nStep 2: Rerank with LLM for relevance scoring...")
    IO.puts("(This may take a few seconds as the LLM evaluates each document)")

    # Create LLM reranker
    reranker = LLMReranker.new(router: router)

    case LLMReranker.rerank(reranker, rerank_query, initial_results, top_k: 3) do
      {:ok, reranked_results} ->
        Helpers.print_results(reranked_results, "Top 3 After LLM Reranking")

        IO.puts("""

        Note: The LLM reranker evaluated each document's actual relevance
        to the query and reordered them accordingly. The Supervisors document
        is now ranked higher because it directly addresses handling crashes.
        """)

      {:error, reason} ->
        IO.puts("Error during reranking: #{inspect(reason)}")
        IO.puts("(This may happen if the LLM response format is unexpected)")
    end

  {:error, reason} ->
    IO.puts("Error generating query embedding: #{inspect(reason)}")
end

# ============================================================================
# STEP 8: COMPLETE RAG PIPELINE
# ============================================================================

Helpers.section("STEP 8: COMPLETE RAG PIPELINE")

IO.puts("""
Putting it all together: A complete RAG pipeline that:
1. Takes a user question
2. Retrieves relevant context with hybrid search
3. Reranks with LLM for quality
4. Generates a contextual answer
""")

final_query = "What tools help with building data processing pipelines?"
Helpers.subsection("User Question: \"#{final_query}\"")

case Router.execute(router, :embeddings, [final_query], []) do
  {:ok, [final_query_embedding], router} ->
    IO.puts("\n1. Retrieving context with hybrid search...")
    hybrid_retriever = %Hybrid{repo: Repo}

    {:ok, context_results} =
      Hybrid.retrieve(hybrid_retriever, {final_query_embedding, final_query}, limit: 5)

    IO.puts("   ✓ Retrieved #{length(context_results)} documents")

    IO.puts("\n2. Reranking with LLM...")
    reranker = LLMReranker.new(router: router)

    {:ok, reranked} = LLMReranker.rerank(reranker, final_query, context_results, top_k: 3)
    IO.puts("   ✓ Reranked to top #{length(reranked)} most relevant")

    IO.puts("\n3. Building context from top results...")

    context =
      reranked
      |> Enum.map(fn r -> "- #{r.content} (Source: #{Map.get(r, :source, "unknown")})" end)
      |> Enum.join("\n")

    IO.puts("   ✓ Context prepared")

    IO.puts("\n4. Generating answer with LLM...")

    augmented_prompt = """
    Answer the user's question based on the following context.
    Be concise and reference specific information from the context.

    Context:
    #{context}

    Question: #{final_query}

    Answer:
    """

    case Router.execute(router, :text, augmented_prompt, []) do
      {:ok, answer, _router} ->
        IO.puts("\n" <> String.duplicate("-", 70))
        IO.puts("ANSWER:\n")
        IO.puts(answer)
        IO.puts(String.duplicate("-", 70))

        IO.puts("\nSources used:")

        for {result, idx} <- Enum.with_index(reranked, 1) do
          IO.puts("  #{idx}. #{Map.get(result, :source, "unknown")}")
        end

      {:error, reason} ->
        IO.puts("   ✗ Error generating answer: #{inspect(reason)}")
    end

  {:error, reason} ->
    IO.puts("Error generating query embedding: #{inspect(reason)}")
end

# ============================================================================
# CONCLUSION
# ============================================================================

Helpers.section("DEMONSTRATION COMPLETE")

IO.puts("""
This example demonstrated:

✓ Semantic Search      - Vector similarity with pgvector
✓ Full-Text Search     - PostgreSQL tsvector keyword matching
✓ Hybrid Search        - RRF fusion of both methods
✓ LLM Reranking        - Quality improvement with LLM scoring
✓ Complete RAG Pipeline - End-to-end question answering

Key Takeaways:
• Semantic search finds conceptually similar documents
• Full-text search excels at exact keyword matching
• Hybrid search (RRF) combines strengths of both
• LLM reranking provides highest quality at higher cost
• The best approach depends on your use case and requirements

Next Steps:
• Explore examples/rag_demo for a complete application setup
• Try different queries and observe how each method performs
• Experiment with different reranking strategies
• Build your own RAG application with this library!

For more information, see the documentation at:
  https://hexdocs.pm/rag
""")

# Clean up
IO.puts("\nCleaning up...")

if Process.whereis(HybridSearchExample.Repo) do
  # Optionally keep the data for experimentation
  choice = System.get_env("KEEP_DATA")

  if choice == "true" do
    IO.puts("✓ Database data preserved (KEEP_DATA=true)")
    IO.puts("  Database: #{Repo.config()[:database]}")
    IO.puts("  Records: #{Repo.aggregate(Chunk, :count)}")
  else
    Repo.delete_all(Chunk)
    IO.puts("✓ Database cleaned up")
    IO.puts("  (Set KEEP_DATA=true to preserve data)")
  end

  Supervisor.stop(HybridSearchExample.Repo)
end

IO.puts("\n✓ Demo completed successfully!")
