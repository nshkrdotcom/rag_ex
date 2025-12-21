# Vector Store Example
#
# This example demonstrates building and querying a vector store.
# Note: This example runs in-memory without a database.
#
# Run from project root:
#   mix run examples/vector_store.exs
#
# Prerequisites:
#   - Set GEMINI_API_KEY environment variable

alias Rag.VectorStore
alias Rag.Router

# Helper module for cosine similarity
defmodule VectorHelper do
  def cosine_similarity(a, b) do
    dot = Enum.zip(a, b) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    norm_a = :math.sqrt(Enum.map(a, fn x -> x * x end) |> Enum.sum())
    norm_b = :math.sqrt(Enum.map(b, fn x -> x * x end) |> Enum.sum())
    dot / (norm_a * norm_b)
  end
end

IO.puts("=== Vector Store Example ===\n")

# Create a router for embedding generation
{:ok, router} = Router.new(providers: [:gemini])

# Sample documents
documents = [
  %{
    content:
      "Elixir is a functional, concurrent programming language that runs on the BEAM virtual machine.",
    source: "intro.md"
  },
  %{
    content:
      "GenServer is a behaviour module for implementing the server of a client-server relation.",
    source: "otp/genserver.md"
  },
  %{
    content:
      "Phoenix is a web framework written in Elixir that implements the server-side MVC pattern.",
    source: "phoenix/overview.md"
  },
  %{
    content: "Ecto is a toolkit for data mapping and language integrated query for Elixir.",
    source: "ecto/intro.md"
  },
  %{
    content: "LiveView enables rich, real-time user experiences with server-rendered HTML.",
    source: "phoenix/liveview.md"
  }
]

IO.puts("1. Building chunks from documents:")
IO.puts(String.duplicate("-", 40))

chunks = VectorStore.build_chunks(documents)
IO.puts("Created #{length(chunks)} chunks")

for chunk <- chunks do
  IO.puts("  - #{chunk.source}: #{String.slice(chunk.content, 0, 50)}...")
end

IO.puts("")

# Generate embeddings
IO.puts("2. Generating embeddings:")
IO.puts(String.duplicate("-", 40))

contents = Enum.map(chunks, & &1.content)

case Router.execute(router, :embeddings, contents, []) do
  {:ok, embeddings, router} ->
    IO.puts("Generated #{length(embeddings)} embeddings")
    IO.puts("Embedding dimension: #{length(hd(embeddings))}")

    chunks_with_embeddings = VectorStore.add_embeddings(chunks, embeddings)
    IO.puts("Added embeddings to chunks")

    IO.puts("")

    # Simulate semantic search (in-memory cosine similarity)
    IO.puts("3. Simulating semantic search:")
    IO.puts(String.duplicate("-", 40))

    query = "How do I build web applications?"
    IO.puts("Query: \"#{query}\"")

    case Router.execute(router, :embeddings, [query], []) do
      {:ok, [query_embedding], _router} ->
        # Calculate cosine similarity for each chunk
        results =
          chunks_with_embeddings
          |> Enum.map(fn chunk ->
            similarity = VectorHelper.cosine_similarity(query_embedding, chunk.embedding)
            {chunk, similarity}
          end)
          |> Enum.sort_by(&elem(&1, 1), :desc)
          |> Enum.take(3)

        IO.puts("\nTop 3 results:")

        for {{chunk, score}, idx} <- Enum.with_index(results, 1) do
          IO.puts("  #{idx}. [#{Float.round(score, 3)}] #{chunk.source}")
          IO.puts("     #{String.slice(chunk.content, 0, 60)}...")
        end

      {:error, reason} ->
        IO.puts("Error generating query embedding: #{inspect(reason)}")
    end

  {:error, reason} ->
    IO.puts("Error generating embeddings: #{inspect(reason)}")
end

IO.puts("")

# Text chunking demo
IO.puts("4. Text chunking:")
IO.puts(String.duplicate("-", 40))

long_text = """
Elixir is a dynamic, functional language for building scalable and maintainable applications.
It leverages the Erlang VM, known for running low-latency, distributed, and fault-tolerant systems.
Elixir provides productive tooling and an extensible design.
The language features include pattern matching, guards, and a macro system for metaprogramming.
Elixir also provides protocols for polymorphism and structs for data structuring.
"""

text_chunks = VectorStore.chunk_text(long_text, max_chars: 150, overlap: 20)
IO.puts("Split into #{length(text_chunks)} chunks with 150 char max and 20 char overlap:")

for {chunk, idx} <- Enum.with_index(text_chunks, 1) do
  IO.puts("\n  Chunk #{idx} (#{String.length(chunk)} chars):")
  IO.puts("  #{inspect(chunk)}")
end

IO.puts("\n=== Done ===")
