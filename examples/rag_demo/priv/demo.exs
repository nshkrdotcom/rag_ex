# RAG Demo - Full Feature Showcase
#
# This demo shows all RAG library features with a real database.
#
# Setup:
#   1. Set GEMINI_API_KEY environment variable
#   2. Ensure PostgreSQL is running with pgvector extension
#   3. Run: mix setup
#   4. Run: mix demo

alias Rag.Router
alias Rag.VectorStore
alias Rag.VectorStore.Chunk
alias Rag.Embedding.Service, as: EmbeddingService
alias Rag.Agent.Agent
alias Rag.Agent.Registry
alias Rag.Agent.Session

alias RagDemo.Repo

defmodule Demo do
  @moduledoc "Demo helper functions"

  def section(title) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts(title)
    IO.puts(String.duplicate("=", 60) <> "\n")
  end

  def subsection(title) do
    IO.puts("\n#{title}")
    IO.puts(String.duplicate("-", 40))
  end
end

# Create router for use throughout demo
{:ok, router} = Router.new(providers: [:gemini])

# =============================================================================
# 1. BASIC LLM INTERACTION
# =============================================================================

Demo.section("1. BASIC LLM INTERACTION")

Demo.subsection("Simple generation")

case Router.execute(router, :text, "What is Elixir? Answer in one sentence.", []) do
  {:ok, response, _} -> IO.puts(response)
  {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
end

Demo.subsection("With system prompt")
opts = [system_prompt: "You are a concise Elixir tutor. Max 30 words."]

case Router.execute(router, :text, "Explain pattern matching", opts) do
  {:ok, response, _} -> IO.puts(response)
  {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
end

# =============================================================================
# 2. EMBEDDINGS & VECTOR STORE
# =============================================================================

Demo.section("2. EMBEDDINGS & VECTOR STORE")

# Sample documents about Elixir
documents = [
  %{
    content: "Elixir is a functional, concurrent programming language that runs on the BEAM VM.",
    source: "elixir/intro.md",
    metadata: %{topic: "language"}
  },
  %{
    content: "GenServer is a behaviour for implementing client-server relations with state.",
    source: "elixir/genserver.md",
    metadata: %{topic: "otp"}
  },
  %{
    content: "Phoenix is a web framework for Elixir implementing server-side MVC pattern.",
    source: "phoenix/intro.md",
    metadata: %{topic: "web"}
  },
  %{
    content: "LiveView enables real-time user experiences with server-rendered HTML.",
    source: "phoenix/liveview.md",
    metadata: %{topic: "web"}
  },
  %{
    content: "Ecto is a toolkit for data mapping and database queries in Elixir.",
    source: "ecto/intro.md",
    metadata: %{topic: "database"}
  },
  %{
    content: "Supervisors monitor processes and restart them on failure for fault tolerance.",
    source: "elixir/supervisors.md",
    metadata: %{topic: "otp"}
  }
]

Demo.subsection("Building chunks")
chunks = VectorStore.build_chunks(documents)
IO.puts("Created #{length(chunks)} chunks")

Demo.subsection("Generating embeddings")
contents = Enum.map(chunks, & &1.content)
{:ok, embeddings, router} = Router.execute(router, :embeddings, contents, [])
IO.puts("Generated #{length(embeddings)} embeddings (dim: #{length(hd(embeddings))})")

chunks_with_embeddings = VectorStore.add_embeddings(chunks, embeddings)

Demo.subsection("Storing in database")
# Clear existing data
Repo.delete_all(Chunk)

# Prepare and insert
prepared = Enum.map(chunks_with_embeddings, &VectorStore.prepare_for_insert/1)
{count, _} = Repo.insert_all(Chunk, prepared)
IO.puts("Inserted #{count} chunks into database")

Demo.subsection("Semantic search")
query_text = "How do I build web applications?"
IO.puts("Query: \"#{query_text}\"")

{:ok, [query_embedding], router} = Router.execute(router, :embeddings, [query_text], [])
results = Repo.all(VectorStore.semantic_search_query(query_embedding, limit: 3))

IO.puts("\nTop 3 results by semantic similarity:")

for {result, idx} <- Enum.with_index(results, 1) do
  IO.puts("  #{idx}. [dist: #{Float.round(result.distance, 4)}] #{result.source}")
  IO.puts("     #{String.slice(result.content, 0, 60)}...")
end

Demo.subsection("Full-text search")
search_text = "fault tolerance restart"
IO.puts("Query: \"#{search_text}\"")

results = Repo.all(VectorStore.fulltext_search_query(search_text, limit: 3))

IO.puts("\nTop results by keyword match:")

for {result, idx} <- Enum.with_index(results, 1) do
  IO.puts("  #{idx}. [rank: #{Float.round(result.rank, 4)}] #{result.source}")
  IO.puts("     #{String.slice(result.content, 0, 60)}...")
end

Demo.subsection("Hybrid search with RRF")
hybrid_query = "web server framework"
IO.puts("Query: \"#{hybrid_query}\"")

{:ok, [hybrid_embedding], router} = Router.execute(router, :embeddings, [hybrid_query], [])
semantic_results = Repo.all(VectorStore.semantic_search_query(hybrid_embedding, limit: 10))
fulltext_results = Repo.all(VectorStore.fulltext_search_query(hybrid_query, limit: 10))

ranked = VectorStore.calculate_rrf_score(semantic_results, fulltext_results)
top_3 = Enum.take(ranked, 3)

IO.puts("\nTop 3 by RRF (combines semantic + fulltext):")

for {result, idx} <- Enum.with_index(top_3, 1) do
  IO.puts("  #{idx}. [rrf: #{Float.round(result.rrf_score, 4)}] #{result.source}")
  IO.puts("     #{String.slice(result.content, 0, 60)}...")
end

# =============================================================================
# 3. EMBEDDING SERVICE (GenServer)
# =============================================================================

Demo.section("3. EMBEDDING SERVICE (GenServer)")

{:ok, embed_service} = EmbeddingService.start_link(provider: :gemini)

Demo.subsection("Single text embedding")
{:ok, embedding} = EmbeddingService.embed_text(embed_service, "Hello world")
IO.puts("Embedded single text, dimension: #{length(embedding)}")

Demo.subsection("Batch embedding")
texts = ["First text", "Second text", "Third text"]
{:ok, _embeddings} = EmbeddingService.embed_texts(embed_service, texts)
IO.puts("Embedded #{length(texts)} texts in batch")

Demo.subsection("Embed chunks directly")

new_chunks =
  VectorStore.build_chunks([
    %{content: "New document one", source: "new1.md"},
    %{content: "New document two", source: "new2.md"}
  ])

{:ok, embedded_chunks} = EmbeddingService.embed_chunks(embed_service, new_chunks)
IO.puts("Embedded #{length(embedded_chunks)} chunks with embeddings attached")

GenServer.stop(embed_service)

# =============================================================================
# 4. AGENT FRAMEWORK
# =============================================================================

Demo.section("4. AGENT FRAMEWORK")

Demo.subsection("Tool registry")

registry =
  Registry.new(
    tools: [
      Rag.Agent.Tools.SearchRepos,
      Rag.Agent.Tools.ReadFile,
      Rag.Agent.Tools.AnalyzeCode
    ]
  )

tools = Registry.list(registry)
IO.puts("Registered #{length(tools)} tools:")

for tool <- tools do
  IO.puts("  - #{tool.name()}: #{String.slice(tool.description(), 0, 50)}...")
end

Demo.subsection("Direct tool execution")

code = """
defmodule Calculator do
  def add(a, b), do: a + b
  def multiply(a, b), do: a * b
  defp validate(n), do: n > 0
end
"""

{:ok, analysis} = Registry.execute(registry, "analyze_code", %{"code" => code}, %{})
IO.puts("Analyzed code:")
IO.puts("  Modules: #{inspect(analysis.modules)}")
IO.puts("  Functions: #{analysis.function_count}")

for func <- analysis.functions do
  vis = if func.type == :def, do: "public", else: "private"
  IO.puts("    - #{func.name}/#{func.arity} (#{vis})")
end

Demo.subsection("Session memory")

session =
  Session.new(system_prompt: "You are a helpful assistant.")
  |> Session.add_message(:user, "What is Elixir?")
  |> Session.add_message(:assistant, "Elixir is a functional programming language.")
  |> Session.add_message(:user, "What about Phoenix?")

IO.puts("Session has #{Session.message_count(session)} messages")
IO.puts("Token estimate: ~#{Session.token_estimate(session)} tokens")

Demo.subsection("Creating an agent")

agent =
  Agent.new(
    tools: [
      Rag.Agent.Tools.SearchRepos,
      Rag.Agent.Tools.ReadFile,
      Rag.Agent.Tools.AnalyzeCode
    ],
    max_iterations: 5
  )

IO.puts("Agent created:")
IO.puts("  Provider: Gemini (default)")
IO.puts("  Tools: #{Registry.count(agent.registry)}")
IO.puts("  Max iterations: #{agent.max_iterations}")

# =============================================================================
# 5. ROUTING STRATEGIES
# =============================================================================

Demo.section("5. ROUTING STRATEGIES")

Demo.subsection("Fallback strategy")
{:ok, fallback_router} = Router.new(providers: [:gemini], strategy: :fallback)
IO.puts("Fallback strategy tries providers in order until one succeeds")

case Router.execute(fallback_router, :text, "Say 'hello'", []) do
  {:ok, response, _} ->
    IO.puts("Success: #{response}")

  {:error, reason} ->
    IO.puts("Failed: #{inspect(reason)}")
end

Demo.subsection("Round robin strategy")
{:ok, _rr_router} = Router.new(providers: [:gemini], strategy: :round_robin)
IO.puts("Round robin distributes load across providers")

# =============================================================================
# 6. TEXT CHUNKING
# =============================================================================

Demo.section("6. TEXT CHUNKING")

long_text = """
Elixir is a dynamic, functional language for building scalable applications.
It leverages the Erlang VM, known for running low-latency, distributed systems.
The language features include pattern matching, guards, and macros.
Elixir provides protocols for polymorphism and structs for data.
Phoenix builds on Elixir to provide a productive web framework.
LiveView enables rich real-time experiences without JavaScript.
"""

chunks = VectorStore.chunk_text(long_text, max_chars: 150, overlap: 30)

IO.puts("Original text: #{String.length(long_text)} chars")
IO.puts("Chunked into #{length(chunks)} pieces (max 150 chars, 30 overlap):")

for {chunk, idx} <- Enum.with_index(chunks, 1) do
  IO.puts("\n  Chunk #{idx} (#{String.length(chunk)} chars):")
  IO.puts("  \"#{String.slice(chunk, 0, 60)}...\"")
end

# =============================================================================
# 7. RAG PIPELINE (Putting it all together)
# =============================================================================

Demo.section("7. RAG PIPELINE - Putting it all together")

# The complete RAG flow:
# 1. User asks a question
# 2. Generate embedding for the question
# 3. Search vector store for relevant context
# 4. Send question + context to LLM
# 5. Return augmented response

user_question = "How does Elixir handle concurrency?"
IO.puts("User question: \"#{user_question}\"")

Demo.subsection("Step 1: Generate query embedding")
{:ok, [question_embedding], router} = Router.execute(router, :embeddings, [user_question], [])
IO.puts("Generated embedding (dim: #{length(question_embedding)})")

Demo.subsection("Step 2: Search for relevant context")
context_results = Repo.all(VectorStore.semantic_search_query(question_embedding, limit: 3))
IO.puts("Found #{length(context_results)} relevant documents")

Demo.subsection("Step 3: Build augmented prompt")

context =
  context_results
  |> Enum.map(fn r -> "- #{r.content} (from #{r.source})" end)
  |> Enum.join("\n")

augmented_prompt = """
Based on the following context, answer the user's question.

Context:
#{context}

Question: #{user_question}

Answer concisely based on the context provided.
"""

IO.puts("Augmented prompt built (#{String.length(augmented_prompt)} chars)")

Demo.subsection("Step 4: Generate response")

case Router.execute(router, :text, augmented_prompt, []) do
  {:ok, response, _} ->
    IO.puts("\nRAG Response:")
    IO.puts(response)

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end

# =============================================================================
Demo.section("DEMO COMPLETE")
IO.puts("All RAG library features demonstrated successfully!")
IO.puts("\nDatabase contains #{Repo.aggregate(Chunk, :count)} chunks")
