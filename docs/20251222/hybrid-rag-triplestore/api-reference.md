# API Reference: Rag.GraphStore.TripleStore

## Module Overview

`Rag.GraphStore.TripleStore` implements the `Rag.GraphStore` behaviour using RocksDB as the storage backend. It adapts the RDF Triple model to the Property Graph API expected by rag_ex.

## Types

```elixir
@type t :: %Rag.GraphStore.TripleStore{
  db: reference(),
  manager: GenServer.server(),
  data_dir: String.t(),
  vector_store: struct() | nil
}

@type graph_node :: %{
  id: term(),
  type: atom() | String.t(),
  name: String.t(),
  properties: map(),
  embedding: [float()] | nil,
  source_chunk_ids: [term()]
}

@type edge :: %{
  id: term(),
  from_id: term(),
  to_id: term(),
  type: atom() | String.t(),
  weight: float(),
  properties: map()
}

@type community :: %{
  id: term(),
  level: non_neg_integer(),
  summary: String.t() | nil,
  entity_ids: [term()]
}
```

## Store Lifecycle

### open/1

Opens a TripleStore at the specified data directory.

```elixir
@spec open(keyword()) :: {:ok, t()} | {:error, term()}
```

**Options:**
- `:data_dir` (required) - Path to RocksDB data directory
- `:vector_store` (optional) - VectorStore instance for hybrid search

**Examples:**

```elixir
# Basic usage
{:ok, store} = Rag.GraphStore.TripleStore.open(data_dir: "data/knowledge_graph")

# With VectorStore for hybrid search
vector_store = %Rag.VectorStore.Pgvector{repo: MyApp.Repo}
{:ok, store} = Rag.GraphStore.TripleStore.open(
  data_dir: "data/knowledge_graph",
  vector_store: vector_store
)
```

**Errors:**
- `{:error, :invalid_path}` - Data directory path is invalid
- `{:error, :rocksdb_open_failed}` - RocksDB failed to open

### close/1

Closes the TripleStore and releases resources.

```elixir
@spec close(t()) :: :ok
```

**Example:**

```elixir
:ok = Rag.GraphStore.TripleStore.close(store)
```

## Node Operations

### create_node/2

Creates a new graph node/entity.

```elixir
@spec create_node(t(), map()) :: {:ok, graph_node()} | {:error, term()}
```

**Required Attributes:**
- `:type` - Entity type (atom or string)
- `:name` - Entity name (string)

**Optional Attributes:**
- `:properties` - Map of additional properties (default: `%{}`)
- `:embedding` - Vector embedding for similarity search
- `:source_chunk_ids` - List of source chunk IDs

**Examples:**

```elixir
# Basic entity
{:ok, node} = Rag.GraphStore.create_node(store, %{
  type: :function,
  name: "calculate_total"
})

# Entity with properties
{:ok, node} = Rag.GraphStore.create_node(store, %{
  type: :function,
  name: "calculate_total",
  properties: %{
    file: "lib/orders.ex",
    line: 127,
    arity: 2,
    visibility: :public
  },
  source_chunk_ids: [42, 43]
})

# Entity with embedding
embedding = Rag.Router.generate_embeddings(router, ["calculate_total function"])
{:ok, node} = Rag.GraphStore.create_node(store, %{
  type: :function,
  name: "calculate_total",
  embedding: hd(embedding)
})
```

**Errors:**
- `{:error, :type_required}` - Missing `:type` attribute
- `{:error, :name_required}` - Missing `:name` attribute
- `{:error, :storage_error}` - RocksDB write failed

**RDF Representation:**

```turtle
<urn:entity:1> rdf:type <urn:type:function> .
<urn:entity:1> <urn:prop:name> "calculate_total" .
<urn:entity:1> <urn:prop:file> "lib/orders.ex" .
<urn:entity:1> <urn:prop:line> "127"^^xsd:integer .
<urn:entity:1> <urn:meta:source_chunk_ids> "[42, 43]" .
```

### get_node/2

Retrieves a node by ID.

```elixir
@spec get_node(t(), term()) :: {:ok, graph_node()} | {:error, :not_found}
```

**Examples:**

```elixir
{:ok, node} = Rag.GraphStore.get_node(store, 1)
# => %{id: 1, type: :function, name: "calculate_total", properties: %{...}}

{:error, :not_found} = Rag.GraphStore.get_node(store, 999)
```

## Edge Operations

### create_edge/2

Creates an edge/relationship between two nodes.

```elixir
@spec create_edge(t(), map()) :: {:ok, edge()} | {:error, term()}
```

**Required Attributes:**
- `:from_id` - Source entity ID
- `:to_id` - Target entity ID
- `:type` - Relationship type (atom or string)

**Optional Attributes:**
- `:weight` - Edge weight 0.0-1.0 (default: 1.0)
- `:properties` - Map of additional properties (default: `%{}`)

**Examples:**

```elixir
# Basic edge
{:ok, edge} = Rag.GraphStore.create_edge(store, %{
  from_id: 1,
  to_id: 2,
  type: :calls
})

# Edge with weight
{:ok, edge} = Rag.GraphStore.create_edge(store, %{
  from_id: 1,
  to_id: 3,
  type: :depends_on,
  weight: 0.8
})

# Edge with properties
{:ok, edge} = Rag.GraphStore.create_edge(store, %{
  from_id: 1,
  to_id: 4,
  type: :imports,
  properties: %{alias: "Orders"}
})
```

**Errors:**
- `{:error, :from_id_required}` - Missing `:from_id`
- `{:error, :to_id_required}` - Missing `:to_id`
- `{:error, :type_required}` - Missing `:type`
- `{:error, :self_loop_not_allowed}` - `from_id` equals `to_id`
- `{:error, :entity_not_found}` - Source or target entity doesn't exist

**RDF Representation:**

```turtle
# Simple edge
<urn:entity:1> <urn:rel:calls> <urn:entity:2> .

# Edge with properties (reified)
<urn:edge:101> rdf:type rdf:Statement .
<urn:edge:101> rdf:subject <urn:entity:1> .
<urn:edge:101> rdf:predicate <urn:rel:depends_on> .
<urn:edge:101> rdf:object <urn:entity:3> .
<urn:edge:101> <urn:prop:weight> "0.8"^^xsd:double .

<urn:entity:1> <urn:rel:depends_on> <urn:entity:3> .
```

## Traversal Operations

### find_neighbors/3

Finds immediate neighbors of a node.

```elixir
@spec find_neighbors(t(), term(), keyword()) :: {:ok, [graph_node()]} | {:error, term()}
```

**Options:**
- `:direction` - `:in`, `:out`, or `:both` (default: `:both`)
- `:edge_type` - Filter by relationship type (default: all types)
- `:limit` - Maximum results (default: 10)

**Examples:**

```elixir
# All neighbors
{:ok, neighbors} = Rag.GraphStore.find_neighbors(store, 1)

# Outgoing edges only
{:ok, callees} = Rag.GraphStore.find_neighbors(store, 1, direction: :out)

# Incoming edges only
{:ok, callers} = Rag.GraphStore.find_neighbors(store, 1, direction: :in)

# Filter by relationship type
{:ok, dependencies} = Rag.GraphStore.find_neighbors(store, 1,
  direction: :out,
  edge_type: :depends_on
)

# Limit results
{:ok, top_5} = Rag.GraphStore.find_neighbors(store, 1, limit: 5)
```

**Index Usage:**

| Direction | Pattern | Index |
|-----------|---------|-------|
| `:out` | `(S, ?, ?)` | SPO prefix |
| `:in` | `(?, ?, S)` | OSP prefix |
| `:both` | Both patterns | SPO + OSP |

### traverse/3

Performs graph traversal (BFS or DFS) from a starting node.

```elixir
@spec traverse(t(), term(), keyword()) :: {:ok, [graph_node()]} | {:error, term()}
```

**Options:**
- `:algorithm` - `:bfs` or `:dfs` (default: `:bfs`)
- `:max_depth` - Maximum traversal depth (default: 2)
- `:limit` - Maximum results (default: 100)
- `:direction` - `:in`, `:out`, or `:both` (default: `:out`)
- `:edge_type` - Filter by relationship type (default: all types)

**Examples:**

```elixir
# BFS with default depth
{:ok, nodes} = Rag.GraphStore.traverse(store, 1)

# DFS traversal
{:ok, nodes} = Rag.GraphStore.traverse(store, 1, algorithm: :dfs)

# Deep traversal
{:ok, nodes} = Rag.GraphStore.traverse(store, 1, max_depth: 5)

# Follow only specific edge type
{:ok, all_deps} = Rag.GraphStore.traverse(store, 1,
  max_depth: 10,
  edge_type: :depends_on
)
```

**Result Format:**

Each node in the result includes a `:depth` field:

```elixir
[
  %{id: 1, name: "root", type: :function, depth: 0, ...},
  %{id: 2, name: "child1", type: :function, depth: 1, ...},
  %{id: 3, name: "grandchild", type: :module, depth: 2, ...}
]
```

## Vector Search

### vector_search/3

Performs semantic similarity search using embeddings.

```elixir
@spec vector_search(t(), [float()], keyword()) :: {:ok, [graph_node()]} | {:error, term()}
```

**Requirements:**
- Store must be opened with `:vector_store` option

**Options:**
- `:limit` - Maximum results (default: 10)
- `:type` - Filter by entity type

**Examples:**

```elixir
# Generate query embedding
{:ok, [embedding]} = Rag.Router.generate_embeddings(router, ["calculate order total"])

# Search
{:ok, nodes} = Rag.GraphStore.vector_search(store, embedding, limit: 5)

# Filter by type
{:ok, functions} = Rag.GraphStore.vector_search(store, embedding,
  limit: 10,
  type: :function
)
```

**Implementation Note:**

Vector search is delegated to the VectorStore (PostgreSQL/pgvector) because RocksDB doesn't support ANN (Approximate Nearest Neighbor) search. The flow is:

1. Query VectorStore for similar chunks
2. Map chunk IDs to entity IDs via `source_chunk_ids`
3. Return matching graph nodes

**Errors:**
- `{:error, :vector_store_not_configured}` - No VectorStore provided

## Community Operations

### create_community/2

Creates a community (cluster of related entities).

```elixir
@spec create_community(t(), map()) :: {:ok, community()} | {:error, term()}
```

**Required Attributes:**
- `:entity_ids` - List of member entity IDs (non-empty)

**Optional Attributes:**
- `:level` - Hierarchy level (default: 0)
- `:summary` - Community description

**Examples:**

```elixir
# Basic community
{:ok, community} = Rag.GraphStore.create_community(store, %{
  entity_ids: [1, 2, 3, 4]
})

# With summary
{:ok, community} = Rag.GraphStore.create_community(store, %{
  entity_ids: [1, 2, 3, 4],
  level: 1,
  summary: "Core order processing functions"
})
```

**Errors:**
- `{:error, :entity_ids_required}` - Empty or missing `entity_ids`

### get_community_members/2

Retrieves all member nodes of a community.

```elixir
@spec get_community_members(t(), term()) :: {:ok, [graph_node()]} | {:error, :not_found}
```

**Example:**

```elixir
{:ok, members} = Rag.GraphStore.get_community_members(store, 1)
# => [%{id: 1, name: "...", ...}, %{id: 2, name: "...", ...}, ...]
```

### update_community_summary/3

Updates the summary of an existing community.

```elixir
@spec update_community_summary(t(), term(), String.t()) :: {:ok, community()} | {:error, term()}
```

**Example:**

```elixir
{:ok, community} = Rag.GraphStore.update_community_summary(
  store,
  1,
  "Updated summary: Core business logic for order management"
)
```

## URI Utilities

The `Rag.GraphStore.TripleStore.URI` module provides utilities for generating and parsing URIs:

### Generation Functions

```elixir
URI.entity(42)      # => "urn:entity:42"
URI.type(:function) # => "urn:type:function"
URI.rel(:calls)     # => "urn:rel:calls"
URI.prop(:name)     # => "urn:prop:name"
URI.edge(101)       # => "urn:edge:101"
URI.community(7)    # => "urn:community:7"
URI.meta(:has_embedding) # => "urn:meta:has_embedding"
```

### Parsing Functions

```elixir
URI.parse("urn:entity:42")    # => {:ok, {:entity, 42}}
URI.parse("urn:type:function") # => {:ok, {:type, "function"}}
URI.parse("urn:rel:calls")     # => {:ok, {:rel, "calls"}}
URI.parse("unknown:uri")       # => {:error, :unknown_uri_scheme}
```

### Predicate Functions

```elixir
URI.entity?("urn:entity:42")    # => true
URI.relationship?("urn:rel:calls") # => true
URI.property?("urn:prop:name")  # => true
```

## Error Reference

| Error | Description | Resolution |
|-------|-------------|------------|
| `:type_required` | Node missing `:type` | Add type to attributes |
| `:name_required` | Node missing `:name` | Add name to attributes |
| `:from_id_required` | Edge missing `:from_id` | Add source ID |
| `:to_id_required` | Edge missing `:to_id` | Add target ID |
| `:self_loop_not_allowed` | Edge `from_id` == `to_id` | Use different IDs |
| `:entity_not_found` | Referenced entity doesn't exist | Create entity first |
| `:entity_ids_required` | Community missing members | Add entity IDs |
| `:not_found` | Entity/community doesn't exist | Check ID |
| `:vector_store_not_configured` | No VectorStore for search | Provide VectorStore |
| `:storage_error` | RocksDB operation failed | Check disk space, logs |

## Performance Considerations

### Batch Operations

For bulk ingestion, use batch operations:

```elixir
# Instead of multiple create_node calls
nodes = Enum.map(entities, fn e ->
  {:ok, node} = Rag.GraphStore.create_node(store, e)
  node
end)

# Consider implementing batch_create_nodes (TODO)
{:ok, nodes} = Rag.GraphStore.batch_create_nodes(store, entities)
```

### Index Selection

Query performance depends on index selection:

| Query Type | Optimal Index | Complexity |
|------------|---------------|------------|
| Get node properties | SPO | O(log n) per property |
| Outgoing edges | SPO | O(log n) + O(k) |
| Incoming edges | OSP | O(log n) + O(k) |
| Edges by type | POS | O(log n) + O(k) |

Where `n` = total triples, `k` = matching triples.

### Memory Usage

- RocksDB uses LRU block cache (configurable, default 64MB)
- Dictionary caches recently used term ↔ ID mappings
- Increase cache for read-heavy workloads

## Thread Safety

- All operations are thread-safe
- Write operations are serialized through Dictionary.Manager
- Read operations can be concurrent
- Iterator streams should not be shared across processes
