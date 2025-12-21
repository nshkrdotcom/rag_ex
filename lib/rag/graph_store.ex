defmodule Rag.GraphStore do
  @moduledoc """
  Behaviour for knowledge graph storage backends.

  Supports entity-relationship storage for GraphRAG patterns.
  GraphRAG extends traditional RAG by:

  1. Extracting entities and relationships from text
  2. Building a knowledge graph
  3. Detecting communities via graph algorithms
  4. Generating hierarchical summaries
  5. Using graph structure for contextual retrieval

  ## Architecture

  The GraphStore provides operations for:

  - **Node operations**: Create and retrieve entities with embeddings
  - **Edge operations**: Model relationships between entities
  - **Graph traversal**: Navigate relationships (BFS/DFS)
  - **Vector search**: Find similar entities via embeddings
  - **Community operations**: Cluster entities and generate summaries

  ## Usage

      # Initialize store with your repo
      store = %Rag.GraphStore.Pgvector{repo: MyApp.Repo}

      # Create entities
      {:ok, alice} = GraphStore.create_node(store, %{
        type: :person,
        name: "Alice",
        properties: %{role: "engineer"},
        embedding: [0.1, 0.2, ...],
        source_chunk_ids: [1, 2]
      })

      {:ok, bob} = GraphStore.create_node(store, %{
        type: :person,
        name: "Bob",
        properties: %{role: "manager"},
        embedding: [0.3, 0.4, ...],
        source_chunk_ids: [3]
      })

      # Create relationship
      {:ok, edge} = GraphStore.create_edge(store, %{
        from_id: alice.id,
        to_id: bob.id,
        type: :reports_to,
        weight: 1.0
      })

      # Find neighbors
      {:ok, neighbors} = GraphStore.find_neighbors(store, alice.id, limit: 10)

      # Traverse graph
      {:ok, nodes} = GraphStore.traverse(store, alice.id, max_depth: 2)

      # Vector search
      {:ok, similar} = GraphStore.vector_search(store, query_embedding, limit: 5)

      # Create community
      {:ok, community} = GraphStore.create_community(store, %{
        level: 0,
        entity_ids: [alice.id, bob.id],
        summary: "Engineering team"
      })

  ## Implementation

  To implement a custom GraphStore backend:

      defmodule MyGraphStore do
        @behaviour Rag.GraphStore

        defstruct [:config]

        @impl true
        def create_node(store, node_attrs) do
          # Implementation
        end

        # ... implement other callbacks
      end

  """

  @type graph_node :: %{
          id: any(),
          type: atom() | String.t(),
          name: String.t(),
          properties: map(),
          embedding: [float()] | nil,
          source_chunk_ids: [any()]
        }

  @type edge :: %{
          id: any(),
          from_id: any(),
          to_id: any(),
          type: atom() | String.t(),
          weight: float(),
          properties: map()
        }

  @type community :: %{
          id: any(),
          level: non_neg_integer(),
          summary: String.t() | nil,
          entity_ids: [any()]
        }

  @doc """
  Create a new entity (node) in the graph.

  ## Parameters

  - `store` - The graph store implementation
  - `node` - Map with entity attributes (type, name, properties, embedding, source_chunk_ids)

  ## Returns

  - `{:ok, node}` - The created node with assigned ID
  - `{:error, reason}` - If creation fails
  """
  @callback create_node(store :: struct(), node :: map()) ::
              {:ok, graph_node} | {:error, term()}

  @doc """
  Create a new relationship (edge) between entities.

  ## Parameters

  - `store` - The graph store implementation
  - `edge` - Map with edge attributes (from_id, to_id, type, weight, properties)

  ## Returns

  - `{:ok, edge}` - The created edge with assigned ID
  - `{:error, reason}` - If creation fails
  """
  @callback create_edge(store :: struct(), edge :: map()) ::
              {:ok, edge()} | {:error, term()}

  @doc """
  Retrieve an entity by ID.

  ## Parameters

  - `store` - The graph store implementation
  - `id` - The entity ID

  ## Returns

  - `{:ok, node}` - The entity if found
  - `{:error, :not_found}` - If entity doesn't exist
  """
  @callback get_node(store :: struct(), id :: any()) ::
              {:ok, graph_node} | {:error, :not_found}

  @doc """
  Find neighboring entities connected by edges.

  ## Parameters

  - `store` - The graph store implementation
  - `node_id` - The starting entity ID
  - `opts` - Options:
    - `:limit` - Maximum number of neighbors (default: 10)
    - `:direction` - `:in`, `:out`, or `:both` (default: :both)
    - `:edge_type` - Filter by edge type (optional)

  ## Returns

  - `{:ok, [node]}` - List of neighboring entities
  - `{:error, reason}` - If query fails
  """
  @callback find_neighbors(store :: struct(), node_id :: any(), opts :: keyword()) ::
              {:ok, [graph_node]} | {:error, term()}

  @doc """
  Search for entities by embedding similarity.

  Uses vector distance (L2) to find semantically similar entities.

  ## Parameters

  - `store` - The graph store implementation
  - `embedding` - Query embedding vector
  - `opts` - Options:
    - `:limit` - Maximum results (default: 10)
    - `:type` - Filter by entity type (optional)

  ## Returns

  - `{:ok, [node]}` - List of similar entities ordered by distance
  - `{:error, reason}` - If search fails
  """
  @callback vector_search(store :: struct(), embedding :: [float()], opts :: keyword()) ::
              {:ok, [graph_node]} | {:error, term()}

  @doc """
  Traverse the graph from a starting entity.

  Supports breadth-first search (BFS) and depth-first search (DFS).

  ## Parameters

  - `store` - The graph store implementation
  - `start_id` - Starting entity ID
  - `opts` - Options:
    - `:max_depth` - Maximum traversal depth (default: 2)
    - `:algorithm` - `:bfs` or `:dfs` (default: :bfs)
    - `:limit` - Maximum nodes to return (optional)

  ## Returns

  - `{:ok, [node]}` - List of reachable entities with depth info
  - `{:error, reason}` - If traversal fails
  """
  @callback traverse(store :: struct(), start_id :: any(), opts :: keyword()) ::
              {:ok, [graph_node]} | {:error, term()}

  @doc """
  Create a community (cluster) of related entities.

  ## Parameters

  - `store` - The graph store implementation
  - `community` - Map with community attributes (level, entity_ids, summary)

  ## Returns

  - `{:ok, community}` - The created community
  - `{:error, reason}` - If creation fails
  """
  @callback create_community(store :: struct(), community :: map()) ::
              {:ok, community()} | {:error, term()}

  @doc """
  Get all entities belonging to a community.

  ## Parameters

  - `store` - The graph store implementation
  - `community_id` - The community ID

  ## Returns

  - `{:ok, [node]}` - List of entities in the community
  - `{:error, :not_found}` - If community doesn't exist
  """
  @callback get_community_members(store :: struct(), community_id :: any()) ::
              {:ok, [graph_node]} | {:error, term()}

  @doc """
  Update the summary of a community.

  Used after generating community summaries via LLM.

  ## Parameters

  - `store` - The graph store implementation
  - `community_id` - The community ID
  - `summary` - New summary text

  ## Returns

  - `{:ok, community}` - The updated community
  - `{:error, :not_found}` - If community doesn't exist
  """
  @callback update_community_summary(
              store :: struct(),
              community_id :: any(),
              summary :: String.t()
            ) ::
              {:ok, community()} | {:error, term()}

  # Convenience dispatch functions

  @doc """
  Convenience function to create a node using the store's implementation.
  """
  @spec create_node(struct(), map()) :: {:ok, graph_node} | {:error, term()}
  def create_node(%module{} = store, node) do
    module.create_node(store, node)
  end

  @doc """
  Convenience function to create an edge using the store's implementation.
  """
  @spec create_edge(struct(), map()) :: {:ok, edge()} | {:error, term()}
  def create_edge(%module{} = store, edge) do
    module.create_edge(store, edge)
  end

  @doc """
  Convenience function to get a node using the store's implementation.
  """
  @spec get_node(struct(), any()) :: {:ok, graph_node} | {:error, :not_found}
  def get_node(%module{} = store, id) do
    module.get_node(store, id)
  end

  @doc """
  Convenience function to find neighbors using the store's implementation.
  """
  @spec find_neighbors(struct(), any(), keyword()) :: {:ok, [graph_node]} | {:error, term()}
  def find_neighbors(%module{} = store, node_id, opts \\ []) do
    module.find_neighbors(store, node_id, opts)
  end

  @doc """
  Convenience function to perform vector search using the store's implementation.
  """
  @spec vector_search(struct(), [float()], keyword()) :: {:ok, [graph_node]} | {:error, term()}
  def vector_search(%module{} = store, embedding, opts \\ []) do
    module.vector_search(store, embedding, opts)
  end

  @doc """
  Convenience function to traverse the graph using the store's implementation.
  """
  @spec traverse(struct(), any(), keyword()) :: {:ok, [graph_node]} | {:error, term()}
  def traverse(%module{} = store, start_id, opts \\ []) do
    module.traverse(store, start_id, opts)
  end

  @doc """
  Convenience function to create a community using the store's implementation.
  """
  @spec create_community(struct(), map()) :: {:ok, community()} | {:error, term()}
  def create_community(%module{} = store, community) do
    module.create_community(store, community)
  end

  @doc """
  Convenience function to get community members using the store's implementation.
  """
  @spec get_community_members(struct(), any()) :: {:ok, [graph_node]} | {:error, term()}
  def get_community_members(%module{} = store, community_id) do
    module.get_community_members(store, community_id)
  end

  @doc """
  Convenience function to update community summary using the store's implementation.
  """
  @spec update_community_summary(struct(), any(), String.t()) ::
          {:ok, community()} | {:error, term()}
  def update_community_summary(%module{} = store, community_id, summary) do
    module.update_community_summary(store, community_id, summary)
  end
end
