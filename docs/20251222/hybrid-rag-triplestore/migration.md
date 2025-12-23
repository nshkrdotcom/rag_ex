# Migration Guide: PostgreSQL GraphStore to TripleStore

## Overview

This guide covers migrating existing knowledge graph data from the PostgreSQL-based `Rag.GraphStore.Pgvector` to the RocksDB-based `Rag.GraphStore.TripleStore`.

## Migration Phases

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Phase 1: Parallel Setup (No downtime)                                  │
│  • Deploy TripleStore alongside PostgreSQL                              │
│  • Both stores coexist, PostgreSQL remains primary                      │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Phase 2: Dual Write (No downtime)                                      │
│  • Write to both stores simultaneously                                   │
│  • Read from PostgreSQL                                                  │
│  • Verify data consistency                                              │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Phase 3: Backfill (No downtime)                                        │
│  • Migrate historical data from PostgreSQL to TripleStore               │
│  • Verify completeness                                                   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Phase 4: Shadow Read (No downtime)                                     │
│  • Read from both, compare results                                       │
│  • Log discrepancies                                                     │
│  • Build confidence in TripleStore                                       │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Phase 5: Cutover (Brief maintenance window)                            │
│  • Switch reads to TripleStore                                           │
│  • PostgreSQL GraphStore becomes backup                                  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Phase 6: Cleanup (Optional)                                            │
│  • Remove dual-write logic                                               │
│  • Archive or drop PostgreSQL graph tables                               │
└─────────────────────────────────────────────────────────────────────────┘
```

## Phase 1: Parallel Setup

### 1.1 Add Dependencies

```elixir
# mix.exs
defp deps do
  [
    # Existing dependencies...
    {:triple_store, path: "./triple_store"}
  ]
end
```

### 1.2 Configure TripleStore

```elixir
# config/config.exs
config :rag, :graph_stores, %{
  primary: Rag.GraphStore.Pgvector,
  secondary: Rag.GraphStore.TripleStore
}

config :rag, Rag.GraphStore.TripleStore,
  data_dir: "data/knowledge_graph"
```

### 1.3 Update Supervision Tree

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  triplestore_config = Application.get_env(:rag, Rag.GraphStore.TripleStore)

  children = [
    MyApp.Repo,
    {Rag.GraphStore.TripleStore.Supervisor, [
      data_dir: triplestore_config[:data_dir]
    ]},
    # ... other children
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

## Phase 2: Dual Write

### 2.1 Create Dual-Write Wrapper

```elixir
# lib/rag/graph_store/dual_write.ex
defmodule Rag.GraphStore.DualWrite do
  @moduledoc """
  Writes to both PostgreSQL and TripleStore during migration.
  Reads from primary (PostgreSQL) only.
  """

  @behaviour Rag.GraphStore

  defstruct [:primary, :secondary]

  def new(primary_store, secondary_store) do
    %__MODULE__{
      primary: primary_store,
      secondary: secondary_store
    }
  end

  # Node Operations

  @impl true
  def create_node(%{primary: primary, secondary: secondary}, attrs) do
    # Write to primary first
    case Rag.GraphStore.create_node(primary, attrs) do
      {:ok, node} ->
        # Async write to secondary (fire and forget during migration)
        Task.start(fn ->
          case Rag.GraphStore.create_node(secondary, Map.put(attrs, :id, node.id)) do
            {:ok, _} -> :ok
            {:error, reason} ->
              Logger.warning("Secondary write failed: #{inspect(reason)}")
          end
        end)

        {:ok, node}

      error ->
        error
    end
  end

  @impl true
  def get_node(%{primary: primary}, id) do
    Rag.GraphStore.get_node(primary, id)
  end

  @impl true
  def create_edge(%{primary: primary, secondary: secondary}, attrs) do
    case Rag.GraphStore.create_edge(primary, attrs) do
      {:ok, edge} ->
        Task.start(fn ->
          Rag.GraphStore.create_edge(secondary, Map.put(attrs, :id, edge.id))
        end)

        {:ok, edge}

      error ->
        error
    end
  end

  # Traversal - read from primary only

  @impl true
  def find_neighbors(%{primary: primary}, node_id, opts) do
    Rag.GraphStore.find_neighbors(primary, node_id, opts)
  end

  @impl true
  def traverse(%{primary: primary}, start_id, opts) do
    Rag.GraphStore.traverse(primary, start_id, opts)
  end

  @impl true
  def vector_search(%{primary: primary}, embedding, opts) do
    Rag.GraphStore.vector_search(primary, embedding, opts)
  end

  # Community operations

  @impl true
  def create_community(%{primary: primary, secondary: secondary}, attrs) do
    case Rag.GraphStore.create_community(primary, attrs) do
      {:ok, community} ->
        Task.start(fn ->
          Rag.GraphStore.create_community(secondary, Map.put(attrs, :id, community.id))
        end)

        {:ok, community}

      error ->
        error
    end
  end

  @impl true
  def get_community_members(%{primary: primary}, community_id) do
    Rag.GraphStore.get_community_members(primary, community_id)
  end

  @impl true
  def update_community_summary(%{primary: primary, secondary: secondary}, community_id, summary) do
    case Rag.GraphStore.update_community_summary(primary, community_id, summary) do
      {:ok, community} ->
        Task.start(fn ->
          Rag.GraphStore.update_community_summary(secondary, community_id, summary)
        end)

        {:ok, community}

      error ->
        error
    end
  end
end
```

### 2.2 Enable Dual Write

```elixir
# lib/my_app/graph_store.ex
defmodule MyApp.GraphStore do
  def get_store do
    config = Application.get_env(:rag, :graph_stores)

    if config[:secondary] do
      primary = get_store_instance(config.primary)
      secondary = get_store_instance(config.secondary)
      Rag.GraphStore.DualWrite.new(primary, secondary)
    else
      get_store_instance(config.primary)
    end
  end

  defp get_store_instance(Rag.GraphStore.Pgvector) do
    %Rag.GraphStore.Pgvector{repo: MyApp.Repo}
  end

  defp get_store_instance(Rag.GraphStore.TripleStore) do
    {:ok, store} = Rag.GraphStore.TripleStore.open(
      data_dir: Application.get_env(:rag, Rag.GraphStore.TripleStore)[:data_dir]
    )
    store
  end
end
```

## Phase 3: Backfill Historical Data

### 3.1 Migration Script

```elixir
# lib/mix/tasks/rag.migrate_graph_store.ex
defmodule Mix.Tasks.Rag.MigrateGraphStore do
  @moduledoc """
  Migrates graph data from PostgreSQL to TripleStore.

  ## Usage

      mix rag.migrate_graph_store --batch-size 1000
  """

  use Mix.Task
  require Logger

  alias Rag.GraphStore.{Entity, Edge, Community}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [batch_size: :integer])
    batch_size = Keyword.get(opts, :batch_size, 1000)

    Mix.Task.run("app.start")

    Logger.info("Starting graph store migration...")

    {:ok, triplestore} = Rag.GraphStore.TripleStore.open(
      data_dir: Application.get_env(:rag, Rag.GraphStore.TripleStore)[:data_dir]
    )

    # Migrate entities
    migrate_entities(triplestore, batch_size)

    # Migrate edges
    migrate_edges(triplestore, batch_size)

    # Migrate communities
    migrate_communities(triplestore, batch_size)

    Rag.GraphStore.TripleStore.close(triplestore)
    Logger.info("Migration complete!")
  end

  defp migrate_entities(triplestore, batch_size) do
    Logger.info("Migrating entities...")

    stream = MyApp.Repo.stream(Entity)

    stream
    |> Stream.chunk_every(batch_size)
    |> Stream.with_index()
    |> Enum.each(fn {batch, index} ->
      Enum.each(batch, fn entity ->
        attrs = %{
          id: entity.id,
          type: String.to_atom(entity.type),
          name: entity.name,
          properties: entity.properties || %{},
          source_chunk_ids: entity.source_chunk_ids || [],
          embedding: entity.embedding
        }

        case Rag.GraphStore.TripleStore.create_node(triplestore, attrs) do
          {:ok, _} -> :ok
          {:error, reason} ->
            Logger.warning("Failed to migrate entity #{entity.id}: #{inspect(reason)}")
        end
      end)

      Logger.info("Migrated entities batch #{index + 1} (#{length(batch)} entities)")
    end)
  end

  defp migrate_edges(triplestore, batch_size) do
    Logger.info("Migrating edges...")

    stream = MyApp.Repo.stream(Edge)

    stream
    |> Stream.chunk_every(batch_size)
    |> Stream.with_index()
    |> Enum.each(fn {batch, index} ->
      Enum.each(batch, fn edge ->
        attrs = %{
          id: edge.id,
          from_id: edge.from_id,
          to_id: edge.to_id,
          type: String.to_atom(edge.type),
          weight: edge.weight,
          properties: edge.properties || %{}
        }

        case Rag.GraphStore.TripleStore.create_edge(triplestore, attrs) do
          {:ok, _} -> :ok
          {:error, reason} ->
            Logger.warning("Failed to migrate edge #{edge.id}: #{inspect(reason)}")
        end
      end)

      Logger.info("Migrated edges batch #{index + 1} (#{length(batch)} edges)")
    end)
  end

  defp migrate_communities(triplestore, batch_size) do
    Logger.info("Migrating communities...")

    stream = MyApp.Repo.stream(Community)

    stream
    |> Stream.chunk_every(batch_size)
    |> Stream.with_index()
    |> Enum.each(fn {batch, index} ->
      Enum.each(batch, fn community ->
        attrs = %{
          id: community.id,
          level: community.level,
          summary: community.summary,
          entity_ids: community.entity_ids || []
        }

        case Rag.GraphStore.TripleStore.create_community(triplestore, attrs) do
          {:ok, _} -> :ok
          {:error, reason} ->
            Logger.warning("Failed to migrate community #{community.id}: #{inspect(reason)}")
        end
      end)

      Logger.info("Migrated communities batch #{index + 1} (#{length(batch)} communities)")
    end)
  end
end
```

### 3.2 Run Migration

```bash
# Run with default batch size
mix rag.migrate_graph_store

# Run with custom batch size
mix rag.migrate_graph_store --batch-size 5000
```

### 3.3 Verify Migration

```elixir
# lib/mix/tasks/rag.verify_migration.ex
defmodule Mix.Tasks.Rag.VerifyMigration do
  @moduledoc """
  Verifies data consistency between PostgreSQL and TripleStore.
  """

  use Mix.Task
  require Logger

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Logger.info("Verifying migration...")

    pg_store = %Rag.GraphStore.Pgvector{repo: MyApp.Repo}
    {:ok, ts_store} = Rag.GraphStore.TripleStore.open(
      data_dir: Application.get_env(:rag, Rag.GraphStore.TripleStore)[:data_dir]
    )

    # Count comparison
    verify_counts(pg_store, ts_store)

    # Sample node comparison
    verify_sample_nodes(pg_store, ts_store, 100)

    # Sample traversal comparison
    verify_sample_traversals(pg_store, ts_store, 10)

    Rag.GraphStore.TripleStore.close(ts_store)
    Logger.info("Verification complete!")
  end

  defp verify_counts(pg_store, ts_store) do
    pg_entity_count = MyApp.Repo.aggregate(Rag.GraphStore.Entity, :count)
    pg_edge_count = MyApp.Repo.aggregate(Rag.GraphStore.Edge, :count)

    # Count triples in TripleStore (entities have rdf:type)
    ts_entity_count = count_entities(ts_store)
    ts_edge_count = count_edges(ts_store)

    Logger.info("""
    Count Comparison:
      Entities: PostgreSQL=#{pg_entity_count}, TripleStore=#{ts_entity_count}
      Edges: PostgreSQL=#{pg_edge_count}, TripleStore=#{ts_edge_count}
    """)

    if pg_entity_count != ts_entity_count or pg_edge_count != ts_edge_count do
      Logger.warning("Count mismatch detected!")
    end
  end

  defp verify_sample_nodes(pg_store, ts_store, sample_size) do
    sample_ids = MyApp.Repo.all(
      from e in Rag.GraphStore.Entity,
      order_by: fragment("RANDOM()"),
      limit: ^sample_size,
      select: e.id
    )

    mismatches = Enum.filter(sample_ids, fn id ->
      {:ok, pg_node} = Rag.GraphStore.get_node(pg_store, id)
      {:ok, ts_node} = Rag.GraphStore.get_node(ts_store, id)

      pg_node.name != ts_node.name or
      pg_node.type != ts_node.type or
      pg_node.properties != ts_node.properties
    end)

    if length(mismatches) > 0 do
      Logger.warning("Found #{length(mismatches)} node mismatches in sample")
    else
      Logger.info("All #{sample_size} sampled nodes match")
    end
  end

  defp verify_sample_traversals(pg_store, ts_store, sample_size) do
    sample_ids = MyApp.Repo.all(
      from e in Rag.GraphStore.Entity,
      order_by: fragment("RANDOM()"),
      limit: ^sample_size,
      select: e.id
    )

    Enum.each(sample_ids, fn id ->
      {:ok, pg_neighbors} = Rag.GraphStore.find_neighbors(pg_store, id, limit: 50)
      {:ok, ts_neighbors} = Rag.GraphStore.find_neighbors(ts_store, id, limit: 50)

      pg_ids = MapSet.new(Enum.map(pg_neighbors, & &1.id))
      ts_ids = MapSet.new(Enum.map(ts_neighbors, & &1.id))

      if pg_ids != ts_ids do
        Logger.warning("Neighbor mismatch for entity #{id}")
        Logger.debug("  PG only: #{inspect(MapSet.difference(pg_ids, ts_ids))}")
        Logger.debug("  TS only: #{inspect(MapSet.difference(ts_ids, pg_ids))}")
      end
    end)
  end

  defp count_entities(ts_store) do
    # Count entities by counting rdf:type triples to entity types
    # Implementation depends on TripleStore API
    0  # Placeholder
  end

  defp count_edges(ts_store) do
    # Count edges by counting urn:rel:* predicates
    0  # Placeholder
  end
end
```

## Phase 4: Shadow Read

### 4.1 Shadow Read Wrapper

```elixir
# lib/rag/graph_store/shadow_read.ex
defmodule Rag.GraphStore.ShadowRead do
  @moduledoc """
  Reads from both stores and compares results.
  Logs discrepancies for analysis.
  """

  @behaviour Rag.GraphStore
  require Logger

  defstruct [:primary, :secondary, :compare_fn]

  def new(primary_store, secondary_store, opts \\ []) do
    %__MODULE__{
      primary: primary_store,
      secondary: secondary_store,
      compare_fn: Keyword.get(opts, :compare_fn, &default_compare/2)
    }
  end

  @impl true
  def get_node(%{primary: primary, secondary: secondary, compare_fn: compare_fn}, id) do
    primary_result = Rag.GraphStore.get_node(primary, id)

    Task.start(fn ->
      secondary_result = Rag.GraphStore.get_node(secondary, id)
      compare_and_log(:get_node, id, primary_result, secondary_result, compare_fn)
    end)

    primary_result
  end

  @impl true
  def find_neighbors(%{primary: primary, secondary: secondary, compare_fn: compare_fn}, node_id, opts) do
    primary_result = Rag.GraphStore.find_neighbors(primary, node_id, opts)

    Task.start(fn ->
      secondary_result = Rag.GraphStore.find_neighbors(secondary, node_id, opts)
      compare_and_log(:find_neighbors, node_id, primary_result, secondary_result, compare_fn)
    end)

    primary_result
  end

  @impl true
  def traverse(%{primary: primary, secondary: secondary, compare_fn: compare_fn}, start_id, opts) do
    primary_result = Rag.GraphStore.traverse(primary, start_id, opts)

    Task.start(fn ->
      secondary_result = Rag.GraphStore.traverse(secondary, start_id, opts)
      compare_and_log(:traverse, start_id, primary_result, secondary_result, compare_fn)
    end)

    primary_result
  end

  # Delegate write operations to dual-write behavior
  @impl true
  def create_node(store, attrs), do: Rag.GraphStore.DualWrite.create_node(store, attrs)

  @impl true
  def create_edge(store, attrs), do: Rag.GraphStore.DualWrite.create_edge(store, attrs)

  @impl true
  def vector_search(%{primary: primary}, embedding, opts) do
    Rag.GraphStore.vector_search(primary, embedding, opts)
  end

  @impl true
  def create_community(store, attrs), do: Rag.GraphStore.DualWrite.create_community(store, attrs)

  @impl true
  def get_community_members(%{primary: primary}, community_id) do
    Rag.GraphStore.get_community_members(primary, community_id)
  end

  @impl true
  def update_community_summary(store, community_id, summary) do
    Rag.GraphStore.DualWrite.update_community_summary(store, community_id, summary)
  end

  # Private

  defp compare_and_log(operation, key, primary_result, secondary_result, compare_fn) do
    case compare_fn.(primary_result, secondary_result) do
      :match ->
        :ok

      {:mismatch, reason} ->
        Logger.warning("""
        Shadow read mismatch detected:
          Operation: #{operation}
          Key: #{inspect(key)}
          Reason: #{reason}
          Primary: #{inspect(primary_result)}
          Secondary: #{inspect(secondary_result)}
        """)

        # Emit telemetry for monitoring
        :telemetry.execute(
          [:rag, :graph_store, :shadow_read, :mismatch],
          %{count: 1},
          %{operation: operation, reason: reason}
        )
    end
  end

  defp default_compare({:ok, p}, {:ok, s}) do
    if compare_results(p, s), do: :match, else: {:mismatch, :content_differs}
  end

  defp default_compare({:error, _}, {:error, _}), do: :match
  defp default_compare(_, _), do: {:mismatch, :status_differs}

  defp compare_results(nodes, nodes) when is_list(nodes), do: true
  defp compare_results(p_nodes, s_nodes) when is_list(p_nodes) and is_list(s_nodes) do
    p_ids = MapSet.new(Enum.map(p_nodes, & &1.id))
    s_ids = MapSet.new(Enum.map(s_nodes, & &1.id))
    MapSet.equal?(p_ids, s_ids)
  end
  defp compare_results(%{id: id, name: name, type: type}, %{id: id, name: name, type: type}), do: true
  defp compare_results(_, _), do: false
end
```

## Phase 5: Cutover

### 5.1 Update Configuration

```elixir
# config/config.exs (after cutover)
config :rag, :graph_stores, %{
  primary: Rag.GraphStore.TripleStore,
  secondary: nil  # Disable dual-write
}

config :rag, Rag.GraphStore.TripleStore,
  data_dir: "data/knowledge_graph"
```

### 5.2 Cutover Checklist

```markdown
## Pre-Cutover Checklist

- [ ] All historical data migrated
- [ ] Shadow read shows <0.1% mismatch rate
- [ ] Performance benchmarks meet requirements
- [ ] Rollback procedure tested
- [ ] Backup of PostgreSQL graph tables created
- [ ] Monitoring alerts configured

## Cutover Steps

1. [ ] Announce maintenance window
2. [ ] Stop ingestion pipelines
3. [ ] Drain in-flight dual-writes
4. [ ] Update configuration to TripleStore primary
5. [ ] Restart application
6. [ ] Verify read operations
7. [ ] Re-enable ingestion pipelines
8. [ ] Monitor error rates

## Post-Cutover

- [ ] Monitor for 24 hours
- [ ] Compare latency metrics
- [ ] Verify no data loss
- [ ] Remove dual-write code (Phase 6)
```

## Phase 6: Cleanup

### 6.1 Remove Dual-Write Code

```elixir
# lib/my_app/graph_store.ex (simplified after migration)
defmodule MyApp.GraphStore do
  def get_store do
    {:ok, store} = Rag.GraphStore.TripleStore.open(
      data_dir: Application.get_env(:rag, Rag.GraphStore.TripleStore)[:data_dir]
    )
    store
  end
end
```

### 6.2 Archive PostgreSQL Tables (Optional)

```sql
-- Create archive schema
CREATE SCHEMA IF NOT EXISTS archive;

-- Move tables to archive
ALTER TABLE graph_entities SET SCHEMA archive;
ALTER TABLE graph_edges SET SCHEMA archive;
ALTER TABLE graph_communities SET SCHEMA archive;

-- Or drop if not needed
-- DROP TABLE graph_entities, graph_edges, graph_communities CASCADE;
```

## Rollback Procedure

If issues are encountered after cutover:

### Immediate Rollback

```elixir
# config/config.exs (rollback)
config :rag, :graph_stores, %{
  primary: Rag.GraphStore.Pgvector,
  secondary: nil
}
```

### Data Recovery

If data was written only to TripleStore during the issue:

```elixir
# lib/mix/tasks/rag.sync_to_postgres.ex
defmodule Mix.Tasks.Rag.SyncToPostgres do
  @moduledoc """
  Syncs new data from TripleStore back to PostgreSQL.
  """

  use Mix.Task
  require Logger

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [since: :string])
    since = Keyword.get(opts, :since) |> parse_datetime()

    Mix.Task.run("app.start")

    # Query TripleStore for entities created after cutover
    # Insert into PostgreSQL

    Logger.info("Sync complete!")
  end

  defp parse_datetime(nil), do: ~U[2025-01-01 00:00:00Z]
  defp parse_datetime(str), do: DateTime.from_iso8601!(str)
end
```

## Monitoring

### Telemetry Events

```elixir
# lib/rag/graph_store/triple_store/telemetry.ex
defmodule Rag.GraphStore.TripleStore.Telemetry do
  def attach do
    :telemetry.attach_many(
      "rag-graphstore-triplestore",
      [
        [:rag, :graph_store, :triple_store, :operation],
        [:rag, :graph_store, :shadow_read, :mismatch]
      ],
      &handle_event/4,
      nil
    )
  end

  defp handle_event([:rag, :graph_store, :triple_store, :operation], measurements, metadata, _) do
    # Log operation metrics
    Logger.debug("TripleStore #{metadata.operation}: #{measurements.duration}ms")
  end

  defp handle_event([:rag, :graph_store, :shadow_read, :mismatch], _measurements, metadata, _) do
    # Alert on mismatches
    Logger.warning("Shadow read mismatch: #{metadata.operation} - #{metadata.reason}")
  end
end
```

### Grafana Dashboard Queries

```promql
# Operation latency
histogram_quantile(0.99, sum(rate(rag_graph_store_operation_duration_bucket[5m])) by (le, operation))

# Mismatch rate
sum(rate(rag_graph_store_shadow_read_mismatch_total[5m])) by (operation)

# Throughput
sum(rate(rag_graph_store_operation_total[5m])) by (operation)
```
