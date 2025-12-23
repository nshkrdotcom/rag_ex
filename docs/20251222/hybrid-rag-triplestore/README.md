# Hybrid RAG: TripleStore Integration

## Overview

This documentation describes the integration of RocksDB-backed TripleStore as the knowledge graph backend for rag_ex, replacing the Postgres-based GraphStore implementation. This architecture splits the "Brain" of the RAG system into two specialized storage engines:

- **Left Brain (VectorStore)**: PostgreSQL with `pgvector` for fuzzy matching, semantic search, and finding entry points (Chunks)
- **Right Brain (GraphStore)**: RocksDB with `triple_store` for strict logic, structural dependencies, graph traversal, and reasoning

## Goals

1. **Performance**: O(log n) graph traversals via RocksDB's LSM-tree indices vs. SQL recursive CTEs
2. **Flexibility**: RDF triple model enables dynamic properties without schema migrations
3. **Reasoning**: OWL 2 RL inference capabilities for automatic relationship derivation
4. **Precision**: Hybrid search combining semantic similarity with logical graph traversal

## Quick Start

```elixir
# Configuration
config :rag, Rag.GraphStore,
  impl: Rag.GraphStore.TripleStore,
  data_dir: "data/knowledge_graph"

# Usage remains identical to existing GraphStore API
store = %Rag.GraphStore.TripleStore{data_dir: "data/knowledge_graph"}

{:ok, node} = Rag.GraphStore.create_node(store, %{
  type: :function,
  name: "calculate_total",
  properties: %{file: "lib/orders.ex", line: 42}
})

{:ok, neighbors} = Rag.GraphStore.find_neighbors(store, node.id, direction: :out)
```

## Documents

| Document | Description |
|----------|-------------|
| [Architecture](architecture.md) | System design, component interactions, data flow |
| [Data Model](data-model.md) | Property Graph to RDF Triple mapping schema |
| [Implementation](implementation.md) | Step-by-step implementation guide |
| [API Reference](api-reference.md) | Complete API documentation with examples |
| [Migration](migration.md) | Strategy for migrating from Postgres GraphStore |

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Application Layer                            │
│                    (Rag.Retriever.Graph, Pipeline)                   │
├─────────────────────────────────────────────────────────────────────┤
│         Rag.GraphStore Behaviour (Unified API)                       │
├────────────────────────┬────────────────────────────────────────────┤
│  Rag.GraphStore.       │  Rag.GraphStore.TripleStore               │
│  Pgvector (Legacy)     │  (New Implementation)                      │
│                        │                                             │
│  PostgreSQL            │  Property Graph → RDF Adapter               │
│  Recursive CTEs        │         │                                   │
│                        │         ▼                                   │
│                        │  TripleStore.Dictionary (ID Encoding)       │
│                        │  TripleStore.Index (SPO/POS/OSP)            │
│                        │         │                                   │
│                        │         ▼                                   │
│                        │  RocksDB (NIF)                              │
└────────────────────────┴────────────────────────────────────────────┘
```

## Key Concepts

### Property Graph to RDF Mapping

| Property Graph | RDF Triple |
|----------------|------------|
| Node ID | `urn:entity:{id}` (Subject IRI) |
| Node Type | `<S> rdf:type <urn:type:{type}>` |
| Node Property | `<S> <urn:prop:{key}> "value"` |
| Edge | `<S> <urn:rel:{type}> <O>` |
| Edge Property | Reified triple with properties |

### Storage Architecture

- **Dictionary**: Maps RDF terms ↔ 64-bit integer IDs with type tagging
- **SPO Index**: Subject-Predicate-Object order for outgoing traversal
- **POS Index**: Predicate-Object-Subject order for type queries
- **OSP Index**: Object-Subject-Predicate order for incoming traversal

## Changes from Current Implementation

| Aspect | Current (Pgvector) | New (TripleStore) |
|--------|-------------------|-------------------|
| Storage | PostgreSQL tables | RocksDB column families |
| Traversal | SQL Recursive CTEs | Elixir/Rust iterators |
| Schema | Fixed Ecto schemas | Flexible RDF triples |
| Vector Search | pgvector L2 distance | Delegated to VectorStore |
| Properties | JSONB column | Individual triples per property |

## File Structure

```
lib/rag/
├── graph_store.ex                      # Behaviour (unchanged)
└── graph_store/
    ├── pgvector.ex                     # Existing implementation
    ├── triple_store.ex                 # NEW: TripleStore adapter
    ├── triple_store/
    │   ├── uri.ex                      # URI generation utilities
    │   ├── mapper.ex                   # Property Graph ↔ RDF conversion
    │   └── traversal.ex                # BFS/DFS implementations
    ├── entity.ex                       # Ecto schema (unchanged)
    ├── edge.ex                         # Ecto schema (unchanged)
    └── community.ex                    # Ecto schema (unchanged)
```

## Prerequisites

- Elixir 1.15+
- Rust toolchain (for NIF compilation)
- `triple_store` dependency added to mix.exs

## Status

| Component | Status |
|-----------|--------|
| TripleStore Storage Foundation | Complete |
| Property Graph Adapter | To Be Implemented |
| SPARQL Query Engine | Planned (Phase 2) |
| OWL 2 RL Reasoning | Planned (Phase 4) |
