# Chunking Strategies Example
#
# This example demonstrates all chunking strategies available in Rag.Chunking.
# Each strategy has different use cases and trade-offs for document processing.
#
# Run from project root:
#   mix run examples/chunking_strategies.exs
#
# Prerequisites:
#   - Set GEMINI_API_KEY environment variable (for semantic chunking demo)

alias Rag.Chunking
alias Rag.Router

IO.puts("=== Chunking Strategies Demo ===\n")

# Sample document with multiple paragraphs and clear structure
sample_document = """
Elixir is a dynamic, functional language designed for building scalable and maintainable applications. It leverages the Erlang VM, known for running low-latency, distributed, and fault-tolerant systems, while also being successfully used in web development, embedded software, data ingestion, and multimedia processing. Elixir provides productive tooling and an extensible design.

The language features include powerful pattern matching capabilities. Pattern matching allows developers to easily destructure data and match specific patterns in function clauses and case statements. This leads to more declarative and readable code. Guards provide additional constraints on pattern matches. Elixir also supports protocols for polymorphism and structs for organizing data.

Elixir's concurrency model is based on lightweight processes that communicate via message passing. These processes are isolated and share nothing, making concurrent programming safer and more predictable. The BEAM VM can handle millions of processes efficiently. Supervisors provide fault tolerance by monitoring and restarting failed processes automatically.

The ecosystem includes Phoenix for web development, Ecto for database interaction, and Nerves for embedded systems. LiveView enables rich, real-time user experiences with server-rendered HTML. The community is vibrant and growing, with excellent documentation and learning resources available.
"""

# Helper function to display chunk information
defmodule ChunkHelper do
  def display_chunks(chunks, title) do
    IO.puts(title)
    IO.puts(String.duplicate("-", 60))
    IO.puts("Total chunks: #{length(chunks)}\n")

    for {chunk, idx} <- Enum.with_index(chunks, 1) do
      char_count = String.length(chunk.content)
      word_count = chunk.content |> String.split() |> length()
      preview = String.slice(chunk.content, 0, 70) |> String.replace("\n", " ")

      IO.puts("Chunk #{idx}:")
      IO.puts("  Characters: #{char_count}, Words: #{word_count}")
      IO.puts("  Preview: #{preview}...")

      if Map.has_key?(chunk.metadata, :hierarchy) do
        IO.puts("  Hierarchy: #{chunk.metadata.hierarchy}")
      end

      IO.puts("")
    end
  end

  def display_summary(strategies_results) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("SUMMARY COMPARISON")
    IO.puts(String.duplicate("=", 60))

    for {name, chunks} <- strategies_results do
      avg_size =
        if length(chunks) > 0 do
          total = Enum.reduce(chunks, 0, fn c, acc -> acc + String.length(c.content) end)
          round(total / length(chunks))
        else
          0
        end

      IO.puts("#{name}:")
      IO.puts("  Chunks: #{length(chunks)}, Avg size: #{avg_size} chars")
    end

    IO.puts("")
  end
end

# Configuration for chunking
max_chars = 300
overlap = 50
min_chars = 100

IO.puts("Configuration:")
IO.puts("  max_chars: #{max_chars}")
IO.puts("  overlap: #{overlap} (for character strategy)")
IO.puts("  min_chars: #{min_chars} (for sentence/paragraph strategies)")
IO.puts("\nOriginal document length: #{String.length(sample_document)} characters\n")
IO.puts(String.duplicate("=", 60))
IO.puts("")

# Track results for comparison
results = []

# 1. CHARACTER-BASED CHUNKING
# Use case: Fixed-size chunks, good for consistent embedding sizes
# Pros: Predictable chunk sizes, works with any text
# Cons: May split sentences/thoughts mid-way
IO.puts("1. CHARACTER-BASED CHUNKING")
IO.puts("   Use case: Fixed-size chunks with predictable lengths")
IO.puts("   Best for: Consistent embedding sizes, any text structure")
IO.puts("")

char_chunks =
  Chunking.chunk(sample_document, strategy: :character, max_chars: max_chars, overlap: overlap)

ChunkHelper.display_chunks(
  char_chunks,
  "Character chunks (max: #{max_chars}, overlap: #{overlap})"
)

results = [{"Character", char_chunks} | results]

# 2. SENTENCE-BASED CHUNKING
# Use case: Preserve sentence boundaries, more semantic coherence
# Pros: Maintains complete thoughts, better context
# Cons: Variable chunk sizes
IO.puts(String.duplicate("=", 60))
IO.puts("\n2. SENTENCE-BASED CHUNKING")
IO.puts("   Use case: Preserve complete sentences and thoughts")
IO.puts("   Best for: Q&A systems, semantic coherence")
IO.puts("")

sentence_chunks =
  Chunking.chunk(sample_document,
    strategy: :sentence,
    max_chars: max_chars,
    min_chars: min_chars
  )

ChunkHelper.display_chunks(
  sentence_chunks,
  "Sentence chunks (max: #{max_chars}, min: #{min_chars})"
)

results = [{"Sentence", sentence_chunks} | results]

# 3. PARAGRAPH-BASED CHUNKING
# Use case: Preserve paragraph structure, maintain topic coherence
# Pros: Natural boundaries, related information stays together
# Cons: Variable sizes, may be too large/small
IO.puts(String.duplicate("=", 60))
IO.puts("\n3. PARAGRAPH-BASED CHUNKING")
IO.puts("   Use case: Preserve topic boundaries and paragraph structure")
IO.puts("   Best for: Documents with clear paragraph organization")
IO.puts("")

paragraph_chunks =
  Chunking.chunk(sample_document,
    strategy: :paragraph,
    max_chars: max_chars,
    min_chars: min_chars
  )

ChunkHelper.display_chunks(
  paragraph_chunks,
  "Paragraph chunks (max: #{max_chars}, min: #{min_chars})"
)

results = [{"Paragraph", paragraph_chunks} | results]

# 4. RECURSIVE CHUNKING
# Use case: Hierarchical splitting (paragraph -> sentence -> character)
# Pros: Tries to preserve structure while respecting size limits
# Cons: More complex, may still split awkwardly
IO.puts(String.duplicate("=", 60))
IO.puts("\n4. RECURSIVE CHUNKING")
IO.puts("   Use case: Hierarchical splitting (paragraph -> sentence -> character)")
IO.puts("   Best for: Mixed content with varying structure")
IO.puts("")

recursive_chunks =
  Chunking.chunk(sample_document,
    strategy: :recursive,
    max_chars: max_chars,
    min_chars: min_chars
  )

ChunkHelper.display_chunks(
  recursive_chunks,
  "Recursive chunks (max: #{max_chars}, min: #{min_chars})"
)

results = [{"Recursive", recursive_chunks} | results]

# 5. SEMANTIC CHUNKING
# Use case: Group semantically similar sentences using embeddings
# Pros: Keeps related content together based on meaning
# Cons: Requires embedding API, slower, costs more
IO.puts(String.duplicate("=", 60))
IO.puts("\n5. SEMANTIC CHUNKING")
IO.puts("   Use case: Group semantically similar content using embeddings")
IO.puts("   Best for: Maintaining semantic coherence, topic-focused chunks")
IO.puts("")

# Try to use semantic chunking with real embeddings
results =
  case Router.new(providers: [:gemini]) do
    {:ok, router} ->
      IO.puts("Using Gemini API for semantic chunking...\n")

      # Define embedding function that uses the router
      embedding_fn = fn text ->
        case Router.execute(router, :embeddings, [text], []) do
          {:ok, [embedding], _router} ->
            embedding

          {:error, reason} ->
            IO.puts("Warning: Failed to generate embedding: #{inspect(reason)}")
            # Return a dummy embedding
            List.duplicate(0.0, 768)
        end
      end

      semantic_chunks =
        Chunking.chunk(sample_document,
          strategy: :semantic,
          max_chars: max_chars,
          embedding_fn: embedding_fn,
          threshold: 0.75
        )

      ChunkHelper.display_chunks(
        semantic_chunks,
        "Semantic chunks (max: #{max_chars}, threshold: 0.75)"
      )

      [{"Semantic", semantic_chunks} | results]

    {:error, reason} ->
      IO.puts("Skipping semantic chunking (Router initialization failed)")
      IO.puts("Reason: #{inspect(reason)}")
      IO.puts("Note: Semantic chunking requires GEMINI_API_KEY environment variable")
      IO.puts("")

      # Show example with mock embedding function
      IO.puts("Demonstrating with mock embeddings instead:\n")

      mock_embedding_fn = fn text ->
        # Simple mock: generate embedding based on text length and content
        words = String.split(text)
        word_count = length(words)

        # Create a simple 10-dimensional mock embedding
        List.duplicate(word_count / 100, 10)
      end

      semantic_chunks =
        Chunking.chunk(sample_document,
          strategy: :semantic,
          max_chars: max_chars,
          embedding_fn: mock_embedding_fn,
          threshold: 0.8
        )

      ChunkHelper.display_chunks(
        semantic_chunks,
        "Semantic chunks with MOCK embeddings (max: #{max_chars}, threshold: 0.8)"
      )

      [{"Semantic (mock)", semantic_chunks} | results]
  end

# Display summary comparison
ChunkHelper.display_summary(Enum.reverse(results))

# Additional demonstration: Chunk overlap
IO.puts(String.duplicate("=", 60))
IO.puts("OVERLAP DEMONSTRATION (Character strategy)")
IO.puts(String.duplicate("=", 60))
IO.puts("")

short_text = "First sentence here. Second sentence follows. Third sentence ends. Fourth is last."

IO.puts("Sample text: #{short_text}\n")

for overlap_size <- [0, 10, 20] do
  overlapping_chunks =
    Chunking.chunk(short_text, strategy: :character, max_chars: 40, overlap: overlap_size)

  IO.puts("With overlap: #{overlap_size} characters")

  for {chunk, idx} <- Enum.with_index(overlapping_chunks, 1) do
    IO.puts("  Chunk #{idx}: \"#{chunk.content}\"")
  end

  IO.puts("")
end

# Strategy Selection Guide
IO.puts(String.duplicate("=", 60))
IO.puts("STRATEGY SELECTION GUIDE")
IO.puts(String.duplicate("=", 60))
IO.puts("")
IO.puts("Choose your chunking strategy based on your use case:")
IO.puts("")
IO.puts("CHARACTER-BASED:")
IO.puts("  ✓ Need consistent chunk sizes for embedding models")
IO.puts("  ✓ Working with unstructured or continuous text")
IO.puts("  ✓ Want predictable memory/processing requirements")
IO.puts("")
IO.puts("SENTENCE-BASED:")
IO.puts("  ✓ Building Q&A or retrieval systems")
IO.puts("  ✓ Need complete thoughts preserved")
IO.puts("  ✓ Working with well-structured prose")
IO.puts("")
IO.puts("PARAGRAPH-BASED:")
IO.puts("  ✓ Documents have clear topic boundaries")
IO.puts("  ✓ Want to keep related information together")
IO.puts("  ✓ Processing articles, blog posts, or papers")
IO.puts("")
IO.puts("RECURSIVE:")
IO.puts("  ✓ Mixed content with varying structure")
IO.puts("  ✓ Want smart hierarchy preservation")
IO.puts("  ✓ Balance between structure and size constraints")
IO.puts("")
IO.puts("SEMANTIC:")
IO.puts("  ✓ Semantic coherence is critical")
IO.puts("  ✓ Can afford embedding API costs")
IO.puts("  ✓ Building high-quality RAG systems")
IO.puts("  ✓ Processing documents where topic shifts matter")
IO.puts("")

IO.puts("=== Done ===")
