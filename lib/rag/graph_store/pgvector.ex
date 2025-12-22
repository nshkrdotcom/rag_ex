if Code.ensure_loaded?(Ecto.Query) do
  defmodule Rag.GraphStore.Pgvector do
    @moduledoc """
    PostgreSQL/pgvector implementation of the GraphStore behaviour.

    Uses:
    - PostgreSQL for graph storage (entities, edges, communities)
    - pgvector for entity embedding similarity search
    - Recursive CTEs for efficient graph traversal
    - Foreign keys for referential integrity

    ## Configuration

    Pass the Ecto repo as an option:

        store = %Rag.GraphStore.Pgvector{repo: MyApp.Repo}

    ## Database Schema

    Requires the following tables:

    - `graph_entities` - Nodes with embeddings
    - `graph_edges` - Relationships between entities
    - `graph_communities` - Entity clusters with summaries

    """

    @behaviour Rag.GraphStore

    import Ecto.Query

    alias Rag.GraphStore
    alias Rag.GraphStore.{Entity, Edge, Community}

    defstruct [:repo]

    @type t :: %__MODULE__{
            repo: module()
          }

    @default_limit 10
    @default_max_depth 2

    # Node operations

    @impl GraphStore
    def create_node(%__MODULE__{repo: repo}, node_attrs) do
      entity = Entity.new(node_attrs)
      changeset = Entity.changeset(entity, Map.from_struct(entity))

      case repo.insert(changeset) do
        {:ok, entity} -> {:ok, Entity.to_node(entity)}
        {:error, changeset} -> {:error, changeset}
      end
    end

    @impl GraphStore
    def get_node(%__MODULE__{repo: repo}, id) do
      case repo.get(Entity, id) do
        nil -> {:error, :not_found}
        entity -> {:ok, Entity.to_node(entity)}
      end
    end

    # Edge operations

    @impl GraphStore
    def create_edge(%__MODULE__{repo: repo}, edge_attrs) do
      edge = Edge.new(edge_attrs)
      changeset = Edge.changeset(edge, Map.from_struct(edge))

      case repo.insert(changeset) do
        {:ok, edge} -> {:ok, Edge.to_map(edge)}
        {:error, changeset} -> {:error, changeset}
      end
    end

    # Neighbor finding

    @impl GraphStore
    def find_neighbors(%__MODULE__{repo: repo}, node_id, opts \\ []) do
      direction = Keyword.get(opts, :direction, :both)
      edge_type = Keyword.get(opts, :edge_type)
      limit = Keyword.get(opts, :limit, @default_limit)

      query = build_neighbors_query(node_id, direction, edge_type, limit)

      neighbors =
        repo.all(query)
        |> Enum.map(&map_to_node/1)

      {:ok, neighbors}
    rescue
      e -> {:error, e}
    end

    # Vector search

    @impl GraphStore
    def vector_search(%__MODULE__{repo: repo}, embedding, opts \\ []) do
      limit = Keyword.get(opts, :limit, @default_limit)
      type_filter = Keyword.get(opts, :type)

      vector = Pgvector.new(embedding)

      query =
        from(e in Entity,
          select: e,
          order_by: fragment("? <-> ?", e.embedding, ^vector),
          limit: ^limit
        )

      query =
        if type_filter do
          type_str = normalize_type(type_filter)
          where(query, [e], e.type == ^type_str)
        else
          query
        end

      entities =
        repo.all(query)
        |> Enum.map(&Entity.to_node/1)

      {:ok, entities}
    rescue
      e -> {:error, e}
    end

    # Graph traversal

    @impl GraphStore
    def traverse(%__MODULE__{repo: repo}, start_id, opts \\ []) do
      max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
      algorithm = Keyword.get(opts, :algorithm, :bfs)
      limit_opt = Keyword.get(opts, :limit)

      query = build_traversal_query(start_id, max_depth, algorithm)

      query =
        if limit_opt do
          limit(query, ^limit_opt)
        else
          query
        end

      results =
        repo.all(query)
        |> Enum.map(&map_to_node_with_depth/1)

      {:ok, results}
    rescue
      e -> {:error, e}
    end

    # Community operations

    @impl GraphStore
    def create_community(%__MODULE__{repo: repo}, community_attrs) do
      community = Community.new(community_attrs)
      changeset = Community.changeset(community, Map.from_struct(community))

      case repo.insert(changeset) do
        {:ok, community} -> {:ok, Community.to_map(community)}
        {:error, changeset} -> {:error, changeset}
      end
    end

    @impl GraphStore
    def get_community_members(%__MODULE__{repo: repo}, community_id) do
      case repo.get(Community, community_id) do
        nil ->
          {:error, :not_found}

        community ->
          query =
            from(e in Entity,
              where: e.id in ^community.entity_ids,
              select: e
            )

          members =
            repo.all(query)
            |> Enum.map(&Entity.to_node/1)

          {:ok, members}
      end
    rescue
      e -> {:error, e}
    end

    @impl GraphStore
    def update_community_summary(%__MODULE__{repo: repo}, community_id, summary) do
      case repo.get(Community, community_id) do
        nil ->
          {:error, :not_found}

        community ->
          changeset = Community.summary_changeset(community, %{summary: summary})

          case repo.update(changeset) do
            {:ok, updated} -> {:ok, Community.to_map(updated)}
            {:error, changeset} -> {:error, changeset}
          end
      end
    rescue
      e -> {:error, e}
    end

    # Private query builders

    defp build_neighbors_query(node_id, direction, edge_type, limit_val) do
      # Build query to find neighbors
      # Joins edges and entities based on direction
      base_query =
        case direction do
          :out ->
            from(e in Edge,
              join: entity in Entity,
              on: e.to_id == entity.id,
              where: e.from_id == ^node_id,
              select: %{
                id: entity.id,
                name: entity.name,
                type: entity.type,
                properties: entity.properties,
                embedding: entity.embedding,
                source_chunk_ids: entity.source_chunk_ids,
                edge_type: e.type,
                weight: e.weight
              }
            )

          :in ->
            from(e in Edge,
              join: entity in Entity,
              on: e.from_id == entity.id,
              where: e.to_id == ^node_id,
              select: %{
                id: entity.id,
                name: entity.name,
                type: entity.type,
                properties: entity.properties,
                embedding: entity.embedding,
                source_chunk_ids: entity.source_chunk_ids,
                edge_type: e.type,
                weight: e.weight
              }
            )

          :both ->
            # Union of outgoing and incoming edges
            out_query =
              from(e in Edge,
                join: entity in Entity,
                on: e.to_id == entity.id,
                where: e.from_id == ^node_id,
                select: %{
                  id: entity.id,
                  name: entity.name,
                  type: entity.type,
                  properties: entity.properties,
                  embedding: entity.embedding,
                  source_chunk_ids: entity.source_chunk_ids,
                  edge_type: e.type,
                  weight: e.weight
                }
              )

            in_query =
              from(e in Edge,
                join: entity in Entity,
                on: e.from_id == entity.id,
                where: e.to_id == ^node_id,
                select: %{
                  id: entity.id,
                  name: entity.name,
                  type: entity.type,
                  properties: entity.properties,
                  embedding: entity.embedding,
                  source_chunk_ids: entity.source_chunk_ids,
                  edge_type: e.type,
                  weight: e.weight
                }
              )

            union_all(out_query, ^in_query)
        end

      # Apply edge type filter if provided
      query =
        if edge_type do
          edge_type_str = normalize_type(edge_type)

          case direction do
            :both ->
              # For union queries, filter on subquery
              from(q in subquery(base_query),
                where: q.edge_type == ^edge_type_str
              )

            _ ->
              where(base_query, [e, _entity], e.type == ^edge_type_str)
          end
        else
          base_query
        end

      # Apply limit
      limit(query, ^limit_val)
    end

    defp build_traversal_query(start_id, max_depth, algorithm) do
      # Build recursive CTE for graph traversal
      case algorithm do
        :bfs -> build_bfs_query(start_id, max_depth)
        :dfs -> build_dfs_query(start_id, max_depth)
      end
    end

    defp build_bfs_query(start_id, max_depth) do
      # Breadth-First Search using recursive CTE with literal fragment
      from(
        e in fragment(
          "(WITH RECURSIVE graph_traversal AS (SELECT e.id, e.name, e.type, e.properties, e.embedding, e.source_chunk_ids, 0 as depth, ARRAY[e.id] as path FROM graph_entities e WHERE e.id = ? UNION ALL SELECT next_entity.id, next_entity.name, next_entity.type, next_entity.properties, next_entity.embedding, next_entity.source_chunk_ids, gt.depth + 1 as depth, gt.path || next_entity.id as path FROM graph_traversal gt JOIN graph_edges edge ON edge.from_id = gt.id JOIN graph_entities next_entity ON next_entity.id = edge.to_id WHERE gt.depth < ? AND NOT (next_entity.id = ANY(gt.path))) SELECT * FROM graph_traversal ORDER BY depth, id)",
          ^start_id,
          ^max_depth
        ),
        select: %{
          id: e.id,
          name: e.name,
          type: e.type,
          properties: e.properties,
          embedding: e.embedding,
          source_chunk_ids: e.source_chunk_ids,
          depth: e.depth
        }
      )
    end

    defp build_dfs_query(start_id, max_depth) do
      # Depth-First Search using recursive CTE with literal fragment
      from(
        e in fragment(
          "(WITH RECURSIVE graph_traversal AS (SELECT e.id, e.name, e.type, e.properties, e.embedding, e.source_chunk_ids, 0 as depth, ARRAY[e.id] as path FROM graph_entities e WHERE e.id = ? UNION ALL SELECT next_entity.id, next_entity.name, next_entity.type, next_entity.properties, next_entity.embedding, next_entity.source_chunk_ids, gt.depth + 1 as depth, gt.path || next_entity.id as path FROM graph_traversal gt JOIN graph_edges edge ON edge.from_id = gt.id JOIN graph_entities next_entity ON next_entity.id = edge.to_id WHERE gt.depth < ? AND NOT (next_entity.id = ANY(gt.path))) SELECT * FROM graph_traversal ORDER BY path, depth)",
          ^start_id,
          ^max_depth
        ),
        select: %{
          id: e.id,
          name: e.name,
          type: e.type,
          properties: e.properties,
          embedding: e.embedding,
          source_chunk_ids: e.source_chunk_ids,
          depth: e.depth
        }
      )
    end

    # Private helpers

    defp normalize_type(type) when is_atom(type), do: Atom.to_string(type)
    defp normalize_type(type) when is_binary(type), do: type

    defp map_to_node(result) when is_map(result) do
      %{
        id: result.id || result[:id],
        name: result.name || result[:name],
        type: result.type || result[:type],
        properties: result.properties || result[:properties] || %{},
        embedding: result.embedding || result[:embedding],
        source_chunk_ids: result.source_chunk_ids || result[:source_chunk_ids] || []
      }
    end

    defp map_to_node_with_depth(result) when is_map(result) do
      node = map_to_node(result)
      Map.put(node, :depth, result.depth || result[:depth] || 0)
    end
  end
end
