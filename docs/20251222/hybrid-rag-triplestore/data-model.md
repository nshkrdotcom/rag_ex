# Data Model: Property Graph to RDF Mapping

## Overview

This document defines the mapping schema between the Property Graph model expected by `Rag.GraphStore` and the RDF Triple model used by `TripleStore`. The mapping preserves all semantics while enabling efficient RocksDB storage and traversal.

## Namespace Definitions

All URIs follow a consistent namespace scheme:

| Prefix | Namespace | Purpose |
|--------|-----------|---------|
| `entity:` | `urn:entity:` | Graph node/entity identifiers |
| `type:` | `urn:type:` | Entity type classification |
| `rel:` | `urn:rel:` | Relationship/edge types |
| `prop:` | `urn:prop:` | Node property keys |
| `edge:` | `urn:edge:` | Reified edge identifiers |
| `meta:` | `urn:meta:` | System metadata |
| `rdf:` | `http://www.w3.org/1999/02/22-rdf-syntax-ns#` | RDF vocabulary |

## Node Mapping

### Property Graph Node Structure

```elixir
%{
  id: 42,
  type: :function,
  name: "calculate_total",
  properties: %{
    file: "lib/orders.ex",
    line: 127,
    deprecated: false,
    description: "Calculates order total with tax"
  },
  embedding: [0.1, 0.2, ...],  # 768-dim vector
  source_chunk_ids: [1, 5, 12]
}
```

### RDF Triple Representation

```turtle
# Entity Identity
<urn:entity:42> rdf:type <urn:type:function> .

# Core Properties
<urn:entity:42> <urn:prop:name> "calculate_total" .
<urn:entity:42> <urn:prop:file> "lib/orders.ex" .
<urn:entity:42> <urn:prop:line> "127"^^xsd:integer .
<urn:entity:42> <urn:prop:deprecated> "false"^^xsd:boolean .
<urn:entity:42> <urn:prop:description> "Calculates order total with tax" .

# Source Chunk References (serialized JSON array)
<urn:entity:42> <urn:meta:source_chunk_ids> "[1, 5, 12]" .

# Embedding Reference (NOT stored in RocksDB)
# Embeddings remain in PostgreSQL for ANN search
<urn:entity:42> <urn:meta:has_embedding> "true"^^xsd:boolean .
```

### Type Mapping Table

| Elixir Type | RDF Literal Type | Encoding |
|-------------|------------------|----------|
| `String.t()` | Plain literal | `"value"` |
| `integer()` | Inline integer | Type tag 0x4 + value |
| `float()` | `xsd:double` string | `"3.14"^^xsd:double` |
| `boolean()` | `xsd:boolean` string | `"true"^^xsd:boolean` |
| `DateTime.t()` | Inline datetime | Type tag 0x6 + epoch ms |
| `Decimal.t()` | Inline decimal | Type tag 0x5 + encoded |
| `map()` | JSON string | `"{\"key\":\"value\"}"` |
| `list()` | JSON array string | `"[1, 2, 3]"` |
| `atom()` | Plain literal | `"atom_name"` |

## Edge Mapping

### Simple Edges (No Properties)

```elixir
# Property Graph Edge
%{
  id: 101,
  from_id: 42,
  to_id: 55,
  type: :calls,
  weight: 0.9,
  properties: %{}
}
```

```turtle
# Direct RDF Triple
<urn:entity:42> <urn:rel:calls> <urn:entity:55> .
```

### Edges with Properties (Reification)

When edges have properties beyond type and weight, use RDF reification:

```elixir
# Property Graph Edge with Properties
%{
  id: 102,
  from_id: 42,
  to_id: 60,
  type: :depends_on,
  weight: 0.75,
  properties: %{
    version: "~> 1.0",
    optional: true
  }
}
```

```turtle
# Reified Edge
<urn:edge:102> rdf:type rdf:Statement .
<urn:edge:102> rdf:subject <urn:entity:42> .
<urn:edge:102> rdf:predicate <urn:rel:depends_on> .
<urn:edge:102> rdf:object <urn:entity:60> .

# Edge Properties
<urn:edge:102> <urn:prop:weight> "0.75"^^xsd:double .
<urn:edge:102> <urn:prop:version> "~> 1.0" .
<urn:edge:102> <urn:prop:optional> "true"^^xsd:boolean .

# Direct triple for efficient traversal
<urn:entity:42> <urn:rel:depends_on> <urn:entity:60> .
```

### Weight Handling Strategy

| Scenario | Approach | Rationale |
|----------|----------|-----------|
| Traversal queries | Ignore weight | Speed: simple prefix scan |
| Ranking results | Include weight | Accuracy: weight affects ordering |
| Simple edges | Skip reification | Efficiency: 1 triple vs 5+ |
| Complex edges | Full reification | Completeness: preserve all data |

**Recommendation**: For the "Right Brain" logic-focused use case, prefer simple triples without weights. Weights are more relevant for semantic similarity (Left Brain).

## Community Mapping

### Property Graph Community

```elixir
%{
  id: 7,
  level: 1,
  summary: "Core business logic functions for order processing",
  entity_ids: [42, 55, 60, 78]
}
```

### RDF Representation

```turtle
# Community Identity
<urn:community:7> rdf:type <urn:type:community> .
<urn:community:7> <urn:prop:level> "1"^^xsd:integer .
<urn:community:7> <urn:prop:summary> "Core business logic functions for order processing" .

# Membership (one triple per member)
<urn:community:7> <urn:rel:has_member> <urn:entity:42> .
<urn:community:7> <urn:rel:has_member> <urn:entity:55> .
<urn:community:7> <urn:rel:has_member> <urn:entity:60> .
<urn:community:7> <urn:rel:has_member> <urn:entity:78> .

# Inverse membership for entity-centric queries
<urn:entity:42> <urn:rel:member_of> <urn:community:7> .
<urn:entity:55> <urn:rel:member_of> <urn:community:7> .
<urn:entity:60> <urn:rel:member_of> <urn:community:7> .
<urn:entity:78> <urn:rel:member_of> <urn:community:7> .
```

## URI Generation

### Entity URIs

```elixir
defmodule Rag.GraphStore.TripleStore.URI do
  @entity_prefix "urn:entity:"
  @type_prefix "urn:type:"
  @rel_prefix "urn:rel:"
  @prop_prefix "urn:prop:"
  @edge_prefix "urn:edge:"
  @community_prefix "urn:community:"
  @meta_prefix "urn:meta:"

  def entity(id), do: @entity_prefix <> to_string(id)
  def type(t), do: @type_prefix <> normalize_type(t)
  def rel(r), do: @rel_prefix <> normalize_type(r)
  def prop(p), do: @prop_prefix <> to_string(p)
  def edge(id), do: @edge_prefix <> to_string(id)
  def community(id), do: @community_prefix <> to_string(id)
  def meta(m), do: @meta_prefix <> to_string(m)

  defp normalize_type(t) when is_atom(t), do: Atom.to_string(t)
  defp normalize_type(t) when is_binary(t), do: t

  # Parsing
  def parse_entity(@entity_prefix <> id), do: {:ok, {:entity, parse_id(id)}}
  def parse_entity(@type_prefix <> type), do: {:ok, {:type, type}}
  def parse_entity(@rel_prefix <> rel), do: {:ok, {:rel, rel}}
  def parse_entity(@prop_prefix <> prop), do: {:ok, {:prop, prop}}
  def parse_entity(@edge_prefix <> id), do: {:ok, {:edge, parse_id(id)}}
  def parse_entity(@community_prefix <> id), do: {:ok, {:community, parse_id(id)}}
  def parse_entity(_), do: {:error, :unknown_uri_scheme}

  defp parse_id(str) do
    case Integer.parse(str) do
      {id, ""} -> id
      _ -> str
    end
  end
end
```

## ID Generation Strategy

### Sequence-Based IDs

For new entities, edges, and communities, use the application-level sequence:

```elixir
defmodule Rag.GraphStore.TripleStore.Sequence do
  use GenServer

  @table :triplestore_sequences

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def next_id(type) when type in [:entity, :edge, :community] do
    :ets.update_counter(@table, type, {2, 1}, {type, 0})
  end

  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{}}
  end
end
```

### Dictionary ID Allocation

The TripleStore Dictionary assigns 64-bit IDs to all RDF terms:

| Term Type | ID Range | Allocation |
|-----------|----------|------------|
| URI | `0x1___` (2^59 values) | Sequence-based via str2id |
| BlankNode | `0x2___` (2^59 values) | Sequence-based via str2id |
| Literal | `0x3___` (2^59 values) | Dictionary lookup |
| Integer | `0x4___` (inline) | Direct encoding |
| Decimal | `0x5___` (inline) | Direct encoding |
| DateTime | `0x6___` (inline) | Direct encoding |

## Query Pattern Mapping

### find_neighbors Implementation

```elixir
def find_neighbors(store, node_id, opts) do
  direction = Keyword.get(opts, :direction, :both)
  edge_type = Keyword.get(opts, :edge_type)
  limit = Keyword.get(opts, :limit, 10)

  entity_uri = URI.entity(node_id)
  {:ok, entity_term_id} = lookup_term_id(store.db, entity_uri)

  patterns = case direction do
    :out -> [{{:bound, entity_term_id}, :var, :var}]
    :in -> [{:var, :var, {:bound, entity_term_id}}]
    :both -> [
      {{:bound, entity_term_id}, :var, :var},
      {:var, :var, {:bound, entity_term_id}}
    ]
  end

  patterns
  |> Enum.flat_map(fn pattern ->
    {:ok, stream} = TripleStore.Index.lookup(store.db, pattern)
    stream
    |> filter_relationships(edge_type)
    |> Stream.take(limit)
    |> Enum.to_list()
  end)
  |> extract_neighbor_ids(direction, entity_term_id)
  |> Enum.uniq()
  |> Enum.take(limit)
  |> load_nodes(store)
end

defp filter_relationships(stream, nil), do: stream
defp filter_relationships(stream, edge_type) do
  rel_uri = URI.rel(edge_type)
  {:ok, rel_term_id} = lookup_term_id(store.db, rel_uri)
  Stream.filter(stream, fn {_s, p, _o} -> p == rel_term_id end)
end
```

### traverse Implementation

```elixir
def traverse(store, start_id, opts) do
  algorithm = Keyword.get(opts, :algorithm, :bfs)
  max_depth = Keyword.get(opts, :max_depth, 2)
  limit = Keyword.get(opts, :limit, 100)

  entity_uri = URI.entity(start_id)
  {:ok, start_term_id} = lookup_term_id(store.db, entity_uri)

  result = case algorithm do
    :bfs -> bfs_traverse(store, start_term_id, max_depth)
    :dfs -> dfs_traverse(store, start_term_id, max_depth)
  end

  result
  |> Enum.take(limit)
  |> load_nodes(store)
end

defp bfs_traverse(store, start_id, max_depth) do
  bfs_loop(store, [{start_id, 0}], MapSet.new([start_id]), max_depth, [])
end

defp bfs_loop(_store, [], _visited, _max_depth, acc), do: Enum.reverse(acc)
defp bfs_loop(store, [{current, depth} | queue], visited, max_depth, acc) do
  acc = [{current, depth} | acc]

  if depth >= max_depth do
    bfs_loop(store, queue, visited, max_depth, acc)
  else
    neighbors = get_outgoing_neighbors(store, current)
    {new_queue, new_visited} =
      Enum.reduce(neighbors, {queue, visited}, fn n, {q, v} ->
        if MapSet.member?(v, n) do
          {q, v}
        else
          {q ++ [{n, depth + 1}], MapSet.put(v, n)}
        end
      end)
    bfs_loop(store, new_queue, new_visited, max_depth, acc)
  end
end
```

## Embedding Strategy

Embeddings are **NOT** stored in RocksDB. Instead:

1. **Storage**: Embeddings remain in PostgreSQL `graph_entities.embedding` column
2. **Reference**: A boolean flag `<entity> urn:meta:has_embedding "true"` indicates presence
3. **Search**: `vector_search/3` delegates to `Rag.VectorStore.Pgvector`
4. **Mapping**: Results are mapped back to entity IDs via `source_chunk_ids`

```elixir
def vector_search(store, embedding, opts) do
  # Delegate to VectorStore (Left Brain)
  {:ok, chunks} = Rag.VectorStore.Pgvector.search(
    store.vector_store,
    embedding,
    opts
  )

  # Map chunk IDs to entity IDs
  chunk_ids = Enum.map(chunks, & &1.id)

  # Query entities with matching source_chunk_ids
  pattern = {:var, prop_term_id(:source_chunk_ids), :var}
  {:ok, stream} = TripleStore.Index.lookup(store.db, pattern)

  stream
  |> Stream.filter(fn {_s, _p, o} ->
    stored_ids = Jason.decode!(id_to_term(store.db, o))
    Enum.any?(chunk_ids, &(&1 in stored_ids))
  end)
  |> Stream.map(fn {s, _p, _o} -> s end)
  |> Enum.uniq()
  |> load_nodes(store)
end
```

## Validation Rules

### Node Validation

```elixir
def validate_node_attrs(attrs) do
  with :ok <- validate_required(attrs, [:type, :name]),
       :ok <- validate_type(attrs.type),
       :ok <- validate_name(attrs.name),
       :ok <- validate_properties(attrs[:properties] || %{}) do
    :ok
  end
end

defp validate_type(t) when is_atom(t), do: :ok
defp validate_type(t) when is_binary(t) and byte_size(t) > 0, do: :ok
defp validate_type(_), do: {:error, :invalid_type}

defp validate_name(n) when is_binary(n) and byte_size(n) > 0, do: :ok
defp validate_name(_), do: {:error, :invalid_name}

defp validate_properties(props) when is_map(props), do: :ok
defp validate_properties(_), do: {:error, :invalid_properties}
```

### Edge Validation

```elixir
def validate_edge_attrs(attrs) do
  with :ok <- validate_required(attrs, [:from_id, :to_id, :type]),
       :ok <- validate_id(attrs.from_id),
       :ok <- validate_id(attrs.to_id),
       :ok <- validate_no_self_loop(attrs.from_id, attrs.to_id),
       :ok <- validate_weight(attrs[:weight] || 1.0) do
    :ok
  end
end

defp validate_no_self_loop(id, id), do: {:error, :self_loop_not_allowed}
defp validate_no_self_loop(_, _), do: :ok

defp validate_weight(w) when is_float(w) and w >= 0.0 and w <= 1.0, do: :ok
defp validate_weight(_), do: {:error, :invalid_weight}
```
