defmodule Rag.GraphStore.TripleStore do
  @moduledoc """
  RocksDB-backed TripleStore implementation of the GraphStore behaviour.

  Adapts RDF triples to the Property Graph API for fast traversal and
  flexible metadata storage.
  """

  @behaviour Rag.GraphStore

  alias Rag.GraphStore.TripleStore.{Mapper, Traversal}
  alias Rag.GraphStore.TripleStore.URI, as: TSURI
  alias TripleStore.Adapter
  alias TripleStore.Dictionary
  alias TripleStore.Dictionary.StringToId
  alias TripleStore.Index
  alias TripleStore.Backend.RocksDB.NIF

  defstruct [:db, :manager, :data_dir, :vector_store]

  @type t :: %__MODULE__{
          db: reference(),
          manager: GenServer.server(),
          data_dir: String.t(),
          vector_store: struct() | nil
        }

  @id_table :triplestore_ids
  @default_limit 10
  @default_max_depth 2
  @default_traverse_limit 100

  @doc """
  Open a TripleStore at the given data directory.
  """
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    vector_store = Keyword.get(opts, :vector_store)

    ensure_id_table()

    with :ok <- File.mkdir_p(data_dir),
         {:ok, db} <- NIF.open(data_dir),
         {:ok, manager} <- Dictionary.Manager.start_link(db: db) do
      {:ok,
       %__MODULE__{
         db: db,
         manager: manager,
         data_dir: data_dir,
         vector_store: vector_store
       }}
    end
  end

  @doc """
  Close the TripleStore and release resources.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{db: db, manager: manager}) do
    stop_manager(manager)

    NIF.close(db)
    :ok
  end

  defp stop_manager(nil), do: :ok

  defp stop_manager(manager) do
    try do
      Dictionary.Manager.stop(manager)
    catch
      :exit, :noproc -> :ok
      :exit, {:noproc, _} -> :ok
    end
  end

  @doc """
  Create a new node in the graph.
  """
  @impl Rag.GraphStore
  @spec create_node(t(), map()) :: {:ok, Rag.GraphStore.graph_node()} | {:error, term()}
  def create_node(store, attrs) do
    with :ok <- validate_node_attrs(attrs),
         id <- node_id(attrs),
         normalized <- normalize_node_attrs(attrs),
         triples <- Mapper.node_to_triples(normalized, id),
         :ok <- insert_triples(store, triples) do
      {:ok, build_node_response(normalized, id)}
    end
  end

  @doc """
  Retrieve a node by ID.
  """
  @impl Rag.GraphStore
  @spec get_node(t(), term()) :: {:ok, Rag.GraphStore.graph_node()} | {:error, :not_found}
  def get_node(store, id) do
    case lookup_entity_term_id(store, id) do
      {:ok, term_id} ->
        triples = get_entity_triples(store, term_id)

        if triples == [] do
          {:error, :not_found}
        else
          {:ok, Mapper.triples_to_node(id, triples)}
        end

      :not_found ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Create an edge between two nodes.
  """
  @impl Rag.GraphStore
  @spec create_edge(t(), map()) :: {:ok, Rag.GraphStore.edge()} | {:error, term()}
  def create_edge(store, attrs) do
    with :ok <- validate_edge_attrs(attrs),
         :ok <- verify_entities_exist(store, attrs.from_id, attrs.to_id),
         id <- edge_id(attrs),
         normalized <- normalize_edge_attrs(attrs),
         triples <- Mapper.edge_to_triples(normalized, id),
         :ok <- insert_triples(store, triples) do
      {:ok, build_edge_response(normalized, id)}
    end
  end

  @doc """
  Find neighboring nodes.
  """
  @impl Rag.GraphStore
  @spec find_neighbors(t(), term(), keyword()) ::
          {:ok, [Rag.GraphStore.graph_node()]} | {:error, term()}
  def find_neighbors(store, node_id, opts \\ []) do
    direction = Keyword.get(opts, :direction, :both)
    edge_type = Keyword.get(opts, :edge_type)
    limit = Keyword.get(opts, :limit, @default_limit)

    case lookup_entity_term_id(store, node_id) do
      {:ok, term_id} ->
        neighbors = Traversal.get_neighbors(store.db, term_id, direction, edge_type)

        nodes =
          neighbors
          |> Enum.take(limit)
          |> Enum.map(&term_id_to_node(store, &1))
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(fn {:ok, node} -> node end)

        {:ok, nodes}

      :not_found ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Traverse the graph from a starting node.
  """
  @impl Rag.GraphStore
  @spec traverse(t(), term(), keyword()) ::
          {:ok, [Rag.GraphStore.graph_node()]} | {:error, term()}
  def traverse(store, start_id, opts \\ []) do
    algorithm = Keyword.get(opts, :algorithm, :bfs)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    limit = Keyword.get(opts, :limit, @default_traverse_limit)

    case lookup_entity_term_id(store, start_id) do
      {:ok, start_term_id} ->
        results =
          case algorithm do
            :dfs -> Traversal.dfs(store.db, start_term_id, max_depth, opts)
            _ -> Traversal.bfs(store.db, start_term_id, max_depth, opts)
          end

        nodes =
          results
          |> Enum.take(limit)
          |> Enum.map(fn {term_id, depth} ->
            case term_id_to_node(store, term_id) do
              {:ok, node} -> Map.put(node, :depth, depth)
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, nodes}

      :not_found ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Perform vector search by delegating to the configured VectorStore.
  """
  @impl Rag.GraphStore
  @spec vector_search(t(), [float()], keyword()) ::
          {:ok, [Rag.GraphStore.graph_node()]} | {:error, term()}
  def vector_search(store, embedding, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    type_filter = Keyword.get(opts, :type)

    if is_nil(store.vector_store) do
      {:error, :vector_store_not_configured}
    else
      vector_store = store.vector_store
      module = vector_store.__struct__

      with {:ok, chunks} <- apply(module, :search, [vector_store, embedding, [limit: limit * 2]]),
           chunk_ids <- Enum.map(chunks, & &1.id),
           {:ok, entities} <- find_entities_by_chunk_ids(store, chunk_ids) do
        entities =
          entities
          |> maybe_filter_by_type(type_filter)
          |> Enum.take(limit)

        {:ok, entities}
      end
    end
  end

  @doc """
  Create a community of related entities.
  """
  @impl Rag.GraphStore
  @spec create_community(t(), map()) :: {:ok, Rag.GraphStore.community()} | {:error, term()}
  def create_community(store, attrs) do
    with :ok <- validate_community_attrs(attrs),
         id <- community_id(attrs),
         normalized <- normalize_community_attrs(attrs),
         triples <- Mapper.community_to_triples(normalized, id),
         :ok <- insert_triples(store, triples) do
      {:ok, build_community_response(normalized, id)}
    end
  end

  @doc """
  Get all members of a community.
  """
  @impl Rag.GraphStore
  @spec get_community_members(t(), term()) ::
          {:ok, [Rag.GraphStore.graph_node()]} | {:error, term()}
  def get_community_members(store, community_id) do
    community_uri = TSURI.community(community_id)
    has_member_uri = TSURI.rel(:has_member)

    with {:ok, community_term_id} <- lookup_term_id(store, community_uri),
         {:ok, has_member_term_id} <- lookup_term_id(store, has_member_uri),
         {:ok, stream} <-
           Index.lookup(
             store.db,
             {{:bound, community_term_id}, {:bound, has_member_term_id}, :var}
           ) do
      nodes =
        stream
        |> Stream.map(fn {_s, _p, o} -> o end)
        |> Enum.map(&term_id_to_node(store, &1))
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, node} -> node end)

      {:ok, nodes}
    else
      :not_found -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
  Update a community summary.
  """
  @impl Rag.GraphStore
  @spec update_community_summary(t(), term(), String.t()) ::
          {:ok, Rag.GraphStore.community()} | {:error, term()}
  def update_community_summary(store, community_id, summary) do
    community_uri = TSURI.community(community_id)
    summary_prop_uri = TSURI.prop(:summary)

    with {:ok, community_term_id} <- lookup_term_id(store, community_uri),
         {:ok, summary_prop_term_id} <- get_or_create_term_id(store, summary_prop_uri),
         {:ok, stream} <-
           Index.lookup(
             store.db,
             {{:bound, community_term_id}, {:bound, summary_prop_term_id}, :var}
           ),
         {:ok, summary_literal_id} <- get_or_create_term_id(store, RDF.literal(summary)) do
      Enum.each(stream, &Index.delete_triple(store.db, &1))

      :ok =
        Index.insert_triple(
          store.db,
          {community_term_id, summary_prop_term_id, summary_literal_id}
        )

      case get_community(store, community_id) do
        {:ok, community} -> {:ok, %{community | summary: summary}}
        _ -> {:ok, %{id: community_id, summary: summary}}
      end
    else
      :not_found -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp validate_node_attrs(attrs) do
    cond do
      is_nil(attrs[:type]) ->
        {:error, :type_required}

      is_nil(attrs[:name]) ->
        {:error, :name_required}

      attrs[:properties] != nil and not is_map(attrs[:properties]) ->
        {:error, :invalid_properties}

      true ->
        :ok
    end
  end

  defp validate_edge_attrs(attrs) do
    weight = Map.get(attrs, :weight, 1.0)

    cond do
      is_nil(attrs[:from_id]) -> {:error, :from_id_required}
      is_nil(attrs[:to_id]) -> {:error, :to_id_required}
      is_nil(attrs[:type]) -> {:error, :type_required}
      attrs[:from_id] == attrs[:to_id] -> {:error, :self_loop_not_allowed}
      not valid_weight?(weight) -> {:error, :invalid_weight}
      true -> :ok
    end
  end

  defp validate_community_attrs(attrs) do
    entity_ids = attrs[:entity_ids]

    cond do
      is_nil(entity_ids) or entity_ids == [] -> {:error, :entity_ids_required}
      not is_list(entity_ids) -> {:error, :entity_ids_required}
      true -> :ok
    end
  end

  defp valid_weight?(weight) when is_float(weight) and weight >= 0.0 and weight <= 1.0, do: true
  defp valid_weight?(weight) when is_integer(weight) and weight >= 0 and weight <= 1, do: true
  defp valid_weight?(_weight), do: false

  defp verify_entities_exist(store, from_id, to_id) do
    with {:ok, _} <- get_node(store, from_id),
         {:ok, _} <- get_node(store, to_id) do
      :ok
    else
      {:error, :not_found} -> {:error, :entity_not_found}
    end
  end

  defp normalize_node_attrs(attrs) do
    attrs
    |> Map.update(:properties, %{}, fn
      nil -> %{}
      props -> props
    end)
    |> Map.update(:source_chunk_ids, [], fn
      nil -> []
      ids -> ids
    end)
  end

  defp normalize_edge_attrs(attrs) do
    attrs
    |> Map.update(:properties, %{}, fn
      nil -> %{}
      props -> props
    end)
    |> Map.update(:weight, 1.0, fn
      nil -> 1.0
      value -> value
    end)
  end

  defp normalize_community_attrs(attrs) do
    attrs
    |> Map.put_new(:level, 0)
    |> Map.put_new(:entity_ids, [])
  end

  defp build_node_response(attrs, id) do
    %{
      id: id,
      type: normalize_type(attrs.type),
      name: attrs.name,
      properties: Map.get(attrs, :properties, %{}),
      embedding: attrs[:embedding],
      source_chunk_ids: Map.get(attrs, :source_chunk_ids, [])
    }
  end

  defp build_edge_response(attrs, id) do
    %{
      id: id,
      from_id: attrs.from_id,
      to_id: attrs.to_id,
      type: normalize_type(attrs.type),
      weight: Map.get(attrs, :weight, 1.0),
      properties: Map.get(attrs, :properties, %{})
    }
  end

  defp build_community_response(attrs, id) do
    %{
      id: id,
      level: Map.get(attrs, :level, 0),
      summary: Map.get(attrs, :summary),
      entity_ids: Map.get(attrs, :entity_ids, [])
    }
  end

  defp normalize_type(type) when is_atom(type), do: type
  defp normalize_type(type) when is_binary(type), do: String.to_atom(type)
  defp normalize_type(type), do: type

  defp node_id(attrs) do
    case Map.get(attrs, :id) do
      nil -> next_id(:entity)
      id -> sync_id_counter(:entity, id)
    end
  end

  defp edge_id(attrs) do
    case Map.get(attrs, :id) do
      nil -> next_id(:edge)
      id -> sync_id_counter(:edge, id)
    end
  end

  defp community_id(attrs) do
    case Map.get(attrs, :id) do
      nil -> next_id(:community)
      id -> sync_id_counter(:community, id)
    end
  end

  defp insert_triples(store, rdf_triples) do
    terms = Enum.flat_map(rdf_triples, fn {s, p, o} -> [s, p, o] end)

    case Adapter.terms_to_ids(store.manager, terms) do
      {:ok, ids} ->
        triples =
          ids
          |> Enum.chunk_every(3)
          |> Enum.map(fn [s, p, o] -> {s, p, o} end)

        Index.insert_triples(store.db, triples)

      {:error, _} = error ->
        error
    end
  end

  defp lookup_term_id(store, uri) when is_binary(uri) do
    StringToId.lookup_id(store.db, RDF.iri(uri))
  end

  defp lookup_entity_term_id(store, entity_id) do
    lookup_term_id(store, TSURI.entity(entity_id))
  end

  defp get_or_create_term_id(store, uri) when is_binary(uri) do
    Dictionary.Manager.get_or_create_id(store.manager, RDF.iri(uri))
  end

  defp get_or_create_term_id(store, %RDF.Literal{} = literal) do
    Dictionary.Manager.get_or_create_id(store.manager, literal)
  end

  defp get_entity_triples(store, term_id) do
    case Index.lookup(store.db, {{:bound, term_id}, :var, :var}) do
      {:ok, stream} ->
        stream
        |> Enum.map(&decode_triple(store, &1))
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp decode_triple(store, {s, p, o}) do
    with {:ok, s_term} <- Dictionary.IdToString.lookup_term(store.db, s),
         {:ok, p_term} <- Dictionary.IdToString.lookup_term(store.db, p),
         {:ok, o_term} <- Dictionary.IdToString.lookup_term(store.db, o) do
      {s_term, p_term, o_term}
    else
      _ -> nil
    end
  end

  defp term_id_to_node(store, term_id) do
    case Dictionary.IdToString.lookup_term(store.db, term_id) do
      {:ok, %RDF.IRI{value: uri}} ->
        case TSURI.parse(uri) do
          {:ok, {:entity, id}} -> get_node(store, id)
          _ -> {:error, :not_an_entity}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp find_entities_by_chunk_ids(_store, []), do: {:ok, []}

  defp find_entities_by_chunk_ids(store, chunk_ids) do
    source_chunks_uri = TSURI.meta(:source_chunk_ids)

    case lookup_term_id(store, source_chunks_uri) do
      {:ok, prop_term_id} ->
        case Index.lookup(store.db, {:var, {:bound, prop_term_id}, :var}) do
          {:ok, stream} ->
            entities =
              stream
              |> Stream.filter(fn {_s, _p, o} ->
                case Dictionary.IdToString.lookup_term(store.db, o) do
                  {:ok, %RDF.Literal{} = lit} ->
                    case RDF.Literal.value(lit) do
                      value when is_binary(value) ->
                        case Jason.decode(value) do
                          {:ok, ids} when is_list(ids) -> Enum.any?(chunk_ids, &(&1 in ids))
                          _ -> false
                        end

                      _ ->
                        false
                    end

                  _ ->
                    false
                end
              end)
              |> Stream.map(fn {s, _p, _o} -> s end)
              |> Enum.uniq()
              |> Enum.map(&term_id_to_node(store, &1))
              |> Enum.filter(&match?({:ok, _}, &1))
              |> Enum.map(fn {:ok, node} -> node end)

            {:ok, entities}

          {:error, _} = error ->
            error
        end

      :not_found ->
        {:ok, []}

      {:error, _} = error ->
        error
    end
  end

  defp maybe_filter_by_type(entities, nil), do: entities

  defp maybe_filter_by_type(entities, type) do
    target = normalize_type(type)

    Enum.filter(entities, fn entity -> normalize_type(entity.type) == target end)
  end

  defp get_community(store, community_id) do
    case lookup_term_id(store, TSURI.community(community_id)) do
      {:ok, term_id} ->
        triples = get_entity_triples(store, term_id)

        if triples == [] do
          {:error, :not_found}
        else
          {:ok, community_from_triples(community_id, triples)}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp community_from_triples(id, triples) do
    base = %{id: id, level: 0, summary: nil, entity_ids: []}
    level_prop = TSURI.prop(:level)
    summary_prop = TSURI.prop(:summary)
    has_member_rel = TSURI.rel(:has_member)

    Enum.reduce(triples, base, fn {_s, p, o}, acc ->
      case iri_value(p) do
        value when value == level_prop ->
          %{acc | level: literal_value(o)}

        value when value == summary_prop ->
          %{acc | summary: literal_value(o)}

        value when value == has_member_rel ->
          case iri_value(o) do
            nil ->
              acc

            uri ->
              case TSURI.parse(uri) do
                {:ok, {:entity, entity_id}} ->
                  %{acc | entity_ids: [entity_id | acc.entity_ids]}

                _ ->
                  acc
              end
          end

        _ ->
          acc
      end
    end)
    |> Map.update!(:entity_ids, &Enum.reverse/1)
  end

  defp iri_value(%RDF.IRI{value: value}), do: value
  defp iri_value(_term), do: nil

  defp literal_value(%RDF.Literal{} = literal), do: RDF.Literal.value(literal)
  defp literal_value(value), do: value

  defp next_id(type) do
    ensure_id_table()
    :ets.update_counter(@id_table, type, {2, 1}, {type, 0})
  end

  defp sync_id_counter(type, id) when is_integer(id) do
    ensure_id_table()

    case :ets.lookup(@id_table, type) do
      [{^type, current}] when id > current ->
        :ets.insert(@id_table, {type, id})

      [] ->
        :ets.insert(@id_table, {type, id})

      _ ->
        :ok
    end

    id
  end

  defp sync_id_counter(_type, id), do: id

  defp ensure_id_table do
    case :ets.whereis(@id_table) do
      :undefined ->
        try do
          :ets.new(@id_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

        :ok

      _ ->
        :ok
    end
  end
end
