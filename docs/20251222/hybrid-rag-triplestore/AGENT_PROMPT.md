# Agent Prompt: Implement Hybrid RAG TripleStore Integration

## Mission

Implement the complete `Rag.GraphStore.TripleStore` module that adapts the RocksDB-backed TripleStore to the `Rag.GraphStore` behaviour, enabling the "Hybrid RAG" architecture where PostgreSQL handles vector search (Left Brain) and RocksDB handles graph traversal (Right Brain).

## Required Reading

Before starting implementation, read these files in order:

### 1. Documentation (Priority: Critical)

```
./docs/20251222/hybrid-rag-triplestore/README.md
./docs/20251222/hybrid-rag-triplestore/architecture.md
./docs/20251222/hybrid-rag-triplestore/data-model.md
./docs/20251222/hybrid-rag-triplestore/implementation.md
./docs/20251222/hybrid-rag-triplestore/api-reference.md
./docs/20251222/hybrid-rag-triplestore/migration.md
```

### 2. rag_ex Source (Priority: Critical)

```
# Behaviour definition - this is the interface you must implement
./lib/rag/graph_store.ex

# Existing implementation - reference for expected behavior
./lib/rag/graph_store/pgvector.ex

# Data models
./lib/rag/graph_store/entity.ex
./lib/rag/graph_store/edge.ex
./lib/rag/graph_store/community.ex

# Integration points
./lib/rag/retriever/graph.ex
./lib/rag/vector_store.ex
./lib/rag/vector_store/pgvector.ex
```

### 3. triple_store Source (Priority: Critical)

```
# Main API and design docs
./triple_store/README.md
./triple_store/CLAUDE.md

# Core modules you'll use
./triple_store/lib/triple_store.ex
./triple_store/lib/triple_store/dictionary.ex
./triple_store/lib/triple_store/dictionary/manager.ex
./triple_store/lib/triple_store/dictionary/string_to_id.ex
./triple_store/lib/triple_store/dictionary/id_to_string.ex
./triple_store/lib/triple_store/dictionary/sequence_counter.ex
./triple_store/lib/triple_store/index.ex
./triple_store/lib/triple_store/adapter.ex
./triple_store/lib/triple_store/backend/rocksdb/nif.ex
```

### 4. Existing Patterns (Priority: High)

```
# Follow these patterns for consistency
./lib/rag/retriever.ex
./lib/rag/reranker.ex
./lib/rag/chunker.ex

# Existing examples structure
./examples/rag_demo/

# Test patterns
./test/rag/graph_store/pgvector_test.exs
./test/support/
```

### 5. Project Configuration

```
./mix.exs
./README.md
./CHANGELOG.md
./config/config.exs
./config/test.exs
```

## Context

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Rag.GraphStore Behaviour                          │
├─────────────────────────────┬───────────────────────────────────────┤
│  Rag.GraphStore.Pgvector    │  Rag.GraphStore.TripleStore (NEW)     │
│  (PostgreSQL)               │  (RocksDB)                            │
│                             │                                       │
│  - Existing implementation  │  Property Graph → RDF Adapter         │
│  - SQL Recursive CTEs       │         │                             │
│  - pgvector similarity      │         ▼                             │
│                             │  TripleStore.Dictionary               │
│                             │  TripleStore.Index (SPO/POS/OSP)      │
│                             │         │                             │
│                             │         ▼                             │
│                             │  RocksDB (NIF)                        │
└─────────────────────────────┴───────────────────────────────────────┘
```

### Key Design Decisions

1. **Embeddings stay in PostgreSQL** - RocksDB cannot do ANN search
2. **URI Namespace Scheme**:
   - Entities: `urn:entity:{id}`
   - Types: `urn:type:{type}`
   - Relations: `urn:rel:{type}`
   - Properties: `urn:prop:{key}`
   - Edges (reified): `urn:edge:{id}`
   - Communities: `urn:community:{id}`
   - Metadata: `urn:meta:{key}`

3. **Index Selection**:
   - SPO: Outgoing edges, entity properties
   - POS: Type queries, predicate-based filtering
   - OSP: Incoming edges

4. **ID Generation**: Use ETS-based atomic counters for entity/edge/community IDs

## Implementation Instructions

### Phase 1: Module Structure (TDD)

Create the following file structure:

```
lib/rag/graph_store/
├── triple_store.ex              # Main implementation
└── triple_store/
    ├── uri.ex                   # URI generation/parsing
    ├── mapper.ex                # Property Graph ↔ RDF conversion
    ├── traversal.ex             # BFS/DFS algorithms
    └── supervisor.ex            # OTP supervision

test/rag/graph_store/
├── triple_store_test.exs        # Main tests
└── triple_store/
    ├── uri_test.exs
    ├── mapper_test.exs
    └── traversal_test.exs
```

### Phase 2: TDD Workflow

For each module, follow this order:

1. **Write tests first** based on the behaviour specification
2. **Implement minimum code** to pass tests
3. **Refactor** while keeping tests green
4. **Add edge cases** and error handling tests

### Phase 3: Implementation Order

#### Step 1: URI Module (`lib/rag/graph_store/triple_store/uri.ex`)

Test file: `test/rag/graph_store/triple_store/uri_test.exs`

```elixir
defmodule Rag.GraphStore.TripleStore.URITest do
  use ExUnit.Case, async: true

  alias Rag.GraphStore.TripleStore.URI

  describe "generation" do
    test "entity/1 generates entity URI" do
      assert URI.entity(42) == "urn:entity:42"
      assert URI.entity("abc") == "urn:entity:abc"
    end

    test "type/1 generates type URI" do
      assert URI.type(:function) == "urn:type:function"
      assert URI.type("module") == "urn:type:module"
    end

    test "rel/1 generates relationship URI" do
      assert URI.rel(:calls) == "urn:rel:calls"
    end

    test "prop/1 generates property URI" do
      assert URI.prop(:name) == "urn:prop:name"
    end
  end

  describe "parsing" do
    test "parse/1 extracts entity id" do
      assert URI.parse("urn:entity:42") == {:ok, {:entity, 42}}
      assert URI.parse("urn:entity:abc") == {:ok, {:entity, "abc"}}
    end

    test "parse/1 returns error for unknown scheme" do
      assert URI.parse("http://example.com") == {:error, :unknown_uri_scheme}
    end
  end

  describe "predicates" do
    test "entity?/1 identifies entity URIs" do
      assert URI.entity?("urn:entity:1") == true
      assert URI.entity?("urn:type:foo") == false
    end

    test "relationship?/1 identifies relationship URIs" do
      assert URI.relationship?("urn:rel:calls") == true
      assert URI.relationship?("urn:prop:name") == false
    end
  end
end
```

#### Step 2: Mapper Module (`lib/rag/graph_store/triple_store/mapper.ex`)

Test file: `test/rag/graph_store/triple_store/mapper_test.exs`

```elixir
defmodule Rag.GraphStore.TripleStore.MapperTest do
  use ExUnit.Case, async: true

  alias Rag.GraphStore.TripleStore.Mapper

  describe "node_to_triples/2" do
    test "converts basic node to RDF triples" do
      attrs = %{type: :function, name: "foo"}
      triples = Mapper.node_to_triples(attrs, 1)

      assert length(triples) >= 2
      # Verify type triple exists
      # Verify name triple exists
    end

    test "converts properties to triples" do
      attrs = %{
        type: :function,
        name: "foo",
        properties: %{file: "lib/foo.ex", line: 42}
      }
      triples = Mapper.node_to_triples(attrs, 1)

      # Verify property triples
    end

    test "handles source_chunk_ids" do
      attrs = %{type: :function, name: "foo", source_chunk_ids: [1, 2, 3]}
      triples = Mapper.node_to_triples(attrs, 1)

      # Verify source_chunk_ids serialized as JSON
    end
  end

  describe "edge_to_triples/2" do
    test "converts simple edge to single triple" do
      attrs = %{from_id: 1, to_id: 2, type: :calls}
      triples = Mapper.edge_to_triples(attrs, 100)

      assert length(triples) == 1
    end

    test "converts edge with properties to reified triples" do
      attrs = %{
        from_id: 1,
        to_id: 2,
        type: :depends_on,
        weight: 0.8,
        properties: %{optional: true}
      }
      triples = Mapper.edge_to_triples(attrs, 100)

      # Should have reified representation
      assert length(triples) > 1
    end
  end

  describe "triples_to_node/2" do
    test "reconstructs node from triples" do
      # Create triples, convert back to node, verify fields match
    end
  end
end
```

#### Step 3: Traversal Module (`lib/rag/graph_store/triple_store/traversal.ex`)

Test file: `test/rag/graph_store/triple_store/traversal_test.exs`

```elixir
defmodule Rag.GraphStore.TripleStore.TraversalTest do
  use ExUnit.Case

  alias Rag.GraphStore.TripleStore.Traversal

  # These tests require a running TripleStore instance
  # Use setup to create a temporary RocksDB directory

  setup do
    data_dir = System.tmp_dir!() <> "/traversal_test_#{System.unique_integer([:positive])}"
    File.mkdir_p!(data_dir)

    {:ok, db} = TripleStore.Backend.RocksDB.Nif.open(data_dir)
    {:ok, manager} = TripleStore.Dictionary.Manager.start_link(db: db)

    on_exit(fn ->
      TripleStore.Dictionary.Manager.stop(manager)
      TripleStore.Backend.RocksDB.Nif.close(db)
      File.rm_rf!(data_dir)
    end)

    %{db: db, manager: manager, data_dir: data_dir}
  end

  describe "bfs/4" do
    test "returns start node at depth 0", %{db: db} do
      # Insert test data, run BFS, verify results
    end

    test "finds neighbors at depth 1", %{db: db} do
      # Create A -> B -> C, verify BFS from A finds B at depth 1
    end

    test "respects max_depth", %{db: db} do
      # Create deep chain, verify traversal stops at max_depth
    end
  end

  describe "dfs/4" do
    test "explores depth-first", %{db: db} do
      # Verify DFS ordering differs from BFS
    end
  end

  describe "get_neighbors/4" do
    test "finds outgoing neighbors", %{db: db} do
      # Create A -> B, A -> C, verify get_neighbors(:out) returns [B, C]
    end

    test "finds incoming neighbors", %{db: db} do
      # Create B -> A, C -> A, verify get_neighbors(:in) returns [B, C]
    end

    test "filters by edge type", %{db: db} do
      # Create A -calls-> B, A -imports-> C
      # Verify filtering by :calls returns only B
    end
  end
end
```

#### Step 4: Main Module (`lib/rag/graph_store/triple_store.ex`)

Test file: `test/rag/graph_store/triple_store_test.exs`

```elixir
defmodule Rag.GraphStore.TripleStoreTest do
  use ExUnit.Case

  alias Rag.GraphStore.TripleStore

  setup do
    data_dir = System.tmp_dir!() <> "/triplestore_test_#{System.unique_integer([:positive])}"

    {:ok, store} = TripleStore.open(data_dir: data_dir)

    on_exit(fn ->
      TripleStore.close(store)
      File.rm_rf!(data_dir)
    end)

    %{store: store}
  end

  describe "create_node/2" do
    test "creates node with required fields", %{store: store} do
      {:ok, node} = Rag.GraphStore.create_node(store, %{
        type: :function,
        name: "calculate_total"
      })

      assert node.id != nil
      assert node.type == :function
      assert node.name == "calculate_total"
    end

    test "stores properties", %{store: store} do
      {:ok, node} = Rag.GraphStore.create_node(store, %{
        type: :function,
        name: "foo",
        properties: %{file: "lib/foo.ex", line: 42}
      })

      assert node.properties.file == "lib/foo.ex"
      assert node.properties.line == 42
    end

    test "returns error without type", %{store: store} do
      assert {:error, :type_required} =
        Rag.GraphStore.create_node(store, %{name: "foo"})
    end

    test "returns error without name", %{store: store} do
      assert {:error, :name_required} =
        Rag.GraphStore.create_node(store, %{type: :function})
    end
  end

  describe "get_node/2" do
    test "retrieves existing node", %{store: store} do
      {:ok, created} = Rag.GraphStore.create_node(store, %{
        type: :function,
        name: "foo"
      })

      {:ok, retrieved} = Rag.GraphStore.get_node(store, created.id)

      assert retrieved.id == created.id
      assert retrieved.name == created.name
      assert retrieved.type == created.type
    end

    test "returns error for non-existent node", %{store: store} do
      assert {:error, :not_found} = Rag.GraphStore.get_node(store, 99999)
    end
  end

  describe "create_edge/2" do
    test "creates edge between existing nodes", %{store: store} do
      {:ok, from} = Rag.GraphStore.create_node(store, %{type: :function, name: "a"})
      {:ok, to} = Rag.GraphStore.create_node(store, %{type: :function, name: "b"})

      {:ok, edge} = Rag.GraphStore.create_edge(store, %{
        from_id: from.id,
        to_id: to.id,
        type: :calls
      })

      assert edge.from_id == from.id
      assert edge.to_id == to.id
      assert edge.type == :calls
    end

    test "returns error for self-loop", %{store: store} do
      {:ok, node} = Rag.GraphStore.create_node(store, %{type: :function, name: "a"})

      assert {:error, :self_loop_not_allowed} =
        Rag.GraphStore.create_edge(store, %{
          from_id: node.id,
          to_id: node.id,
          type: :calls
        })
    end

    test "returns error for non-existent from node", %{store: store} do
      {:ok, to} = Rag.GraphStore.create_node(store, %{type: :function, name: "b"})

      assert {:error, :entity_not_found} =
        Rag.GraphStore.create_edge(store, %{
          from_id: 99999,
          to_id: to.id,
          type: :calls
        })
    end
  end

  describe "find_neighbors/3" do
    setup %{store: store} do
      # Create a small graph: A -> B -> C, A -> D
      {:ok, a} = Rag.GraphStore.create_node(store, %{type: :function, name: "a"})
      {:ok, b} = Rag.GraphStore.create_node(store, %{type: :function, name: "b"})
      {:ok, c} = Rag.GraphStore.create_node(store, %{type: :function, name: "c"})
      {:ok, d} = Rag.GraphStore.create_node(store, %{type: :module, name: "d"})

      Rag.GraphStore.create_edge(store, %{from_id: a.id, to_id: b.id, type: :calls})
      Rag.GraphStore.create_edge(store, %{from_id: b.id, to_id: c.id, type: :calls})
      Rag.GraphStore.create_edge(store, %{from_id: a.id, to_id: d.id, type: :imports})

      %{a: a, b: b, c: c, d: d}
    end

    test "finds outgoing neighbors", %{store: store, a: a, b: b, d: d} do
      {:ok, neighbors} = Rag.GraphStore.find_neighbors(store, a.id, direction: :out)

      neighbor_ids = Enum.map(neighbors, & &1.id) |> Enum.sort()
      assert neighbor_ids == Enum.sort([b.id, d.id])
    end

    test "finds incoming neighbors", %{store: store, a: a, b: b} do
      {:ok, neighbors} = Rag.GraphStore.find_neighbors(store, b.id, direction: :in)

      assert length(neighbors) == 1
      assert hd(neighbors).id == a.id
    end

    test "filters by edge type", %{store: store, a: a, b: b} do
      {:ok, neighbors} = Rag.GraphStore.find_neighbors(store, a.id,
        direction: :out,
        edge_type: :calls
      )

      assert length(neighbors) == 1
      assert hd(neighbors).id == b.id
    end

    test "respects limit", %{store: store, a: a} do
      {:ok, neighbors} = Rag.GraphStore.find_neighbors(store, a.id,
        direction: :out,
        limit: 1
      )

      assert length(neighbors) == 1
    end
  end

  describe "traverse/3" do
    setup %{store: store} do
      # Create chain: A -> B -> C -> D
      {:ok, a} = Rag.GraphStore.create_node(store, %{type: :function, name: "a"})
      {:ok, b} = Rag.GraphStore.create_node(store, %{type: :function, name: "b"})
      {:ok, c} = Rag.GraphStore.create_node(store, %{type: :function, name: "c"})
      {:ok, d} = Rag.GraphStore.create_node(store, %{type: :function, name: "d"})

      Rag.GraphStore.create_edge(store, %{from_id: a.id, to_id: b.id, type: :calls})
      Rag.GraphStore.create_edge(store, %{from_id: b.id, to_id: c.id, type: :calls})
      Rag.GraphStore.create_edge(store, %{from_id: c.id, to_id: d.id, type: :calls})

      %{a: a, b: b, c: c, d: d}
    end

    test "BFS respects max_depth", %{store: store, a: a, b: b, c: c} do
      {:ok, nodes} = Rag.GraphStore.traverse(store, a.id,
        algorithm: :bfs,
        max_depth: 2
      )

      node_ids = Enum.map(nodes, & &1.id)
      assert a.id in node_ids
      assert b.id in node_ids
      assert c.id in node_ids
    end

    test "includes depth in results", %{store: store, a: a} do
      {:ok, nodes} = Rag.GraphStore.traverse(store, a.id, max_depth: 1)

      start_node = Enum.find(nodes, & &1.id == a.id)
      assert start_node.depth == 0
    end
  end

  describe "community operations" do
    test "create_community/2 creates community", %{store: store} do
      {:ok, n1} = Rag.GraphStore.create_node(store, %{type: :function, name: "a"})
      {:ok, n2} = Rag.GraphStore.create_node(store, %{type: :function, name: "b"})

      {:ok, community} = Rag.GraphStore.create_community(store, %{
        entity_ids: [n1.id, n2.id],
        level: 1,
        summary: "Test community"
      })

      assert community.entity_ids == [n1.id, n2.id]
      assert community.level == 1
      assert community.summary == "Test community"
    end

    test "get_community_members/2 returns member nodes", %{store: store} do
      {:ok, n1} = Rag.GraphStore.create_node(store, %{type: :function, name: "a"})
      {:ok, n2} = Rag.GraphStore.create_node(store, %{type: :function, name: "b"})

      {:ok, community} = Rag.GraphStore.create_community(store, %{
        entity_ids: [n1.id, n2.id]
      })

      {:ok, members} = Rag.GraphStore.get_community_members(store, community.id)

      member_ids = Enum.map(members, & &1.id) |> Enum.sort()
      assert member_ids == Enum.sort([n1.id, n2.id])
    end

    test "update_community_summary/3 updates summary", %{store: store} do
      {:ok, n1} = Rag.GraphStore.create_node(store, %{type: :function, name: "a"})

      {:ok, community} = Rag.GraphStore.create_community(store, %{
        entity_ids: [n1.id]
      })

      {:ok, updated} = Rag.GraphStore.update_community_summary(
        store,
        community.id,
        "Updated summary"
      )

      assert updated.summary == "Updated summary"
    end
  end
end
```

#### Step 5: Supervisor Module (`lib/rag/graph_store/triple_store/supervisor.ex`)

Implement OTP supervision tree for the TripleStore processes.

### Phase 4: Examples

Create working examples in `./examples/`:

#### `examples/triple_store_demo/`

```
examples/triple_store_demo/
├── mix.exs
├── lib/
│   └── triple_store_demo.ex
├── priv/
│   └── sample_data.json
└── README.md
```

**mix.exs:**
```elixir
defmodule TripleStoreDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :triple_store_demo,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [{:rag, path: "../.."}]
  end
end
```

**lib/triple_store_demo.ex:**
```elixir
defmodule TripleStoreDemo do
  @moduledoc """
  Demonstrates Rag.GraphStore.TripleStore usage.
  """

  alias Rag.GraphStore.TripleStore

  def run do
    IO.puts("=== TripleStore Demo ===\n")

    # Open store
    data_dir = "priv/demo_graph"
    File.mkdir_p!(data_dir)

    IO.puts("Opening TripleStore at #{data_dir}...")
    {:ok, store} = TripleStore.open(data_dir: data_dir)

    # Create nodes
    IO.puts("\nCreating nodes...")
    {:ok, mod} = Rag.GraphStore.create_node(store, %{
      type: :module,
      name: "Orders",
      properties: %{file: "lib/orders.ex"}
    })
    IO.puts("  Created module: #{mod.name} (id: #{mod.id})")

    {:ok, fn1} = Rag.GraphStore.create_node(store, %{
      type: :function,
      name: "calculate_total",
      properties: %{arity: 1, visibility: :public}
    })
    IO.puts("  Created function: #{fn1.name} (id: #{fn1.id})")

    {:ok, fn2} = Rag.GraphStore.create_node(store, %{
      type: :function,
      name: "apply_discount",
      properties: %{arity: 2, visibility: :private}
    })
    IO.puts("  Created function: #{fn2.name} (id: #{fn2.id})")

    # Create edges
    IO.puts("\nCreating edges...")
    {:ok, _} = Rag.GraphStore.create_edge(store, %{
      from_id: mod.id,
      to_id: fn1.id,
      type: :defines
    })
    IO.puts("  #{mod.name} -defines-> #{fn1.name}")

    {:ok, _} = Rag.GraphStore.create_edge(store, %{
      from_id: mod.id,
      to_id: fn2.id,
      type: :defines
    })
    IO.puts("  #{mod.name} -defines-> #{fn2.name}")

    {:ok, _} = Rag.GraphStore.create_edge(store, %{
      from_id: fn1.id,
      to_id: fn2.id,
      type: :calls
    })
    IO.puts("  #{fn1.name} -calls-> #{fn2.name}")

    # Query neighbors
    IO.puts("\nQuerying neighbors of #{mod.name}...")
    {:ok, neighbors} = Rag.GraphStore.find_neighbors(store, mod.id, direction: :out)
    Enum.each(neighbors, fn n ->
      IO.puts("  -> #{n.name} (#{n.type})")
    end)

    # Traverse graph
    IO.puts("\nTraversing from #{mod.name} (depth: 2)...")
    {:ok, nodes} = Rag.GraphStore.traverse(store, mod.id, max_depth: 2)
    Enum.each(nodes, fn n ->
      IO.puts("  [depth #{n.depth}] #{n.name} (#{n.type})")
    end)

    # Create community
    IO.puts("\nCreating community...")
    {:ok, community} = Rag.GraphStore.create_community(store, %{
      entity_ids: [mod.id, fn1.id, fn2.id],
      level: 0,
      summary: "Order processing module and functions"
    })
    IO.puts("  Community #{community.id}: #{community.summary}")

    # Cleanup
    IO.puts("\nClosing store...")
    TripleStore.close(store)

    IO.puts("\n=== Demo Complete ===")
  end
end
```

#### `examples/run_all.sh`

```bash
#!/bin/bash
set -e

echo "Running all rag_ex examples..."
echo ""

# TripleStore Demo
echo "=== Running TripleStore Demo ==="
cd triple_store_demo
mix deps.get
mix run -e "TripleStoreDemo.run()"
cd ..

# Add other examples here as they are created
# echo "=== Running RAG Demo ==="
# cd rag_demo
# mix run -e "RagDemo.run()"
# cd ..

echo ""
echo "All examples completed successfully!"
```

#### `examples/README.md`

```markdown
# rag_ex Examples

This directory contains working examples demonstrating rag_ex features.

## Examples

| Example | Description |
|---------|-------------|
| [triple_store_demo](./triple_store_demo/) | Demonstrates TripleStore-backed GraphStore |
| [rag_demo](./rag_demo/) | Full RAG pipeline with vector search |

## Running Examples

### All Examples

```bash
./run_all.sh
```

### Individual Examples

```bash
cd triple_store_demo
mix deps.get
mix run -e "TripleStoreDemo.run()"
```

## Prerequisites

- Elixir 1.15+
- Rust toolchain (for TripleStore NIF)
- PostgreSQL (for rag_demo vector search)
```

### Phase 5: Documentation Updates

#### Update `README.md`

Add section on TripleStore:

```markdown
## Graph Storage Backends

rag_ex supports multiple graph storage backends:

### PostgreSQL (Pgvector)

The default backend using PostgreSQL with pgvector for both graph storage and vector similarity search.

```elixir
store = %Rag.GraphStore.Pgvector{repo: MyApp.Repo}
```

### RocksDB (TripleStore) - NEW in v0.4.0

High-performance graph backend using RocksDB with RDF triple storage. Ideal for large graphs requiring fast traversal.

```elixir
{:ok, store} = Rag.GraphStore.TripleStore.open(data_dir: "data/graph")
```

See [Hybrid RAG Architecture](docs/20251222/hybrid-rag-triplestore/README.md) for details.
```

#### Update `CHANGELOG.md`

```markdown
## [0.4.0] - 2025-12-22

### Added
- `Rag.GraphStore.TripleStore` - RocksDB-backed graph storage using RDF triples
- Hybrid RAG architecture support (PostgreSQL vectors + RocksDB graph)
- `Rag.GraphStore.TripleStore.URI` - URI generation and parsing utilities
- `Rag.GraphStore.TripleStore.Mapper` - Property Graph to RDF conversion
- `Rag.GraphStore.TripleStore.Traversal` - BFS/DFS graph algorithms
- `Rag.GraphStore.TripleStore.Supervisor` - OTP supervision
- Triple store demo in examples/
- Comprehensive documentation for Hybrid RAG integration

### Changed
- Bumped version to 0.4.0

### Documentation
- Added docs/20251222/hybrid-rag-triplestore/ with complete integration guide
```

#### Update `mix.exs`

```elixir
def project do
  [
    app: :rag,
    version: "0.4.0",  # Updated
    # ...
    docs: [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        # Add new docs
        "docs/20251222/hybrid-rag-triplestore/README.md",
        "docs/20251222/hybrid-rag-triplestore/architecture.md",
        "docs/20251222/hybrid-rag-triplestore/data-model.md",
        "docs/20251222/hybrid-rag-triplestore/implementation.md",
        "docs/20251222/hybrid-rag-triplestore/api-reference.md",
        "docs/20251222/hybrid-rag-triplestore/migration.md"
      ],
      groups_for_extras: [
        "Guides": ~r/docs/
      ]
    ]
  ]
end
```

### Phase 6: Quality Assurance

#### Run All Checks

```bash
# Format code
mix format

# Run tests
mix test

# Check for warnings
mix compile --warnings-as-errors

# Run Dialyzer
mix dialyzer

# Run Credo
mix credo --strict
```

#### Fix Common Issues

1. **Dialyzer specs**: Ensure all public functions have @spec
2. **Unused variables**: Prefix with underscore
3. **Module attributes**: Use @moduledoc for all modules
4. **Test coverage**: Aim for >80% coverage on new code

### Phase 7: Final Verification

1. All tests pass: `mix test`
2. No warnings: `mix compile --warnings-as-errors`
3. Dialyzer clean: `mix dialyzer`
4. Credo clean: `mix credo --strict`
5. Examples run: `cd examples && ./run_all.sh`
6. Version bumped in:
   - `mix.exs` → `0.4.0`
   - `README.md` → mentions 0.4.0
   - `CHANGELOG.md` → has 0.4.0 section dated 2025-12-22

## Success Criteria

- [ ] All 8 GraphStore behaviour callbacks implemented
- [ ] All tests passing (100+ new tests expected)
- [ ] No compiler warnings
- [ ] No Dialyzer errors
- [ ] No Credo issues (strict mode)
- [ ] Working example in `examples/triple_store_demo/`
- [ ] `examples/run_all.sh` executes successfully
- [ ] `examples/README.md` documents all examples
- [ ] Main `README.md` updated with TripleStore section
- [ ] `CHANGELOG.md` has 0.4.0 entry dated 2025-12-22
- [ ] Version 0.4.0 in `mix.exs`
- [ ] All docs in `docs/20251222/` are accurate
- [ ] Docs added to `mix.exs` extras

## Notes for Agent

1. **Use RDF library**: Import `RDF` for creating IRIs and literals
2. **Handle inline encoding**: TripleStore.Dictionary handles integers/decimals/datetimes inline
3. **Test isolation**: Each test should create its own RocksDB directory
4. **Cleanup**: Always close store and remove temp directories in test cleanup
5. **Error handling**: Return tagged tuples consistently
6. **Type safety**: Add @spec to all public functions
7. **Documentation**: Add @doc to all public functions

## Commands Reference

```bash
# Run specific test file
mix test test/rag/graph_store/triple_store_test.exs

# Run with coverage
mix test --cover

# Generate docs
mix docs

# Check everything
mix format && mix compile --warnings-as-errors && mix test && mix dialyzer && mix credo --strict
```
