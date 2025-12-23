# Architecture: Hybrid RAG with TripleStore

## System Overview

The Hybrid RAG architecture separates concerns between two specialized storage engines, each optimized for different query patterns:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Query Processing                               │
│                                                                          │
│   "What functions call calculate_total and might be affected by         │
│    changes to the Orders module?"                                        │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
┌───────────────────────────────┐   ┌───────────────────────────────────┐
│     LEFT BRAIN (VectorStore)  │   │     RIGHT BRAIN (GraphStore)      │
│                               │   │                                   │
│  • Semantic similarity        │   │  • Structural dependencies        │
│  • Fuzzy matching             │   │  • Logical inference              │
│  • Entry point discovery      │   │  • Graph traversal                │
│                               │   │                                   │
│  PostgreSQL + pgvector        │   │  RocksDB + TripleStore            │
│  L2 distance ANN search       │   │  SPO/POS/OSP prefix scans         │
└───────────────────────────────┘   └───────────────────────────────────┘
                    │                               │
                    └───────────────┬───────────────┘
                                    ▼
                    ┌───────────────────────────────┐
                    │      Hybrid Retriever         │
                    │   (RRF Fusion + Dedup)        │
                    └───────────────────────────────┘
```

## Component Architecture

### Layer 1: Application Interface

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Rag.Retriever.Graph                                                     │
│  ├── local_search(query, opts)     → Vector seed + Graph expansion      │
│  ├── global_search(query, opts)    → Community summary retrieval        │
│  └── hybrid_search(query, opts)    → Weighted RRF fusion                │
├─────────────────────────────────────────────────────────────────────────┤
│  Rag.GraphRAG.Extractor                                                  │
│  └── extract(text, router)         → Entities + Relationships           │
└─────────────────────────────────────────────────────────────────────────┘
```

### Layer 2: Storage Behaviours

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Rag.GraphStore (Behaviour)                                              │
│  ├── create_node/2, get_node/2                                          │
│  ├── create_edge/2                                                       │
│  ├── find_neighbors/3, traverse/3                                        │
│  ├── vector_search/3                                                     │
│  └── create_community/2, get_community_members/2, update_community_summary/3
├─────────────────────────────────────────────────────────────────────────┤
│  Rag.VectorStore.Store (Behaviour)                                       │
│  ├── insert/3, search/3                                                  │
│  ├── delete/3, get/3                                                     │
└─────────────────────────────────────────────────────────────────────────┘
```

### Layer 3: Implementations

```
┌──────────────────────────────┐    ┌──────────────────────────────────────┐
│  Rag.GraphStore.Pgvector     │    │  Rag.GraphStore.TripleStore          │
│  (Legacy - PostgreSQL)       │    │  (New - RocksDB)                     │
│                              │    │                                      │
│  • Ecto.Repo for queries     │    │  TripleStore.Dictionary.Manager      │
│  • Recursive CTEs for BFS    │    │  ├── get_or_create_id/2              │
│  • pgvector for similarity   │    │  └── ID ↔ Term mapping               │
│                              │    │                                      │
│  Tables:                     │    │  TripleStore.Index                   │
│  ├── graph_entities          │    │  ├── insert_triple/2                 │
│  ├── graph_edges             │    │  ├── lookup/2 (pattern matching)     │
│  └── graph_communities       │    │  └── prefix_stream/3                 │
└──────────────────────────────┘    │                                      │
                                    │  RocksDB Column Families:            │
                                    │  ├── id2str, str2id (dictionary)     │
                                    │  ├── spo, pos, osp (indices)         │
                                    │  └── derived (inferred triples)      │
                                    └──────────────────────────────────────┘
```

## Data Flow

### Ingestion Pipeline

```
Document
    │
    ├──► Rag.Chunker.chunk/2
    │         │
    │         ▼
    │    Chunks with byte positions
    │         │
    ├──► Rag.Router.generate_embeddings/2
    │         │
    │         ▼
    │    Chunks with embeddings
    │         │
    ├──► Rag.VectorStore.Pgvector.insert/3    ──────► rag_chunks table
    │
    └──► Rag.GraphRAG.Extractor.extract/2
              │
              ▼
         %{entities: [...], relationships: [...]}
              │
              ├──► Rag.GraphStore.TripleStore.create_node/2
              │         │
              │         ▼
              │    RDF Triples for entity properties
              │    • <urn:entity:1> rdf:type <urn:type:function>
              │    • <urn:entity:1> urn:prop:name "calculate_total"
              │    • <urn:entity:1> urn:prop:file "lib/orders.ex"
              │
              └──► Rag.GraphStore.TripleStore.create_edge/2
                        │
                        ▼
                   RDF Triple for relationship
                   • <urn:entity:1> urn:rel:calls <urn:entity:2>
```

### Retrieval Pipeline

```
Query: "How does calculate_total work?"
    │
    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Step 1: Vector Search (Left Brain Entry Point)                          │
│                                                                          │
│  Rag.VectorStore.Pgvector.search(query_embedding)                        │
│  → [{chunk_id: 42, score: 0.95, content: "def calculate_total..."}]      │
└─────────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Step 2: Map to Graph Entities                                           │
│                                                                          │
│  Lookup entities where source_chunk_ids contains chunk_id                │
│  SELECT ?entity WHERE {                                                  │
│    ?entity urn:prop:source_chunk_ids ?chunks .                           │
│    FILTER(contains(?chunks, "42"))                                       │
│  }                                                                       │
│  → [entity_id: 1 (calculate_total function)]                             │
└─────────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Step 3: Graph Traversal (Right Brain Expansion)                         │
│                                                                          │
│  Rag.GraphStore.TripleStore.traverse(entity_1, depth: 2)                 │
│                                                                          │
│  Pattern: {bound(entity_1), :var, :var} → SPO prefix scan                │
│  → Callers, callees, containing module, related types                    │
└─────────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Step 4: Collect Source Chunks                                           │
│                                                                          │
│  For each discovered entity, get source_chunk_ids                        │
│  Fetch chunk contents from VectorStore                                   │
│  Score by: semantic_similarity × (1 / graph_distance)                    │
└─────────────────────────────────────────────────────────────────────────┘
    │
    ▼
Final Results: Ranked chunks with graph context
```

## Index Selection Strategy

The TripleStore maintains three indices to support all access patterns:

| Pattern | Example Query | Index Used | Operation |
|---------|---------------|------------|-----------|
| `(S, P, O)` | Exact triple existence check | SPO | Point lookup |
| `(S, P, ?)` | All values of property P for entity S | SPO | Prefix scan |
| `(S, ?, ?)` | All outgoing edges from entity S | SPO | Prefix scan |
| `(?, P, O)` | All entities with property P = O | POS | Prefix scan |
| `(?, P, ?)` | All triples with predicate P | POS | Prefix scan |
| `(?, ?, O)` | All incoming edges to entity O | OSP | Prefix scan |
| `(S, ?, O)` | Path between S and O | OSP | Prefix + filter |

### Traversal Implementation

```elixir
# BFS Traversal (formerly SQL Recursive CTE)
defp traverse_bfs(db, start_id, max_depth, visited \\ MapSet.new(), depth \\ 0)

defp traverse_bfs(_db, _start_id, max_depth, visited, depth) when depth >= max_depth do
  MapSet.to_list(visited)
end

defp traverse_bfs(db, start_id, max_depth, visited, depth) do
  if MapSet.member?(visited, start_id) do
    MapSet.to_list(visited)
  else
    visited = MapSet.put(visited, start_id)

    # SPO prefix scan for outgoing edges
    pattern = {{:bound, start_id}, :var, :var}
    {:ok, stream} = TripleStore.Index.lookup(db, pattern)

    neighbors = stream
    |> Stream.map(fn {_s, _p, o} -> o end)
    |> Stream.filter(&entity_id?/1)  # Filter to entity URIs only
    |> Enum.to_list()

    Enum.reduce(neighbors, visited, fn neighbor_id, acc ->
      traverse_bfs(db, neighbor_id, max_depth, acc, depth + 1)
    end)
    |> MapSet.to_list()
  end
end
```

## Supervision Tree Integration

```
MyApp.Application
    │
    ├── MyApp.Repo (Ecto - PostgreSQL)
    │
    ├── Rag.Embedding.Service (GenServer)
    │
    └── TripleStore.Supervisor (NEW)
            │
            ├── TripleStore.Dictionary.Manager
            │   └── Serializes ID creation
            │
            ├── TripleStore.Dictionary.SequenceCounter
            │   └── Atomic ID generation with periodic flush
            │
            └── (Future: Query.PlanCache, Transaction manager)
```

### Application Configuration

```elixir
# config/config.exs
config :rag, Rag.GraphStore,
  impl: Rag.GraphStore.TripleStore,
  data_dir: System.get_env("TRIPLESTORE_DATA_DIR", "data/knowledge_graph")

# lib/my_app/application.ex
def start(_type, _args) do
  triplestore_config = Application.get_env(:rag, Rag.GraphStore)

  children = [
    MyApp.Repo,
    {Rag.Embedding.Service, name: :embedding_service},
    {TripleStore.Supervisor, [
      data_dir: triplestore_config[:data_dir],
      name: :knowledge_graph
    ]}
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

## Performance Characteristics

### RocksDB vs PostgreSQL Comparison

| Operation | PostgreSQL | RocksDB | Advantage |
|-----------|------------|---------|-----------|
| Single edge lookup | ~1ms (index) | ~0.1ms (prefix scan) | 10x faster |
| 2-hop traversal | ~10ms (CTE) | ~1ms (iterative) | 10x faster |
| Deep traversal (5+) | Exponential | Linear in edges | Dramatically better |
| Batch insert | ~50ms/1000 | ~5ms/1000 | 10x faster |
| Schema change | Migration | None needed | Infinite flexibility |
| Vector search | Excellent | N/A (delegated) | PostgreSQL wins |

### Memory & Storage

- **Dictionary overhead**: ~100 bytes per unique term
- **Index overhead**: 72 bytes per triple (24 bytes × 3 indices)
- **Compression**: LZ4 block compression enabled by default
- **Cache**: RocksDB block cache tunable (default: 64MB)

## Error Handling Strategy

```elixir
# All operations return tagged tuples
case Rag.GraphStore.create_node(store, attrs) do
  {:ok, node} ->
    # Success path

  {:error, :validation_failed} ->
    # Invalid attributes

  {:error, :storage_error} ->
    # RocksDB write failure

  {:error, :dictionary_full} ->
    # Sequence counter exhausted (unlikely: 2^59 IDs)
end
```

## Future Enhancements

### Phase 2: SPARQL Integration

```elixir
# Direct SPARQL queries for complex patterns
results = TripleStore.query(store, """
  SELECT ?caller ?callee WHERE {
    ?caller urn:rel:calls ?callee .
    ?callee rdf:type urn:type:function .
    ?callee urn:prop:deprecated "true" .
  }
""")
```

### Phase 4: OWL 2 RL Reasoning

```elixir
# Automatic inference of transitive relationships
TripleStore.materialize(store, profile: :owl2rl)

# Now queries automatically include inferred triples
# e.g., if A depends_on B and B depends_on C,
# then A transitively_depends_on C is automatically available
```
