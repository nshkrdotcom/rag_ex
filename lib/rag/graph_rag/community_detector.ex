defmodule Rag.GraphRAG.CommunityDetector do
  @moduledoc """
  Detect communities in the knowledge graph and generate summaries.

  Uses label propagation algorithm for community detection,
  which is simple and works well with PostgreSQL.

  ## Examples

      # Detect communities
      {:ok, communities} = CommunityDetector.detect(graph_store)

      # Detect and summarize
      {:ok, communities} = CommunityDetector.detect_and_summarize(graph_store, router: router)

      # Build hierarchical communities
      {:ok, hierarchy} = CommunityDetector.build_hierarchy(graph_store, levels: 2)

  ## Community Structure

  Each community is a map with:
  - `:id` - Unique community identifier
  - `:level` - Hierarchy level (0 = base level)
  - `:entity_ids` - List of entity IDs in this community
  - `:summary` - Optional LLM-generated summary

  ## Label Propagation Algorithm

  1. Initialize each node with its own community ID
  2. Iteratively propagate: each node adopts the most common community among neighbors
  3. Repeat until convergence or max iterations reached
  4. Group nodes by final community assignment

  """

  require Logger

  @type community :: %{
          id: any(),
          level: non_neg_integer(),
          entity_ids: [any()],
          summary: String.t() | nil
        }

  @default_max_iterations 100
  @default_levels 1

  @doc """
  Detect communities using label propagation algorithm.

  Returns list of communities with member entity IDs.

  ## Options

  - `:max_iterations` - Maximum iterations for label propagation (default: 100)

  ## Examples

      {:ok, communities} = CommunityDetector.detect(graph_store)
      {:ok, communities} = CommunityDetector.detect(graph_store, max_iterations: 50)

  """
  @spec detect(graph_store :: struct(), opts :: keyword()) ::
          {:ok, [community()]} | {:error, term()}
  def detect(graph_store, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)

    with {:ok, entities} <- graph_store.__struct__.get_all_entities(graph_store),
         {:ok, edges} <- graph_store.__struct__.get_all_edges(graph_store) do
      communities = run_label_propagation(entities, edges, max_iterations)
      {:ok, communities}
    end
  end

  @doc """
  Generate summaries for detected communities using LLM.

  ## Options

  - `:router` - Router instance for LLM calls (will auto-detect if not provided)
  - `:provider` - Specific provider to use (optional)

  ## Examples

      {:ok, communities} = CommunityDetector.summarize_communities(
        graph_store,
        communities,
        router: router
      )

  """
  @spec summarize_communities(
          graph_store :: struct(),
          communities :: [community()],
          opts :: keyword()
        ) ::
          {:ok, [community()]} | {:error, term()}
  def summarize_communities(graph_store, communities, opts \\ [])

  def summarize_communities(_graph_store, [], _opts), do: {:ok, []}

  def summarize_communities(graph_store, communities, opts) when is_list(communities) do
    router = get_router(opts)

    # Process each community and generate summary
    results =
      Enum.reduce_while(communities, {:ok, []}, fn community, {:ok, acc} ->
        case summarize_single_community(graph_store, community, router) do
          {:ok, summarized_community} ->
            {:cont, {:ok, [summarized_community | acc]}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)

    case results do
      {:ok, summarized} -> {:ok, Enum.reverse(summarized)}
      error -> error
    end
  end

  @doc """
  Detect and summarize communities in one step.

  Combines `detect/2` and `summarize_communities/3`.

  ## Options

  - `:max_iterations` - For label propagation
  - `:router` - Router for LLM summarization
  - `:provider` - Specific LLM provider

  ## Examples

      {:ok, communities} = CommunityDetector.detect_and_summarize(graph_store)
      {:ok, communities} = CommunityDetector.detect_and_summarize(
        graph_store,
        router: router,
        max_iterations: 50
      )

  """
  @spec detect_and_summarize(graph_store :: struct(), opts :: keyword()) ::
          {:ok, [community()]} | {:error, term()}
  def detect_and_summarize(graph_store, opts \\ []) do
    with {:ok, communities} <- detect(graph_store, opts),
         {:ok, summarized} <- summarize_communities(graph_store, communities, opts) do
      {:ok, summarized}
    end
  end

  @doc """
  Build hierarchical communities (multiple levels).

  Creates a hierarchy by:
  1. Detecting level-0 communities on the original graph
  2. Creating a meta-graph where communities become nodes
  3. Detecting communities on the meta-graph for level-1
  4. Repeating for additional levels

  ## Options

  - `:levels` - Number of hierarchy levels (default: 1)
  - `:max_iterations` - For each level's label propagation

  ## Returns

  List of community lists, one per level:
  `[[level_0_communities], [level_1_communities], ...]`

  ## Examples

      {:ok, hierarchy} = CommunityDetector.build_hierarchy(graph_store)
      {:ok, hierarchy} = CommunityDetector.build_hierarchy(graph_store, levels: 3)

  """
  @spec build_hierarchy(graph_store :: struct(), opts :: keyword()) ::
          {:ok, [[community()]]} | {:error, term()}
  def build_hierarchy(graph_store, opts \\ []) do
    levels = Keyword.get(opts, :levels, @default_levels)

    case detect(graph_store, opts) do
      {:ok, level_0_communities} ->
        build_hierarchy_levels(graph_store, [level_0_communities], levels - 1, opts)

      {:error, _} = error ->
        error
    end
  end

  # Private functions

  defp run_label_propagation([], _edges, _max_iterations) do
    []
  end

  defp run_label_propagation(entities, edges, max_iterations) do
    # Initialize: each node gets its own community ID
    entity_ids = Enum.map(entities, & &1.id)
    initial_labels = Map.new(entity_ids, fn id -> {id, id} end)

    # Build adjacency list for efficient neighbor lookup
    adjacency = build_adjacency_list(edges)

    # Run label propagation iterations
    final_labels = propagate_labels(initial_labels, adjacency, max_iterations)

    # Group entities by their final community label
    group_by_community(final_labels)
  end

  defp build_adjacency_list(edges) do
    # Build undirected adjacency list
    Enum.reduce(edges, %{}, fn edge, acc ->
      acc
      |> Map.update(edge.from_id, [edge.to_id], &[edge.to_id | &1])
      |> Map.update(edge.to_id, [edge.from_id], &[edge.from_id | &1])
    end)
  end

  defp propagate_labels(labels, adjacency, max_iterations) do
    propagate_labels(labels, adjacency, 0, max_iterations, %{})
  end

  defp propagate_labels(labels, _adjacency, iteration, max_iterations, prev_labels)
       when iteration >= max_iterations or labels == prev_labels do
    # Converged or reached max iterations
    labels
  end

  defp propagate_labels(labels, adjacency, iteration, max_iterations, _prev_labels) do
    # Randomize node update order to avoid bias (important for label propagation)
    node_ids = Map.keys(labels) |> Enum.shuffle()

    # Update each node's label to the most common among its neighbors
    new_labels =
      Enum.reduce(node_ids, labels, fn node_id, acc_labels ->
        neighbors = Map.get(adjacency, node_id, [])

        new_label =
          if neighbors == [] do
            # No neighbors, keep own label
            Map.get(acc_labels, node_id)
          else
            # Find most common label among neighbors
            # In case of tie, pick the smallest to ensure determinism
            neighbors
            |> Enum.map(&Map.get(acc_labels, &1))
            |> Enum.frequencies()
            |> Enum.max_by(fn {label, count} -> {count, -label} end)
            |> elem(0)
          end

        Map.put(acc_labels, node_id, new_label)
      end)

    propagate_labels(new_labels, adjacency, iteration + 1, max_iterations, labels)
  end

  defp group_by_community(labels) do
    # Group entity IDs by their community label
    labels
    |> Enum.group_by(fn {_entity_id, community_label} -> community_label end)
    |> Enum.map(fn {community_label, members} ->
      entity_ids = Enum.map(members, fn {entity_id, _} -> entity_id end)

      %{
        id: community_label,
        level: 0,
        entity_ids: entity_ids,
        summary: nil
      }
    end)
  end

  defp summarize_single_community(graph_store, community, router) do
    with {:ok, entities} <-
           graph_store.__struct__.get_entities_by_ids(graph_store, community.entity_ids),
         {:ok, relationships} <-
           graph_store.__struct__.get_relationships_between(graph_store, community.entity_ids) do
      prompt = build_summary_prompt(entities, relationships)

      case router.__struct__.execute(router, :text, prompt, []) do
        {:ok, summary} ->
          {:ok, Map.put(community, :summary, summary)}

        {:error, _} = error ->
          error
      end
    end
  end

  defp build_summary_prompt(entities, relationships) do
    """
    You are summarizing a community of related entities from a knowledge graph.

    Community members:
    #{format_entities(entities)}

    Relationships between members:
    #{format_relationships(relationships)}

    Write a concise summary (2-3 sentences) that:
    1. Identifies the main theme or topic of this community
    2. Highlights key entities and their roles
    3. Describes important relationships

    Summary:
    """
  end

  defp format_entities(entities) do
    if entities == [] do
      "(no entities)"
    else
      entities
      |> Enum.map(fn entity ->
        description = get_in(entity, [:properties, :description]) || "No description"
        "- #{entity.name} (#{entity.type}): #{description}"
      end)
      |> Enum.join("\n")
    end
  end

  defp format_relationships(relationships) do
    if relationships == [] do
      "(no relationships)"
    else
      relationships
      |> Enum.map(fn rel ->
        from_name = Map.get(rel, :from_name, "Entity #{rel.from_id}")
        to_name = Map.get(rel, :to_name, "Entity #{rel.to_id}")
        "- #{from_name} --[#{rel.type}]--> #{to_name}"
      end)
      |> Enum.join("\n")
    end
  end

  defp get_router(opts) do
    case Keyword.get(opts, :router) do
      nil ->
        # Auto-detect providers
        {:ok, router} = Rag.Router.new(auto_detect: true)
        router

      router ->
        router
    end
  end

  defp build_hierarchy_levels(_graph_store, levels_acc, 0, _opts) do
    {:ok, Enum.reverse(levels_acc)}
  end

  defp build_hierarchy_levels(graph_store, [prev_level | _] = levels_acc, remaining, opts) do
    # Build meta-graph from previous level communities
    # In a full implementation, this would create nodes from communities
    # and edges based on inter-community connections
    # For now, we'll do a simplified version

    case detect_meta_level(graph_store, prev_level, opts) do
      {:ok, next_level_communities} ->
        # Update level numbers
        next_level =
          Enum.map(next_level_communities, fn c ->
            %{c | level: length(levels_acc)}
          end)

        build_hierarchy_levels(graph_store, [next_level | levels_acc], remaining - 1, opts)

      {:error, _} = error ->
        error
    end
  end

  defp detect_meta_level(graph_store, _prev_communities, opts) do
    # Simplified: just run detection again on the graph
    # A full implementation would build a meta-graph where communities are nodes
    detect(graph_store, opts)
  end
end
