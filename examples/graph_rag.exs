# GraphRAG Example
#
# This example demonstrates the complete GraphRAG workflow:
# 1. Entity and relationship extraction from text using LLM
# 2. Building a knowledge graph in PostgreSQL with pgvector
# 3. Community detection with graph algorithms
# 4. Graph-based retrieval (local, global, and hybrid modes)
# 5. Graph traversal (BFS/DFS)
#
# Prerequisites:
#   - PostgreSQL database with pgvector extension installed
#   - Graph tables created (graph_entities, graph_edges, graph_communities)
#   - Set GEMINI_API_KEY or other LLM provider API key
#   - Configure database connection in config/config.exs
#
# Run from project root:
#   mix run examples/graph_rag.exs
#
# Note: This example assumes you have already run the database migrations
# to create the graph tables. See priv/repo/migrations for table schemas.
#
# KNOWN ISSUE: Some LLM providers (including Gemini) wrap JSON responses
# in markdown code blocks (```json ... ```), which causes JSON parsing
# errors. The example handles this gracefully and continues to demonstrate
# the GraphRAG APIs even when extraction fails. In production, you would
# add JSON extraction logic to strip markdown formatting.

alias Rag.Router
alias Rag.GraphRAG.Extractor

# ============================================================================
# Configuration and Setup
# ============================================================================

IO.puts("=== GraphRAG Complete Example ===\n")

# Check for API key
api_key =
  System.get_env("GEMINI_API_KEY") || System.get_env("OPENAI_API_KEY") ||
    System.get_env("ANTHROPIC_API_KEY")

unless api_key do
  IO.puts("""
  ERROR: No LLM API key found!

  Please set one of the following environment variables:
    - GEMINI_API_KEY (recommended for this example)
    - OPENAI_API_KEY
    - ANTHROPIC_API_KEY

  Example:
    export GEMINI_API_KEY="your-api-key-here"
    mix run examples/graph_rag.exs

  NOTE: This example demonstrates the GraphRAG APIs and workflow.
  Some LLM providers may wrap JSON responses in markdown code blocks,
  which can cause parsing errors. This is a known limitation.
  The example will continue to run and demonstrate other features
  even if entity extraction encounters errors.
  """)

  System.halt(1)
end

# Initialize Router for LLM operations
# Use Gemini explicitly for entity extraction (most reliable for JSON output)
IO.puts("1. Initializing Router...")
IO.puts(String.duplicate("-", 60))

{:ok, router} = Router.new(providers: [:gemini])
IO.puts("Router initialized with Gemini provider")
IO.puts("")

# ============================================================================
# Sample Documents
# ============================================================================

# Sample text documents about a fictional tech company
documents = [
  """
  Alice Smith is a senior software engineer at TechCorp. She leads the AI
  research team and has been working on natural language processing systems
  for over 5 years. Alice holds a PhD in Computer Science from Stanford
  University and specializes in machine learning and deep learning.
  """,
  """
  Bob Johnson works as a product manager at TechCorp. He collaborates closely
  with Alice Smith on AI product development. Bob previously worked at Google
  for 3 years before joining TechCorp in 2020. He is based in San Francisco
  and manages the AI products division.
  """,
  """
  TechCorp is a technology company headquartered in San Francisco, California.
  The company was founded in 2015 and focuses on artificial intelligence and
  machine learning solutions. TechCorp has raised over $100M in funding and
  employs approximately 200 people across three offices.
  """,
  """
  The AI Research Lab at TechCorp is working on a new project called NeuralNet,
  which aims to build advanced neural network architectures for language
  understanding. Alice Smith is the technical lead for this project, with
  Bob Johnson managing the product roadmap.
  """,
  """
  Stanford University is a prestigious research university located in
  California. It has a renowned Computer Science department that has produced
  many tech industry leaders. The university is known for its work in
  artificial intelligence and machine learning research.
  """
]

IO.puts("2. Sample Documents:")
IO.puts(String.duplicate("-", 60))
IO.puts("Loaded #{length(documents)} documents about:")
IO.puts("  - People: Alice Smith, Bob Johnson")
IO.puts("  - Organizations: TechCorp, Stanford University, Google")
IO.puts("  - Projects: NeuralNet")
IO.puts("  - Locations: San Francisco, California")
IO.puts("")

# ============================================================================
# Step 1: Entity and Relationship Extraction
# ============================================================================

IO.puts("3. Extracting Entities and Relationships...")
IO.puts(String.duplicate("-", 60))
IO.puts("Note: Entity extraction uses LLM and may take 30-60 seconds...")
IO.puts("")

# Extract entities and relationships from all documents
# Note: In production, you'd want to batch this or process in parallel
extraction_results =
  for {doc, idx} <- Enum.with_index(documents, 1) do
    IO.puts("Processing document #{idx}/#{length(documents)}...")

    try do
      case Extractor.extract(doc, router: router) do
        {:ok, result} ->
          IO.puts(
            "  Found #{length(result.entities)} entities, #{length(result.relationships)} relationships"
          )

          result

        {:error, reason} ->
          IO.puts("  Error extracting from document #{idx}")
          IO.puts("  Reason: #{inspect(reason)}")

          IO.puts(
            "  Note: Some LLMs wrap JSON in markdown code blocks, which causes parsing errors."
          )

          IO.puts("  This is a known issue - continuing with other documents...")
          %{entities: [], relationships: []}
      end
    rescue
      e ->
        IO.puts("  Exception during extraction: #{inspect(e)}")
        IO.puts("  Continuing with other documents...")
        %{entities: [], relationships: []}
    end
  end

# Collect all entities and relationships
all_entities = Enum.flat_map(extraction_results, & &1.entities)
all_relationships = Enum.flat_map(extraction_results, & &1.relationships)

IO.puts("\nExtraction complete!")
IO.puts("Total entities: #{length(all_entities)}")
IO.puts("Total relationships: #{length(all_relationships)}")
IO.puts("")

# Show sample entities
IO.puts("Sample entities:")

all_entities
|> Enum.take(5)
|> Enum.each(fn entity ->
  IO.puts("  - #{entity.name} (#{entity.type}): #{String.slice(entity.description, 0, 50)}...")
end)

IO.puts("")

# Show sample relationships
IO.puts("Sample relationships:")

all_relationships
|> Enum.take(5)
|> Enum.each(fn rel ->
  IO.puts("  - #{rel.source} --[#{rel.type}]--> #{rel.target}")
end)

IO.puts("")

# ============================================================================
# Step 2: Entity Resolution (Deduplication)
# ============================================================================

IO.puts("4. Resolving Duplicate Entities...")
IO.puts(String.duplicate("-", 60))

# Use LLM to identify duplicate entities and merge them
{resolved_entities, _entities_with_aliases} =
  if length(all_entities) > 0 do
    case Extractor.resolve_entities(all_entities, router: router) do
      {:ok, resolved} ->
        IO.puts(
          "Resolved #{length(all_entities)} entities to #{length(resolved)} unique entities"
        )

        # Show entities with aliases
        with_aliases = Enum.filter(resolved, fn e -> length(e.aliases) > 0 end)

        if length(with_aliases) > 0 do
          IO.puts("\nEntities with aliases:")

          with_aliases
          |> Enum.take(3)
          |> Enum.each(fn entity ->
            IO.puts("  - #{entity.name}: #{Enum.join(entity.aliases, ", ")}")
          end)
        end

        {resolved, with_aliases}

      {:error, reason} ->
        IO.puts("Entity resolution failed: #{inspect(reason)}")
        IO.puts("Continuing with unresolved entities...")
        {all_entities, []}
    end
  else
    IO.puts("No entities to resolve")
    {all_entities, []}
  end

# Use resolved entities going forward
_all_entities_with_embeddings = resolved_entities

IO.puts("")

# ============================================================================
# Step 3: Generate Embeddings for Entities
# ============================================================================

IO.puts("5. Generating Entity Embeddings...")
IO.puts(String.duplicate("-", 60))

# Generate embeddings for entity descriptions
_final_entities =
  if length(resolved_entities) > 0 do
    entity_texts = Enum.map(resolved_entities, fn e -> "#{e.name}: #{e.description}" end)

    case Router.execute(router, :embeddings, entity_texts, []) do
      {:ok, embeddings, _router} ->
        IO.puts("Generated #{length(embeddings)} embeddings")
        IO.puts("Embedding dimension: #{length(hd(embeddings))}")

        # Add embeddings to entities
        Enum.zip(resolved_entities, embeddings)
        |> Enum.map(fn {entity, embedding} ->
          Map.put(entity, :embedding, embedding)
        end)

      {:error, reason} ->
        IO.puts("Error generating embeddings: #{inspect(reason)}")
        IO.puts("Continuing without embeddings...")
        resolved_entities
    end
  else
    IO.puts("No entities to generate embeddings for")
    resolved_entities
  end

IO.puts("")

# ============================================================================
# Step 4: Store in Graph Database
# ============================================================================

IO.puts("6. Storing Entities and Relationships in PostgreSQL...")
IO.puts(String.duplicate("-", 60))

# Note: This example shows the API but won't actually connect to the database
# unless you have configured your repo and run migrations.
#
# To make this work with a real database:
# 1. Ensure Rag.Repo is configured in config/config.exs
# 2. Run migrations: mix ecto.migrate
# 3. Uncomment the code below

# Initialize graph store with your Ecto repo
# Uncomment the following line and replace with your actual repo:
# graph_store = %PgvectorGraphStore{repo: Rag.Repo}

IO.puts("""
Skipping database operations in this example.

To use a real PostgreSQL database:
1. Configure your Ecto repo in config/config.exs
2. Run migrations to create graph tables:
   mix ecto.migrate
3. Initialize the graph store:
   graph_store = %Rag.GraphStore.Pgvector{repo: MyApp.Repo}
4. Create entities and edges as shown below
""")

IO.puts("\nExample code for storing entities:")

IO.puts("""
# Create entities in the database
entity_id_map = %{}

for entity <- all_entities do
  case GraphStore.create_node(graph_store, %{
    type: entity.type,
    name: entity.name,
    properties: %{
      description: entity.description,
      aliases: entity.aliases
    },
    embedding: entity.embedding,
    source_chunk_ids: []  # Would link to actual document chunks
  }) do
    {:ok, node} ->
      entity_id_map = Map.put(entity_id_map, entity.name, node.id)
      IO.puts("  Created entity: \#{entity.name} (ID: \#{node.id})")

    {:error, reason} ->
      IO.puts("  Error creating entity \#{entity.name}: \#{inspect(reason)}")
  end
end
""")

IO.puts("\nExample code for storing relationships:")

IO.puts("""
# Create relationships in the database
for rel <- all_relationships do
  from_id = Map.get(entity_id_map, rel.source)
  to_id = Map.get(entity_id_map, rel.target)

  if from_id && to_id do
    case GraphStore.create_edge(graph_store, %{
      from_id: from_id,
      to_id: to_id,
      type: rel.type,
      weight: rel.weight,
      properties: %{description: rel.description}
    }) do
      {:ok, edge} ->
        IO.puts("  Created edge: \#{rel.source} -> \#{rel.target}")

      {:error, reason} ->
        IO.puts("  Error: \#{inspect(reason)}")
    end
  end
end
""")

IO.puts("")

# ============================================================================
# Step 5: Graph Traversal
# ============================================================================

IO.puts("7. Graph Traversal Examples...")
IO.puts(String.duplicate("-", 60))

IO.puts("""
Once entities are stored in the database, you can traverse the graph:

# Breadth-First Search (BFS) from Alice Smith
{:ok, bfs_nodes} = GraphStore.traverse(graph_store, alice_id,
  algorithm: :bfs,
  max_depth: 2
)

IO.puts("BFS traversal found \#{length(bfs_nodes)} nodes:")
for node <- bfs_nodes do
  IO.puts("  - \#{node.name} (depth: \#{node.depth})")
end

# Depth-First Search (DFS) from TechCorp
{:ok, dfs_nodes} = GraphStore.traverse(graph_store, techcorp_id,
  algorithm: :dfs,
  max_depth: 2
)

# Find neighbors of a specific entity
{:ok, neighbors} = GraphStore.find_neighbors(graph_store, alice_id,
  direction: :both,  # :in, :out, or :both
  limit: 10
)

IO.puts("Alice's neighbors:")
for neighbor <- neighbors do
  IO.puts("  - \#{neighbor.name} (\#{neighbor.type})")
end
""")

IO.puts("")

# ============================================================================
# Step 6: Community Detection
# ============================================================================

IO.puts("8. Community Detection...")
IO.puts(String.duplicate("-", 60))

IO.puts("""
Community detection groups related entities using graph algorithms:

# Detect communities using label propagation
{:ok, communities} = CommunityDetector.detect(graph_store,
  max_iterations: 100
)

IO.puts("Detected \#{length(communities)} communities")

for community <- communities do
  IO.puts("\\nCommunity \#{community.id}:")
  IO.puts("  Members: \#{length(community.entity_ids)} entities")
  IO.puts("  Level: \#{community.level}")
end

# Generate summaries for communities using LLM
{:ok, summarized} = CommunityDetector.summarize_communities(
  graph_store,
  communities,
  router: router
)

for community <- summarized do
  IO.puts("\\nCommunity \#{community.id} Summary:")
  IO.puts("  \#{community.summary}")
end

# Build hierarchical communities (multi-level)
{:ok, hierarchy} = CommunityDetector.build_hierarchy(graph_store,
  levels: 3
)

IO.puts("\\nBuilt \#{length(hierarchy)} levels of hierarchy")
for {level_communities, level} <- Enum.with_index(hierarchy) do
  IO.puts("  Level \#{level}: \#{length(level_communities)} communities")
end
""")

IO.puts("")

# ============================================================================
# Step 7: Graph-Based Retrieval
# ============================================================================

IO.puts("9. Graph-Based Retrieval...")
IO.puts(String.duplicate("-", 60))

IO.puts("""
GraphRAG supports three retrieval modes:

1. LOCAL SEARCH - Find specific, detailed information
   - Vector search on entity embeddings
   - Graph expansion to find related entities
   - Collect source chunks from discovered entities

2. GLOBAL SEARCH - Find high-level context
   - Vector search on community summaries
   - Return broad organizational context

3. HYBRID SEARCH - Combine both approaches
   - Run local and global in parallel
   - Merge with weighted Reciprocal Rank Fusion (RRF)

Example code:

# Create a graph retriever (local mode)
retriever = GraphRetriever.new(
  graph_store: graph_store,
  vector_store: vector_store,  # Your vector store instance
  mode: :local,
  depth: 2  # How many hops to traverse from seed entities
)

# Generate query embedding
query = "What AI projects is Alice working on?"
{:ok, [query_embedding], _router} = Router.execute(router, :embeddings, [query], [])

# Perform local search
{:ok, results} = GraphRetriever.local_search(retriever, query_embedding,
  limit: 5
)

IO.puts("\\nLocal search results:")
for result <- results do
  IO.puts("  Score: \#{result.score}")
  IO.puts("  Content: \#{String.slice(result.content, 0, 100)}...")
  IO.puts("  Graph depth: \#{result.metadata.graph_depth}")
  IO.puts("")
end

# Perform global search (community summaries)
{:ok, global_results} = GraphRetriever.global_search(retriever, query_embedding,
  limit: 3
)

IO.puts("\\nGlobal search results (community summaries):")
for result <- global_results do
  IO.puts("  Community: \#{result.metadata.community_id}")
  IO.puts("  Entities: \#{result.metadata.entity_count}")
  IO.puts("  Summary: \#{String.slice(result.content, 0, 100)}...")
  IO.puts("")
end

# Perform hybrid search
hybrid_retriever = GraphRetriever.new(
  graph_store: graph_store,
  vector_store: vector_store,
  mode: :hybrid,
  local_weight: 0.7,   # Weight for local results
  global_weight: 0.3   # Weight for global results
)

{:ok, hybrid_results} = GraphRetriever.hybrid_search(hybrid_retriever, query_embedding,
  limit: 10
)

IO.puts("\\nHybrid search results (RRF-merged):")
for result <- hybrid_results do
  IO.puts("  RRF Score: \#{result.score}")
  IO.puts("  Content: \#{String.slice(result.content, 0, 100)}...")
  IO.puts("")
end
""")

IO.puts("")

# ============================================================================
# Step 8: Vector Search on Entities
# ============================================================================

IO.puts("10. Vector Search on Entities...")
IO.puts(String.duplicate("-", 60))

IO.puts("""
Search for entities similar to a query embedding:

query = "machine learning researcher"
{:ok, [query_embedding], _router} = Router.execute(router, :embeddings, [query], [])

# Find similar entities
{:ok, similar_entities} = GraphStore.vector_search(graph_store, query_embedding,
  limit: 5,
  type: :person  # Optional: filter by entity type
)

IO.puts("\\nEntities similar to '\#{query}':")
for entity <- similar_entities do
  IO.puts("  - \#{entity.name} (\#{entity.type})")
  IO.puts("    \#{entity.properties.description}")
  IO.puts("")
end

# Vector search supports type filtering
{:ok, orgs} = GraphStore.vector_search(graph_store, query_embedding,
  type: :organization,
  limit: 3
)
""")

IO.puts("")

# ============================================================================
# Summary and Best Practices
# ============================================================================

IO.puts("11. Summary and Best Practices")
IO.puts(String.duplicate("=", 60))

IO.puts("""
GraphRAG combines knowledge graphs with vector search for enhanced RAG:

KEY CONCEPTS:
1. Entity Extraction - Use LLM to extract entities from text
2. Relationship Extraction - Identify connections between entities
3. Entity Resolution - Deduplicate entities across documents
4. Graph Storage - Store entities and edges in PostgreSQL with pgvector
5. Community Detection - Find clusters using label propagation
6. Graph Traversal - Navigate relationships (BFS/DFS)
7. Graph-Based Retrieval - Leverage graph structure for better context

RETRIEVAL STRATEGIES:
- Local Search: Best for specific, detailed questions
  → "What is Alice working on?"
- Global Search: Best for broad, overview questions
  → "What are the main themes in the organization?"
- Hybrid Search: Best for complex questions needing both
  → "How do AI projects relate to the company's strategy?"

BEST PRACTICES:
1. Batch entity extraction for efficiency
2. Use entity resolution to handle duplicates
3. Generate quality embeddings for entities
4. Build community hierarchies for multi-scale context
5. Tune traversal depth based on your graph density
6. Use type filters to focus searches
7. Adjust local/global weights based on your use case

PERFORMANCE TIPS:
- Index entity embeddings with pgvector IVFFLAT or HNSW
- Cache community summaries
- Use concurrent processing for extraction
- Limit traversal depth to avoid over-expansion
- Use database transactions for bulk inserts

ERROR HANDLING:
- Always check for API key availability
- Handle LLM extraction failures gracefully
- Validate entity/relationship formats
- Use database transactions for consistency
- Implement retry logic for transient failures

For more information, see:
- lib/rag/graph_rag/extractor.ex
- lib/rag/graph_rag/community_detector.ex
- lib/rag/graph_store/pgvector.ex
- lib/rag/retriever/graph.ex
""")

IO.puts("\n=== GraphRAG Example Complete ===")
