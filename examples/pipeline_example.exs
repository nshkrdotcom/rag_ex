# ==============================================================================
# RAG Pipeline Example - Complete Working Implementation
# ==============================================================================
#
# This example demonstrates a full RAG pipeline using:
#   - REAL PostgreSQL database with pgvector extension
#   - REAL LLM APIs (Gemini) for embeddings and generation
#   - Pipeline system with multiple steps
#   - Context passing between steps
#   - Parallel execution
#   - Error handling and retries
#
# Prerequisites:
#   1. PostgreSQL with pgvector extension installed
#   2. GEMINI_API_KEY environment variable set
#   3. Database setup: cd examples/rag_demo && mix setup
#
# Run with:
#   cd examples/rag_demo && mix run ../pipeline_example.exs
#
# ==============================================================================

# Check for required API key
unless System.get_env("GEMINI_API_KEY") do
  IO.puts("""

  ⚠️  ERROR: Missing GEMINI_API_KEY environment variable

  Please set your Gemini API key:

    export GEMINI_API_KEY="your-api-key-here"

  Get your API key at: https://aistudio.google.com/apikey

  """)

  exit(:missing_api_key)
end

# Import required modules
alias Rag.Pipeline
alias Rag.Pipeline.Context
alias Rag.Router
alias Rag.VectorStore
alias Rag.VectorStore.Chunk
alias Rag.Reranker
alias RagDemo.Repo

# ==============================================================================
# Pipeline Step Functions
# ==============================================================================
#
# Each step receives:
#   - input: The result from the previous step (or pipeline input for first step)
#   - context: Pipeline.Context struct containing all step results
#   - opts: Step-specific options (from args in step definition)
#
# Steps can return:
#   - {:ok, result} - Step succeeded, result stored in context
#   - {:ok, result, updated_context} - Step succeeded with context modifications
#   - {:error, reason} - Step failed (triggers error handling)
# ==============================================================================

defmodule RAGPipelineSteps do
  @moduledoc """
  Production-ready pipeline steps for a complete RAG system.
  """

  alias Rag.Pipeline.Context
  alias Rag.Router
  alias Rag.VectorStore
  alias Rag.VectorStore.Chunk
  alias RagDemo.Repo

  # ----------------------------------------------------------------------------
  # Step 1: Extract and validate the query
  # ----------------------------------------------------------------------------
  @doc """
  Extracts the user query from input and validates it.

  Input can be either:
    - A string (the query directly)
    - A map with :query key
  """
  def extract_query(input, context, _opts) do
    query =
      case input do
        query when is_binary(query) -> query
        %{query: query} when is_binary(query) -> query
        _ -> nil
      end

    if query && String.trim(query) != "" do
      # Update context with the query
      updated_context = %{context | query: query}
      {:ok, query, updated_context}
    else
      {:error, :invalid_query}
    end
  end

  # ----------------------------------------------------------------------------
  # Step 2: Generate embedding for the query
  # ----------------------------------------------------------------------------
  @doc """
  Generates an embedding vector for the query using the Router.

  This uses Gemini's auth-aware default embedding model via
  `Gemini.Config.default_embedding_model/0` with its default dimensionality.
  """
  def generate_embedding(query, context, opts) when is_binary(query) do
    IO.puts("  📊 Generating embedding for query...")

    # Get or create router
    router =
      case Keyword.get(opts, :router) do
        nil ->
          {:ok, r} = Router.new(providers: [:gemini])
          r

        r ->
          r
      end

    # Generate embedding
    case Router.execute(router, :embeddings, [query], []) do
      {:ok, [embedding], _router} ->
        # Store embedding in context
        updated_context = %{context | query_embedding: embedding}
        IO.puts("  ✓ Embedding generated (dimension: #{length(embedding)})")
        {:ok, embedding, updated_context}

      {:error, reason} ->
        IO.puts("  ✗ Embedding generation failed: #{inspect(reason)}")
        {:error, {:embedding_failed, reason}}
    end
  end

  # ----------------------------------------------------------------------------
  # Step 3: Chunk text documents (for ingestion pipeline)
  # ----------------------------------------------------------------------------
  @doc """
  Chunks text documents into smaller pieces for embedding.

  Useful when building the vector store from source documents.
  """
  def chunk_documents(documents, _context, opts) when is_list(documents) do
    max_chars = Keyword.get(opts, :max_chars, 500)
    overlap = Keyword.get(opts, :overlap, 50)

    IO.puts("  📄 Chunking #{length(documents)} documents...")

    chunks =
      Enum.flat_map(documents, fn doc ->
        text_chunks = VectorStore.chunk_text(doc.content, max_chars: max_chars, overlap: overlap)

        Enum.map(text_chunks, fn chunk_text ->
          %{
            content: chunk_text,
            source: doc.source,
            metadata: Map.get(doc, :metadata, %{})
          }
        end)
      end)

    IO.puts("  ✓ Created #{length(chunks)} chunks")
    {:ok, chunks}
  end

  # ----------------------------------------------------------------------------
  # Step 4: Retrieve documents from vector store
  # ----------------------------------------------------------------------------
  @doc """
  Performs semantic search to retrieve relevant documents.

  Uses the query embedding to find the most similar documents in the
  vector store using L2 distance.
  """
  def retrieve_documents(embedding, context, opts) do
    limit = Keyword.get(opts, :limit, 10)
    IO.puts("  🔍 Retrieving top #{limit} documents from vector store...")

    # Build semantic search query
    query = VectorStore.semantic_search_query(embedding, limit: limit)

    # Execute query against database
    results = Repo.all(query)

    if Enum.empty?(results) do
      IO.puts("  ⚠️  No documents found in vector store")
      {:ok, []}
    else
      IO.puts("  ✓ Retrieved #{length(results)} documents")

      # Convert to standard document format for reranking
      documents =
        Enum.map(results, fn r ->
          %{
            id: r.id,
            content: r.content,
            source: Map.get(r, :source, "unknown"),
            score: 1.0 / (1.0 + r.distance),
            # Convert distance to similarity
            metadata: Map.get(r, :metadata, %{})
          }
        end)

      updated_context = %{context | retrieval_results: documents}
      {:ok, documents, updated_context}
    end
  end

  # ----------------------------------------------------------------------------
  # Step 5: Rerank documents
  # ----------------------------------------------------------------------------
  @doc """
  Reranks retrieved documents to improve relevance.

  This step takes the initially retrieved documents and reorders them
  based on their relevance to the query. Uses a simple scoring method
  but could be replaced with an LLM-based reranker.
  """
  def rerank_documents(documents, context, opts) when is_list(documents) do
    top_k = Keyword.get(opts, :top_k, 5)

    if Enum.empty?(documents) do
      IO.puts("  ⚠️  No documents to rerank")
      {:ok, []}
    else
      IO.puts("  🎯 Reranking documents (keeping top #{top_k})...")

      # Simple reranking: sort by score and take top_k
      # In production, you might use Rag.Reranker.LLM here
      reranked =
        documents
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(top_k)

      IO.puts("  ✓ Reranked to #{length(reranked)} documents")

      updated_context = %{context | reranked_results: reranked}
      {:ok, reranked, updated_context}
    end
  end

  # ----------------------------------------------------------------------------
  # Step 6: Build context text from documents
  # ----------------------------------------------------------------------------
  @doc """
  Builds a formatted context string from the reranked documents.

  This creates the context that will be injected into the LLM prompt.
  """
  def build_context(documents, context, _opts) when is_list(documents) do
    if Enum.empty?(documents) do
      IO.puts("  📝 No documents available for context")
      {:ok, "No relevant context found."}
    else
      IO.puts("  📝 Building context from #{length(documents)} documents...")

      context_text =
        documents
        |> Enum.with_index(1)
        |> Enum.map_join("\n\n", fn {doc, idx} ->
          """
          [Document #{idx}] (source: #{doc.source}, score: #{Float.round(doc.score, 3)})
          #{doc.content}
          """
        end)

      IO.puts("  ✓ Context built (#{String.length(context_text)} characters)")

      updated_context = %{context | context_text: context_text}
      {:ok, context_text, updated_context}
    end
  end

  # ----------------------------------------------------------------------------
  # Step 7: Generate final response
  # ----------------------------------------------------------------------------
  @doc """
  Generates the final response using the LLM with the retrieved context.

  This is the final step that produces the RAG-augmented answer.
  """
  def generate_response(context_text, context, opts) when is_binary(context_text) do
    IO.puts("  🤖 Generating response with LLM...")

    query = context.query

    # Build augmented prompt
    prompt = """
    You are a helpful assistant. Answer the user's question based on the provided context.

    Context:
    #{context_text}

    User Question: #{query}

    Instructions:
    - Answer based on the context provided
    - If the context doesn't contain relevant information, say so
    - Be concise and accurate
    - Cite which documents you used (e.g., "According to Document 1...")

    Answer:
    """

    # Get or create router
    router =
      case Keyword.get(opts, :router) do
        nil ->
          {:ok, r} = Router.new(providers: [:gemini])
          r

        r ->
          r
      end

    # Generate response
    case Router.execute(router, :text, prompt, []) do
      {:ok, response, _router} ->
        IO.puts("  ✓ Response generated (#{String.length(response)} characters)")
        updated_context = %{context | response: response}
        {:ok, response, updated_context}

      {:error, reason} ->
        IO.puts("  ✗ Response generation failed: #{inspect(reason)}")
        {:error, {:generation_failed, reason}}
    end
  end

  # ----------------------------------------------------------------------------
  # Parallel Step Examples
  # ----------------------------------------------------------------------------

  @doc """
  Performs full-text search in parallel with semantic search.
  """
  def fulltext_search(query, _context, opts) do
    limit = Keyword.get(opts, :limit, 10)
    IO.puts("  [Parallel] 🔤 Full-text search...")

    results = Repo.all(VectorStore.fulltext_search_query(query, limit: limit))

    documents =
      Enum.map(results, fn r ->
        %{
          id: r.id,
          content: r.content,
          source: Map.get(r, :source, "unknown"),
          score: r.rank,
          metadata: Map.get(r, :metadata, %{})
        }
      end)

    IO.puts("  [Parallel] ✓ Found #{length(documents)} documents via full-text")
    {:ok, documents}
  end

  @doc """
  Combines results from parallel semantic and full-text search using RRF.
  """
  def combine_search_results(inputs, _context, _opts) when is_map(inputs) do
    semantic_results = Map.get(inputs, :semantic_search, [])
    fulltext_results = Map.get(inputs, :fulltext_search, [])

    IO.puts("  🔀 Combining search results with RRF...")
    IO.puts("     Semantic: #{length(semantic_results)} docs")
    IO.puts("     Fulltext: #{length(fulltext_results)} docs")

    # Convert to format expected by RRF
    semantic_for_rrf =
      Enum.map(semantic_results, fn doc ->
        %{id: doc.id, distance: 1.0 - doc.score, content: doc.content, source: doc.source}
      end)

    fulltext_for_rrf =
      Enum.map(fulltext_results, fn doc ->
        %{id: doc.id, rank: doc.score, content: doc.content, source: doc.source}
      end)

    combined = VectorStore.calculate_rrf_score(semantic_for_rrf, fulltext_for_rrf)

    # Convert back to standard format
    documents =
      Enum.map(combined, fn doc ->
        %{
          id: doc.id,
          content: doc.content,
          source: doc.source,
          score: doc.rrf_score,
          metadata: %{}
        }
      end)

    IO.puts("  ✓ Combined into #{length(documents)} unique documents")
    {:ok, documents}
  end
end

# ==============================================================================
# Helper Functions
# ==============================================================================

defmodule PipelineDemo do
  @moduledoc "Helper functions for the pipeline demo"

  def section(title) do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts(title)
    IO.puts(String.duplicate("=", 80) <> "\n")
  end

  def subsection(title) do
    IO.puts("\n#{title}")
    IO.puts(String.duplicate("-", 80))
  end

  def print_step_results(context) do
    IO.puts("\nStep Results Summary:")
    IO.puts(String.duplicate("-", 80))

    Enum.each(context.metadata.step_results, fn {step_name, result} ->
      result_preview =
        case result do
          s when is_binary(s) -> String.slice(s, 0, 50) <> "..."
          l when is_list(l) -> "List with #{length(l)} items"
          m when is_map(m) -> "Map with #{map_size(m)} keys"
          other -> inspect(other, limit: 50)
        end

      IO.puts("  #{step_name}: #{result_preview}")
    end)

    IO.puts("")
  end

  def ensure_sample_data(repo) do
    # Check if we have data
    count = repo.aggregate(Chunk, :count)

    if count == 0 do
      IO.puts("\n⚠️  No data in vector store. Adding sample documents...")

      # Sample documents about Elixir
      documents = [
        %{
          content:
            "Elixir is a dynamic, functional language designed for building scalable and maintainable applications. It leverages the Erlang VM, known for running low-latency, distributed, and fault-tolerant systems.",
          source: "elixir_intro.md",
          metadata: %{topic: "introduction"}
        },
        %{
          content:
            "The Pipeline operator |> is one of Elixir's most beloved features. It takes the result of an expression on its left and passes it as the first argument to the function call on its right.",
          source: "elixir_pipeline.md",
          metadata: %{topic: "syntax"}
        },
        %{
          content:
            "GenServer is a behaviour module for implementing the server of a client-server relation. It provides a standard set of callback functions for managing state in concurrent processes.",
          source: "genserver.md",
          metadata: %{topic: "otp"}
        },
        %{
          content:
            "Pattern matching is a powerful feature in Elixir that allows you to destructure data and match it against specific patterns. It's used in function definitions, case statements, and variable assignments.",
          source: "pattern_matching.md",
          metadata: %{topic: "syntax"}
        },
        %{
          content:
            "Supervisors are processes that monitor other processes and restart them when they crash. This is a core concept in building fault-tolerant systems with the 'let it crash' philosophy.",
          source: "supervisors.md",
          metadata: %{topic: "otp"}
        }
      ]

      # Create router for embeddings
      {:ok, router} = Router.new(providers: [:gemini])

      # Build chunks
      chunks = VectorStore.build_chunks(documents)

      # Generate embeddings
      contents = Enum.map(chunks, & &1.content)
      {:ok, embeddings, _router} = Router.execute(router, :embeddings, contents, [])

      # Add embeddings to chunks
      chunks_with_embeddings = VectorStore.add_embeddings(chunks, embeddings)

      # Insert into database
      prepared = Enum.map(chunks_with_embeddings, &VectorStore.prepare_for_insert/1)
      {inserted, _} = repo.insert_all(Chunk, prepared)

      IO.puts("✓ Inserted #{inserted} sample documents\n")
    else
      IO.puts("\n✓ Vector store contains #{count} documents\n")
    end
  end
end

# ==============================================================================
# EXAMPLE 1: Basic RAG Pipeline
# ==============================================================================

PipelineDemo.section("EXAMPLE 1: BASIC RAG PIPELINE")

IO.puts("This example demonstrates a complete RAG pipeline with sequential steps:\n")
IO.puts("  1. Extract and validate query")
IO.puts("  2. Generate query embedding")
IO.puts("  3. Retrieve documents from vector store")
IO.puts("  4. Rerank documents by relevance")
IO.puts("  5. Build context from top documents")
IO.puts("  6. Generate final response with LLM")

# Ensure we have sample data
PipelineDemo.ensure_sample_data(Repo)

# Create router to pass to steps (avoids recreating in each step)
{:ok, router} = Router.new(providers: [:gemini])

# Build the RAG pipeline
basic_pipeline =
  Pipeline.new(:rag_pipeline,
    description: "Complete RAG pipeline with semantic search and generation"
  )
  |> Pipeline.add_step(
    name: :extract_query,
    module: RAGPipelineSteps,
    function: :extract_query,
    args: [],
    on_error: :halt
  )
  |> Pipeline.add_step(
    name: :generate_embedding,
    module: RAGPipelineSteps,
    function: :generate_embedding,
    args: [router: router],
    inputs: [:extract_query],
    cache: true,
    # Cache embeddings for repeated queries
    timeout: 10_000,
    # 10 second timeout
    on_error: {:retry, 2}
    # Retry up to 2 times on failure
  )
  |> Pipeline.add_step(
    name: :retrieve_documents,
    module: RAGPipelineSteps,
    function: :retrieve_documents,
    args: [limit: 10],
    inputs: [:generate_embedding],
    timeout: 5_000,
    on_error: :halt
  )
  |> Pipeline.add_step(
    name: :rerank_documents,
    module: RAGPipelineSteps,
    function: :rerank_documents,
    args: [top_k: 3],
    inputs: [:retrieve_documents],
    on_error: :continue
    # Continue even if reranking fails
  )
  |> Pipeline.add_step(
    name: :build_context,
    module: RAGPipelineSteps,
    function: :build_context,
    args: [],
    inputs: [:rerank_documents],
    on_error: :halt
  )
  |> Pipeline.add_step(
    name: :generate_response,
    module: RAGPipelineSteps,
    function: :generate_response,
    args: [router: router],
    inputs: [:build_context],
    timeout: 30_000,
    # 30 second timeout for LLM
    on_error: {:retry, 1}
  )

PipelineDemo.subsection("Pipeline Configuration")
IO.puts("Pipeline: #{basic_pipeline.name}")
IO.puts("Description: #{basic_pipeline.description}")
IO.puts("Steps: #{length(basic_pipeline.steps)}")

Enum.with_index(basic_pipeline.steps, 1)
|> Enum.each(fn {step, idx} ->
  IO.puts(
    "  #{idx}. #{step.name} - #{step.module}.#{step.function}/3 (#{step.on_error}, cache: #{step.cache})"
  )
end)

# Execute the pipeline
PipelineDemo.subsection("Executing Pipeline")

user_query = "How does pattern matching work in Elixir?"
IO.puts("Query: \"#{user_query}\"\n")

start_time = System.monotonic_time(:millisecond)

case Pipeline.execute(basic_pipeline, user_query) do
  {:ok, result, context} ->
    elapsed = System.monotonic_time(:millisecond) - start_time

    IO.puts("\n✓ Pipeline completed successfully in #{elapsed}ms\n")

    PipelineDemo.subsection("Final Response")
    IO.puts(result)

    PipelineDemo.subsection("Context Information")
    IO.puts("Retrieved documents: #{length(context.retrieval_results || [])}")
    IO.puts("Reranked documents: #{length(context.reranked_results || [])}")
    IO.puts("Context length: #{String.length(context.context_text || "")} characters")
    IO.puts("Errors encountered: #{length(context.errors)}")

    if length(context.errors) > 0 do
      IO.puts("\nErrors:")

      Enum.each(context.errors, fn error ->
        IO.puts("  - #{inspect(error)}")
      end)
    end

  {:error, reason} ->
    elapsed = System.monotonic_time(:millisecond) - start_time
    IO.puts("\n✗ Pipeline failed after #{elapsed}ms")
    IO.puts("Reason: #{inspect(reason)}")
end

# ==============================================================================
# EXAMPLE 2: Parallel Execution with Hybrid Search
# ==============================================================================

PipelineDemo.section("EXAMPLE 2: PARALLEL EXECUTION - HYBRID SEARCH")

IO.puts("This example demonstrates parallel step execution:\n")
IO.puts("  1. Extract query")
IO.puts("  2. Generate embedding")
IO.puts("  3a. Semantic search (PARALLEL)")
IO.puts("  3b. Full-text search (PARALLEL)")
IO.puts("  4. Combine results with RRF")
IO.puts("  5. Build context")
IO.puts("  6. Generate response")

hybrid_pipeline =
  Pipeline.new(:hybrid_rag_pipeline, description: "RAG with parallel hybrid search")
  |> Pipeline.add_step(
    name: :extract_query,
    module: RAGPipelineSteps,
    function: :extract_query,
    args: []
  )
  |> Pipeline.add_step(
    name: :generate_embedding,
    module: RAGPipelineSteps,
    function: :generate_embedding,
    args: [router: router],
    inputs: [:extract_query],
    cache: true
  )
  # These two steps run in parallel
  |> Pipeline.add_step(
    name: :semantic_search,
    module: RAGPipelineSteps,
    function: :retrieve_documents,
    args: [limit: 10],
    inputs: [:generate_embedding],
    parallel: true
    # Mark as parallel
  )
  |> Pipeline.add_step(
    name: :fulltext_search,
    module: RAGPipelineSteps,
    function: :fulltext_search,
    args: [limit: 10],
    inputs: [:extract_query],
    parallel: true
    # Also parallel
  )
  # This step depends on both parallel steps
  |> Pipeline.add_step(
    name: :combine_results,
    module: RAGPipelineSteps,
    function: :combine_search_results,
    args: [],
    inputs: [:semantic_search, :fulltext_search]
    # Multiple inputs
  )
  |> Pipeline.add_step(
    name: :rerank_documents,
    module: RAGPipelineSteps,
    function: :rerank_documents,
    args: [top_k: 3],
    inputs: [:combine_results]
  )
  |> Pipeline.add_step(
    name: :build_context,
    module: RAGPipelineSteps,
    function: :build_context,
    args: [],
    inputs: [:rerank_documents]
  )
  |> Pipeline.add_step(
    name: :generate_response,
    module: RAGPipelineSteps,
    function: :generate_response,
    args: [router: router],
    inputs: [:build_context]
  )

PipelineDemo.subsection("Executing Hybrid Pipeline")

hybrid_query = "Tell me about processes and fault tolerance"
IO.puts("Query: \"#{hybrid_query}\"\n")

start_time = System.monotonic_time(:millisecond)

case Pipeline.execute(hybrid_pipeline, hybrid_query) do
  {:ok, result, context} ->
    elapsed = System.monotonic_time(:millisecond) - start_time

    IO.puts("\n✓ Hybrid pipeline completed in #{elapsed}ms\n")

    PipelineDemo.subsection("Final Response")
    IO.puts(result)

    PipelineDemo.print_step_results(context)

  {:error, reason} ->
    elapsed = System.monotonic_time(:millisecond) - start_time
    IO.puts("\n✗ Hybrid pipeline failed after #{elapsed}ms")
    IO.puts("Reason: #{inspect(reason)}")
end

# ==============================================================================
# EXAMPLE 3: Error Handling and Retries
# ==============================================================================

PipelineDemo.section("EXAMPLE 3: ERROR HANDLING & CACHING")

IO.puts("This example demonstrates:")
IO.puts("  - Caching of expensive operations (embeddings)")
IO.puts("  - Retry logic on transient failures")
IO.puts("  - Continue on non-critical errors\n")

# Run the same query twice to show caching
PipelineDemo.subsection("First Execution (No Cache)")

start_time = System.monotonic_time(:millisecond)
{:ok, _result1, _context1} = Pipeline.execute(basic_pipeline, "What is GenServer?")
elapsed1 = System.monotonic_time(:millisecond) - start_time

IO.puts("✓ First execution: #{elapsed1}ms")

PipelineDemo.subsection("Second Execution (With Cache)")

start_time = System.monotonic_time(:millisecond)
{:ok, _result2, _context2} = Pipeline.execute(basic_pipeline, "What is GenServer?")
elapsed2 = System.monotonic_time(:millisecond) - start_time

IO.puts("✓ Second execution: #{elapsed2}ms")
IO.puts("⚡ Speedup from caching: #{Float.round((elapsed1 - elapsed2) / elapsed1 * 100, 1)}%")

# ==============================================================================
# EXAMPLE 4: Document Ingestion Pipeline
# ==============================================================================

PipelineDemo.section("EXAMPLE 4: DOCUMENT INGESTION PIPELINE")

IO.puts("This example shows how to use pipelines for document ingestion:\n")
IO.puts("  1. Chunk documents into smaller pieces")
IO.puts("  2. Generate embeddings for all chunks")
IO.puts("  3. Store in vector database")

ingestion_pipeline =
  Pipeline.new(:ingestion_pipeline, description: "Document ingestion with chunking and embedding")
  |> Pipeline.add_step(
    name: :chunk_documents,
    module: RAGPipelineSteps,
    function: :chunk_documents,
    args: [max_chars: 500, overlap: 50]
  )

PipelineDemo.subsection("Ingesting New Document")

new_doc = [
  %{
    content:
      "Elixir macros are compile-time metaprogramming constructs that allow you to write code that writes code. They operate on the AST and can transform code before compilation. Use quote and unquote to work with code representations.",
    source: "macros.md",
    metadata: %{topic: "metaprogramming"}
  }
]

IO.puts("Document: macros.md")
IO.puts("Length: #{String.length(hd(new_doc).content)} characters\n")

case Pipeline.execute(ingestion_pipeline, new_doc) do
  {:ok, chunks, _context} ->
    IO.puts("✓ Document chunked into #{length(chunks)} pieces")

    # Generate embeddings
    contents = Enum.map(chunks, & &1.content)
    {:ok, embeddings, _} = Router.execute(router, :embeddings, contents, [])

    # Build chunk structs and add embeddings
    chunk_structs =
      chunks
      |> VectorStore.build_chunks()
      |> VectorStore.add_embeddings(embeddings)

    # Insert into database
    prepared = Enum.map(chunk_structs, &VectorStore.prepare_for_insert/1)
    {inserted, _} = Repo.insert_all(Chunk, prepared)

    IO.puts("✓ Inserted #{inserted} chunks into vector store")

  {:error, reason} ->
    IO.puts("✗ Ingestion failed: #{inspect(reason)}")
end

# ==============================================================================
# Summary
# ==============================================================================

PipelineDemo.section("SUMMARY")

total_chunks = Repo.aggregate(Chunk, :count)

IO.puts("""
Pipeline System Features Demonstrated:

✓ Sequential step execution with dependencies
✓ Parallel step execution for performance
✓ Context passing between steps
✓ Error handling strategies (halt, continue, retry)
✓ Caching of expensive operations
✓ Timeout configuration per step
✓ Integration with real PostgreSQL + pgvector
✓ Integration with real LLM APIs (Gemini)
✓ Multiple pipeline patterns (RAG, hybrid search, ingestion)

Vector Store Status:
  Total documents: #{total_chunks}

The pipeline system provides a flexible, composable way to build
complex RAG workflows with proper error handling and observability.

Key Benefits:
  • Type-safe step definitions
  • Automatic context management
  • Telemetry integration (see [:rag, :pipeline, :step, :start/:stop])
  • Reusable step functions
  • Clear separation of concerns
""")
