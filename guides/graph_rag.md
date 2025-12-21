# GraphRAG

GraphRAG extends traditional RAG by building knowledge graphs from documents for enhanced retrieval through entity relationships and community detection.

## Overview

GraphRAG provides:
- **Entity Extraction** - Extract entities and relationships using LLM
- **Graph Storage** - Store entities, edges, and communities in PostgreSQL
- **Community Detection** - Cluster related entities with label propagation
- **Graph Retrieval** - Local, global, and hybrid search modes

## Architecture

```
Documents
    |
    v
Entity Extraction (LLM)
    |
    v
Graph Storage (PostgreSQL + pgvector)
    |
    v
Community Detection (Label Propagation)
    |
    v
Graph Retrieval (Local/Global/Hybrid)
```

## Entity Extraction

Extract entities and relationships from text:

```elixir
alias Rag.GraphRAG.Extractor
alias Rag.Router

{:ok, router} = Router.new(providers: [:gemini])

text = "Alice works for Acme Corp in New York. Bob reports to Alice."

{:ok, result} = Extractor.extract(text, router: router)
# result.entities: [%{name: "Alice", type: :person, ...}, ...]
# result.relationships: [%{source: "Bob", target: "Alice", type: :reports_to, ...}]
```

### Entity Types

- `:person` - Individuals
- `:organization` - Companies, institutions
- `:location` - Geographic places
- `:event` - Named events
- `:concept` - Abstract ideas
- `:technology` - Technologies/tools
- `:document` - Documents/publications

### Relationship Types

- `:works_for` - Employment
- `:located_in` - Geography
- `:created_by` - Authorship
- `:part_of` - Membership
- `:related_to` - General
- `:uses` - Tool usage
- `:depends_on` - Dependencies

### Batch Extraction

```elixir
{:ok, results} = Extractor.extract_batch(documents,
  router: router,
  max_concurrency: 4,
  timeout: 60_000
)
```

### Entity Resolution

Merge duplicate entities:

```elixir
entities = [
  %{name: "New York", type: :location, ...},
  %{name: "NYC", type: :location, ...}
]

{:ok, resolved} = Extractor.resolve_entities(entities, router: router)
# Returns: [%{name: "New York", aliases: ["NYC"], ...}]
```

## Graph Storage

### Database Setup

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
      add :from_id, references(:graph_entities, on_delete: :delete_all)
      add :to_id, references(:graph_entities, on_delete: :delete_all)
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
end
```

### Creating Nodes and Edges

```elixir
alias Rag.GraphStore
alias Rag.GraphStore.Pgvector

store = %Pgvector{repo: MyApp.Repo}

# Create entity
{:ok, alice} = GraphStore.create_node(store, %{
  type: :person,
  name: "Alice Smith",
  properties: %{role: "engineer"},
  embedding: [0.1, 0.2, ...],
  source_chunk_ids: [1, 2, 3]
})

# Create relationship
{:ok, edge} = GraphStore.create_edge(store, %{
  from_id: alice.id,
  to_id: acme.id,
  type: :works_for,
  weight: 0.95
})
```

### Graph Traversal

```elixir
# Find neighbors
{:ok, neighbors} = GraphStore.find_neighbors(store, alice.id,
  direction: :both,  # :in, :out, or :both
  limit: 10,
  edge_type: :works_for
)

# BFS traversal
{:ok, nodes} = GraphStore.traverse(store, alice.id,
  max_depth: 2,
  algorithm: :bfs
)

# DFS traversal
{:ok, nodes} = GraphStore.traverse(store, alice.id,
  max_depth: 3,
  algorithm: :dfs
)
```

### Vector Search on Entities

```elixir
{:ok, similar} = GraphStore.vector_search(store, query_embedding,
  limit: 5,
  type: :person  # Optional filter
)
```

## Community Detection

Detect clusters of related entities:

```elixir
alias Rag.GraphRAG.CommunityDetector

# Detect communities
{:ok, communities} = CommunityDetector.detect(store, max_iterations: 100)
# Returns: [%{id: 1, level: 0, entity_ids: [1, 2, 3], summary: nil}, ...]

# Generate summaries with LLM
{:ok, summarized} = CommunityDetector.summarize_communities(store, communities,
  router: router
)

# Combined: detect and summarize
{:ok, communities} = CommunityDetector.detect_and_summarize(store,
  router: router,
  max_iterations: 100
)
```

### Hierarchical Communities

Build multi-level community hierarchy:

```elixir
{:ok, hierarchy} = CommunityDetector.build_hierarchy(store,
  levels: 3,
  max_iterations: 100
)
# Returns: [[level_0_communities], [level_1_communities], [level_2_communities]]
```

## Graph-Based Retrieval

### Creating a Graph Retriever

```elixir
alias Rag.Retriever.Graph

retriever = Graph.new(
  graph_store: graph_store,
  vector_store: vector_store,
  mode: :hybrid,
  depth: 2,
  local_weight: 0.7,
  global_weight: 0.3
)
```

### Search Modes

#### Local Search

Find specific, detailed information via entity expansion:

```elixir
{:ok, results} = Graph.local_search(retriever, query_embedding,
  limit: 10,
  depth: 2
)
```

**Process:**
1. Vector search on entity embeddings
2. BFS traversal to related entities
3. Collect source chunks from entities
4. Score by graph distance (closer = higher)

**Best for:** "What is Alice's role?", specific entity queries

#### Global Search

Find high-level context via community summaries:

```elixir
{:ok, results} = Graph.global_search(retriever, query_embedding,
  limit: 10
)
```

**Process:**
1. Vector search on community summaries
2. Return community summaries as context

**Best for:** "What are the main areas of focus?", overview queries

#### Hybrid Search

Combine local and global with weighted RRF:

```elixir
{:ok, results} = Graph.hybrid_search(retriever, query_embedding,
  limit: 10
)
```

**Process:**
1. Run local and global in parallel
2. Apply weighted RRF fusion
3. Return merged results

**Best for:** Complex queries needing multiple perspectives

### Using the Retriever

```elixir
alias Rag.Retriever

# With embedding
{:ok, results} = Retriever.retrieve(retriever, query_embedding, limit: 10)

# With text (requires embedding function)
{:ok, results} = Retriever.retrieve(retriever, "search query",
  limit: 10,
  embedding_fn: fn text ->
    {:ok, [emb], _} = Router.execute(router, :embeddings, [text], [])
    emb
  end
)
```

## Complete Workflow

```elixir
alias Rag.Router
alias Rag.GraphStore
alias Rag.GraphStore.Pgvector
alias Rag.GraphRAG.{Extractor, CommunityDetector}
alias Rag.Retriever.Graph

# 1. Initialize
{:ok, router} = Router.new(providers: [:gemini])
store = %Pgvector{repo: MyApp.Repo}

# 2. Extract entities from documents
documents = ["doc1 text", "doc2 text", "doc3 text"]
{:ok, results} = Extractor.extract_batch(documents, router: router)

# 3. Resolve duplicates
all_entities = Enum.flat_map(results, & &1.entities)
{:ok, resolved} = Extractor.resolve_entities(all_entities, router: router)

# 4. Generate embeddings
entity_texts = Enum.map(resolved, &"#{&1.name}: #{&1.description}")
{:ok, embeddings, _} = Router.execute(router, :embeddings, entity_texts, [])

# 5. Store entities with embeddings
entity_ids = for {entity, embedding} <- Enum.zip(resolved, embeddings) do
  {:ok, node} = GraphStore.create_node(store, %{
    type: entity.type,
    name: entity.name,
    properties: %{description: entity.description},
    embedding: embedding
  })
  {entity.name, node.id}
end |> Map.new()

# 6. Create relationships
all_rels = Enum.flat_map(results, & &1.relationships)
for rel <- all_rels do
  from_id = entity_ids[rel.source]
  to_id = entity_ids[rel.target]

  if from_id && to_id do
    GraphStore.create_edge(store, %{
      from_id: from_id,
      to_id: to_id,
      type: rel.type,
      weight: rel.weight
    })
  end
end

# 7. Detect and summarize communities
{:ok, communities} = CommunityDetector.detect_and_summarize(store,
  router: router,
  max_iterations: 100
)

# 8. Create retriever
retriever = Graph.new(
  graph_store: store,
  vector_store: vector_store,
  mode: :hybrid,
  depth: 2
)

# 9. Query
{:ok, [query_emb], _} = Router.execute(router, :embeddings, ["AI projects"], [])
{:ok, results} = Retriever.retrieve(retriever, query_emb, limit: 10)
```

## Choosing Search Mode

| Query Type | Mode | Example |
|------------|------|---------|
| Specific entity | `:local` | "What is Alice's role?" |
| Overview | `:global` | "What are the main themes?" |
| Complex/multi-faceted | `:hybrid` | "How do teams connect to projects?" |

## Performance Tips

1. **Batch extraction** - Use `extract_batch/2` with concurrency
2. **Limit traversal depth** - Default depth of 2 balances breadth/performance
3. **Type filtering** - Filter vector search by entity type when possible
4. **Adjust weights** - Tune local/global weights for your use case
5. **Index properly** - Ensure vector and type indexes exist

## Next Steps

- [Retrievers](retrievers.md) - Other retrieval strategies
- [Pipeline](pipelines.md) - Integrate GraphRAG in workflows
- [Agent Framework](agent_framework.md) - Use with agents
