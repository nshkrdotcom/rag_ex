defmodule Rag.Retriever.Graph do
  @moduledoc """
  Graph-enhanced retrieval for GraphRAG.

  Supports three search modes:
  - :local - Find entities via vector search, expand via graph traversal
  - :global - Search community summaries for broad context
  - :hybrid - Combine local and global with weighted fusion

  ## Local Search

  Local search finds specific, detailed information by:
  1. Vector search on entity embeddings to find seed entities
  2. Graph traversal to expand to related entities (configurable depth)
  3. Collecting source chunks from all discovered entities
  4. Scoring by relevance and graph distance

  ## Global Search

  Global search finds high-level context by:
  1. Vector search on community summaries
  2. Returning summaries of relevant communities
  3. Providing broad organizational context

  ## Hybrid Search

  Hybrid search combines both approaches:
  1. Runs local and global searches in parallel
  2. Applies weighted Reciprocal Rank Fusion (RRF)
  3. Deduplicates and returns merged results

  ## Usage

      # Create a graph retriever with local search
      retriever = Graph.new(
        graph_store: graph_store,
        vector_store: vector_store,
        mode: :local,
        depth: 2
      )

      # Search with embedding
      {:ok, results} = Retriever.retrieve(retriever, query_embedding, limit: 10)

      # Or use specific search modes
      {:ok, local_results} = Graph.local_search(retriever, query_embedding)
      {:ok, global_results} = Graph.global_search(retriever, query_embedding)
      {:ok, hybrid_results} = Graph.hybrid_search(retriever, query_embedding)

  ## Options

  - `:mode` - Search mode: `:local`, `:global`, or `:hybrid` (default: `:local`)
  - `:depth` - Traversal depth for local search (default: 2)
  - `:local_weight` - Weight for local results in hybrid mode (default: 1.0)
  - `:global_weight` - Weight for global results in hybrid mode (default: 1.0)
  - `:embedding_fn` - Function to embed text queries `(String.t() -> {:ok, [float()]})`
  - `:limit` - Maximum number of results to return

  """

  @behaviour Rag.Retriever

  defstruct [
    :graph_store,
    :vector_store,
    :mode,
    :depth,
    :local_weight,
    :global_weight
  ]

  @type t :: %__MODULE__{
          graph_store: module(),
          vector_store: module(),
          mode: :local | :global | :hybrid,
          depth: pos_integer(),
          local_weight: float(),
          global_weight: float()
        }

  @default_mode :local
  @default_depth 2
  @default_limit 10
  @default_weight 1.0
  @rrf_k 60

  @doc """
  Create a new Graph retriever.

  ## Options

  - `:graph_store` - Graph store module (required)
  - `:vector_store` - Vector store module (required)
  - `:mode` - Search mode: `:local`, `:global`, or `:hybrid` (default: `:local`)
  - `:depth` - Traversal depth for local search (default: 2)
  - `:local_weight` - Weight for local results in hybrid (default: 1.0)
  - `:global_weight` - Weight for global results in hybrid (default: 1.0)

  ## Examples

      iex> Graph.new(graph_store: MyGraphStore, vector_store: MyVectorStore)
      %Graph{mode: :local, depth: 2, ...}

      iex> Graph.new(
      ...>   graph_store: MyGraphStore,
      ...>   vector_store: MyVectorStore,
      ...>   mode: :hybrid,
      ...>   local_weight: 0.7,
      ...>   global_weight: 0.3
      ...> )
      %Graph{mode: :hybrid, local_weight: 0.7, ...}

  """
  @spec new(opts :: keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      graph_store: Keyword.fetch!(opts, :graph_store),
      vector_store: Keyword.fetch!(opts, :vector_store),
      mode: Keyword.get(opts, :mode, @default_mode),
      depth: Keyword.get(opts, :depth, @default_depth),
      local_weight: Keyword.get(opts, :local_weight, @default_weight),
      global_weight: Keyword.get(opts, :global_weight, @default_weight)
    }
  end

  @doc """
  Retrieve relevant documents using the configured search mode.

  Delegates to the appropriate search function based on the retriever's mode:
  - `:local` -> `local_search/3`
  - `:global` -> `global_search/3`
  - `:hybrid` -> `hybrid_search/3`

  ## Parameters

  - `retriever` - The Graph retriever struct
  - `query` - Query text (string) or embedding vector (list of floats)
  - `opts` - Options including `:limit`, `:embedding_fn`

  ## Returns

  - `{:ok, [result()]}` - List of retrieved results with scores
  - `{:error, term()}` - Error during retrieval

  """
  @impl Rag.Retriever
  @spec retrieve(t(), String.t() | [float()], keyword()) ::
          {:ok, [Rag.Retriever.result()]} | {:error, term()}
  def retrieve(%__MODULE__{mode: mode} = retriever, query, opts \\ []) do
    case mode do
      :local -> local_search(retriever, query, opts)
      :global -> global_search(retriever, query, opts)
      :hybrid -> hybrid_search(retriever, query, opts)
    end
  end

  @doc """
  Local search: vector search -> graph expansion -> chunk retrieval.

  Performs local search by:
  1. Embedding the query if it's text
  2. Finding seed entities via vector search
  3. Expanding via graph traversal (BFS)
  4. Collecting source chunks from all entities
  5. Scoring and ranking by relevance and graph distance

  ## Parameters

  - `retriever` - The Graph retriever struct
  - `query` - Query text or embedding vector
  - `opts` - Options:
    - `:limit` - Max results (default: 10)
    - `:embedding_fn` - Function to embed text queries
    - `:depth` - Override traversal depth

  ## Returns

  - `{:ok, [result()]}` - Chunks with scores
  - `{:error, term()}` - Error during search

  ## Examples

      iex> Graph.local_search(retriever, query_embedding, limit: 5)
      {:ok, [%{id: 1, content: "...", score: 0.9, metadata: %{}}]}

  """
  @spec local_search(retriever :: t(), query :: String.t() | [float()], opts :: keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def local_search(retriever, query, opts \\ [])

  def local_search(%__MODULE__{} = retriever, query, opts) when is_binary(query) do
    case get_embedding(query, opts) do
      {:ok, embedding} -> do_local_search(retriever, embedding, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  def local_search(%__MODULE__{} = retriever, embedding, opts) when is_list(embedding) do
    do_local_search(retriever, embedding, opts)
  end

  @doc """
  Global search: find relevant communities -> get summaries.

  Performs global search by:
  1. Embedding the query if it's text
  2. Vector search on community summaries
  3. Returning community summaries as context

  ## Parameters

  - `retriever` - The Graph retriever struct
  - `query` - Query text or embedding vector
  - `opts` - Options:
    - `:limit` - Max communities (default: 10)
    - `:embedding_fn` - Function to embed text queries

  ## Returns

  - `{:ok, [result()]}` - Community summaries with scores
  - `{:error, term()}` - Error during search

  ## Examples

      iex> Graph.global_search(retriever, query_embedding, limit: 5)
      {:ok, [%{id: "comm_1", content: "Summary...", score: 0.85, metadata: %{}}]}

  """
  @spec global_search(retriever :: t(), query :: String.t() | [float()], opts :: keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def global_search(retriever, query, opts \\ [])

  def global_search(%__MODULE__{} = retriever, query, opts) when is_binary(query) do
    case get_embedding(query, opts) do
      {:ok, embedding} -> do_global_search(retriever, embedding, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  def global_search(%__MODULE__{} = retriever, embedding, opts) when is_list(embedding) do
    do_global_search(retriever, embedding, opts)
  end

  @doc """
  Hybrid search: combine local and global with RRF.

  Performs hybrid search by:
  1. Running local and global searches in parallel (using Task.async)
  2. Applying weighted Reciprocal Rank Fusion (RRF)
  3. Deduplicating and merging results
  4. Returning sorted by combined score

  ## Parameters

  - `retriever` - The Graph retriever struct
  - `query` - Query text or embedding vector
  - `opts` - Options:
    - `:limit` - Max results (default: 10)
    - `:embedding_fn` - Function to embed text queries

  ## Returns

  - `{:ok, [result()]}` - Combined results with RRF scores
  - `{:error, term()}` - Error during search

  ## Examples

      iex> Graph.hybrid_search(retriever, query_embedding, limit: 10)
      {:ok, [%{id: 1, content: "...", score: 0.95, metadata: %{}}]}

  """
  @spec hybrid_search(retriever :: t(), query :: String.t() | [float()], opts :: keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def hybrid_search(retriever, query, opts \\ [])

  def hybrid_search(%__MODULE__{} = retriever, query, opts) when is_binary(query) do
    case get_embedding(query, opts) do
      {:ok, embedding} -> do_hybrid_search(retriever, embedding, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  def hybrid_search(%__MODULE__{} = retriever, embedding, opts) when is_list(embedding) do
    do_hybrid_search(retriever, embedding, opts)
  end

  @doc """
  Returns true - Graph retriever supports embedding queries.
  """
  @impl Rag.Retriever
  @spec supports_embedding?() :: boolean()
  def supports_embedding?, do: true

  @doc """
  Returns true - Graph retriever supports text queries (with embedding_fn).
  """
  @impl Rag.Retriever
  @spec supports_text_query?() :: boolean()
  def supports_text_query?, do: true

  # Private functions

  defp do_local_search(retriever, embedding, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    depth = Keyword.get(opts, :depth, retriever.depth)

    with {:ok, seed_entities} <- vector_search_entities(retriever.graph_store, embedding, limit),
         {:ok, expanded_entities} <- expand_entities(retriever.graph_store, seed_entities, depth),
         {:ok, chunks} <- fetch_chunks(retriever.vector_store, expanded_entities) do
      results = score_and_rank_chunks(chunks, expanded_entities, limit)
      {:ok, results}
    end
  end

  defp do_global_search(retriever, embedding, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    case search_communities(retriever.graph_store, embedding, limit) do
      {:ok, communities} ->
        results = format_community_results(communities)
        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_hybrid_search(retriever, embedding, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    # Run local and global searches in parallel
    local_task = Task.async(fn -> do_local_search(retriever, embedding, opts) end)
    global_task = Task.async(fn -> do_global_search(retriever, embedding, opts) end)

    local_results =
      case Task.await(local_task, 30_000) do
        {:ok, results} -> results
        {:error, _} -> []
      end

    global_results =
      case Task.await(global_task, 30_000) do
        {:ok, results} -> results
        {:error, _} -> []
      end

    # Apply weighted RRF fusion
    merged_results =
      combine_with_rrf(
        local_results,
        global_results,
        retriever.local_weight,
        retriever.global_weight,
        limit
      )

    {:ok, merged_results}
  end

  defp vector_search_entities(graph_store, embedding, limit) do
    # Call the module function directly
    apply(graph_store.__struct__, :vector_search, [graph_store, embedding, [limit: limit]])
  end

  defp expand_entities(_graph_store, [], _depth), do: {:ok, []}

  defp expand_entities(graph_store, seed_entities, depth) do
    # Traverse from each seed entity and collect all reachable entities
    module = graph_store.__struct__

    # Try to traverse from each seed entity
    results =
      Enum.map(seed_entities, fn entity ->
        apply(module, :traverse, [graph_store, entity.id, [max_depth: depth]])
      end)

    # Check if any traversal returned an error
    error_result = Enum.find(results, fn result -> match?({:error, _}, result) end)

    case error_result do
      {:error, reason} ->
        # Propagate the first error encountered
        {:error, reason}

      nil ->
        # All traversals succeeded, collect and deduplicate entities
        expanded =
          results
          |> Enum.flat_map(fn {:ok, traversed} -> traversed end)
          |> Enum.uniq_by(& &1.id)

        if expanded == [] do
          # If no entities were found, return seeds with depth 0
          {:ok, seed_entities |> Enum.map(&Map.put(&1, :depth, 0))}
        else
          {:ok, expanded}
        end
    end
  end

  defp fetch_chunks(_vector_store, []), do: {:ok, []}

  defp fetch_chunks(vector_store, entities) do
    # Collect all unique chunk IDs from entities
    chunk_ids =
      entities
      |> Enum.flat_map(fn entity ->
        Map.get(entity, :source_chunk_ids, [])
      end)
      |> Enum.uniq()

    if chunk_ids == [] do
      {:ok, []}
    else
      module = vector_store.__struct__
      apply(module, :get_chunks_by_ids, [vector_store, chunk_ids])
    end
  end

  defp score_and_rank_chunks(chunks, entities, limit) do
    # Create a map of chunk_id -> depth for scoring
    depth_map =
      entities
      |> Enum.flat_map(fn entity ->
        depth = Map.get(entity, :depth, 0)

        entity
        |> Map.get(:source_chunk_ids, [])
        |> Enum.map(fn chunk_id -> {chunk_id, depth} end)
      end)
      |> Enum.into(%{}, fn {chunk_id, depth} ->
        # If a chunk appears at multiple depths, keep the minimum
        {chunk_id, depth}
      end)
      |> Enum.group_by(fn {chunk_id, _depth} -> chunk_id end, fn {_chunk_id, depth} -> depth end)
      |> Enum.map(fn {chunk_id, depths} -> {chunk_id, Enum.min(depths)} end)
      |> Enum.into(%{})

    chunks
    |> Enum.map(fn chunk ->
      depth = Map.get(depth_map, chunk.id, 0)
      # Score: closer entities (lower depth) get higher scores
      # Use 1.0 / (1.0 + depth) to ensure scores are between 0 and 1
      score = 1.0 / (1.0 + depth)

      %{
        id: chunk.id,
        content: chunk.content,
        score: score,
        metadata: Map.merge(chunk.metadata || %{}, %{graph_depth: depth})
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  defp search_communities(graph_store, embedding, limit) do
    module = graph_store.__struct__
    apply(module, :search_communities, [graph_store, embedding, [limit: limit]])
  end

  defp format_community_results(communities) do
    communities
    |> Enum.with_index()
    |> Enum.map(fn {community, rank} ->
      # Score based on rank (higher rank = lower score)
      score = 1.0 / (1.0 + rank)

      %{
        id: "community_#{community.id}",
        content: community.summary,
        score: score,
        metadata: %{
          community_id: community.id,
          level: community.level,
          entity_count: length(community.entity_ids)
        }
      }
    end)
  end

  defp combine_with_rrf(local_results, global_results, local_weight, global_weight, limit) do
    # Calculate RRF scores for local results
    local_scored =
      local_results
      |> Enum.with_index()
      |> Enum.map(fn {result, rank} ->
        rrf_score = local_weight / (@rrf_k + rank)
        {result, rrf_score}
      end)

    # Calculate RRF scores for global results
    global_scored =
      global_results
      |> Enum.with_index()
      |> Enum.map(fn {result, rank} ->
        rrf_score = global_weight / (@rrf_k + rank)
        {result, rrf_score}
      end)

    # Combine and deduplicate by ID
    all_results = local_scored ++ global_scored

    all_results
    |> Enum.reduce(%{}, fn {result, rrf_score}, acc ->
      key = result.id

      Map.update(acc, key, {result, rrf_score}, fn {existing_result, existing_score} ->
        # Merge scores, keep first result encountered
        {existing_result, existing_score + rrf_score}
      end)
    end)
    |> Map.values()
    |> Enum.map(fn {result, rrf_score} ->
      Map.put(result, :score, rrf_score)
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  defp get_embedding(text, opts) do
    case Keyword.get(opts, :embedding_fn) do
      nil ->
        {:error, :embedding_fn_required}

      embedding_fn when is_function(embedding_fn, 1) ->
        embedding_fn.(text)
    end
  end
end
