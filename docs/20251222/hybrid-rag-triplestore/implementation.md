# Implementation Guide: Rag.GraphStore.TripleStore

## Overview

This guide provides step-by-step instructions for implementing the `Rag.GraphStore.TripleStore` module, which adapts the RDF-based TripleStore to the Property Graph API expected by rag_ex.

## Prerequisites

1. **TripleStore dependency** added to `mix.exs`:
   ```elixir
   {:triple_store, path: "./triple_store"}
   ```

2. **Rust toolchain** installed for NIF compilation

3. **RocksDB** libraries available on the system

## Module Structure

```
lib/rag/graph_store/
├── triple_store.ex              # Main implementation
└── triple_store/
    ├── uri.ex                   # URI generation and parsing
    ├── mapper.ex                # Property Graph ↔ RDF conversion
    ├── traversal.ex             # BFS/DFS algorithms
    └── supervisor.ex            # OTP supervision
```

## Step 1: URI Module

Create the URI generation and parsing utilities:

```elixir
# lib/rag/graph_store/triple_store/uri.ex
defmodule Rag.GraphStore.TripleStore.URI do
  @moduledoc """
  URI generation and parsing for Property Graph to RDF mapping.
  """

  @entity_prefix "urn:entity:"
  @type_prefix "urn:type:"
  @rel_prefix "urn:rel:"
  @prop_prefix "urn:prop:"
  @edge_prefix "urn:edge:"
  @community_prefix "urn:community:"
  @meta_prefix "urn:meta:"
  @rdf_type "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

  # URI Generation

  @spec entity(term()) :: String.t()
  def entity(id), do: @entity_prefix <> to_string(id)

  @spec type(atom() | String.t()) :: String.t()
  def type(t) when is_atom(t), do: @type_prefix <> Atom.to_string(t)
  def type(t) when is_binary(t), do: @type_prefix <> t

  @spec rel(atom() | String.t()) :: String.t()
  def rel(r) when is_atom(r), do: @rel_prefix <> Atom.to_string(r)
  def rel(r) when is_binary(r), do: @rel_prefix <> r

  @spec prop(atom() | String.t()) :: String.t()
  def prop(p) when is_atom(p), do: @prop_prefix <> Atom.to_string(p)
  def prop(p) when is_binary(p), do: @prop_prefix <> p

  @spec edge(term()) :: String.t()
  def edge(id), do: @edge_prefix <> to_string(id)

  @spec community(term()) :: String.t()
  def community(id), do: @community_prefix <> to_string(id)

  @spec meta(atom() | String.t()) :: String.t()
  def meta(m) when is_atom(m), do: @meta_prefix <> Atom.to_string(m)
  def meta(m) when is_binary(m), do: @meta_prefix <> m

  @spec rdf_type() :: String.t()
  def rdf_type, do: @rdf_type

  # URI Parsing

  @spec parse(String.t()) :: {:ok, {atom(), term()}} | {:error, :unknown_uri_scheme}
  def parse(@entity_prefix <> id), do: {:ok, {:entity, parse_id(id)}}
  def parse(@type_prefix <> type), do: {:ok, {:type, type}}
  def parse(@rel_prefix <> rel), do: {:ok, {:rel, rel}}
  def parse(@prop_prefix <> prop), do: {:ok, {:prop, String.to_atom(prop)}}
  def parse(@edge_prefix <> id), do: {:ok, {:edge, parse_id(id)}}
  def parse(@community_prefix <> id), do: {:ok, {:community, parse_id(id)}}
  def parse(@meta_prefix <> meta), do: {:ok, {:meta, String.to_atom(meta)}}
  def parse(@rdf_type), do: {:ok, {:rdf, :type}}
  def parse(_), do: {:error, :unknown_uri_scheme}

  # Predicates

  @spec entity?(String.t()) :: boolean()
  def entity?(@entity_prefix <> _), do: true
  def entity?(_), do: false

  @spec relationship?(String.t()) :: boolean()
  def relationship?(@rel_prefix <> _), do: true
  def relationship?(_), do: false

  @spec property?(String.t()) :: boolean()
  def property?(@prop_prefix <> _), do: true
  def property?(_), do: false

  # Helpers

  defp parse_id(str) do
    case Integer.parse(str) do
      {id, ""} -> id
      _ -> str
    end
  end
end
```

## Step 2: Mapper Module

Create the Property Graph to RDF mapping utilities:

```elixir
# lib/rag/graph_store/triple_store/mapper.ex
defmodule Rag.GraphStore.TripleStore.Mapper do
  @moduledoc """
  Converts between Property Graph structures and RDF triples.
  """

  alias Rag.GraphStore.TripleStore.URI, as: U

  @type triple :: {term_id :: non_neg_integer(), term_id :: non_neg_integer(), term_id :: non_neg_integer()}
  @type graph_node :: Rag.GraphStore.graph_node()
  @type edge :: Rag.GraphStore.edge()

  # Node to Triples

  @spec node_to_triples(map(), term()) :: [RDF.Triple.t()]
  def node_to_triples(attrs, id) do
    entity_uri = RDF.iri(U.entity(id))

    [
      # Type triple
      {entity_uri, RDF.type(), RDF.iri(U.type(attrs.type))},

      # Name triple
      {entity_uri, RDF.iri(U.prop(:name)), RDF.literal(attrs.name)}
    ]
    ++ properties_to_triples(entity_uri, attrs[:properties] || %{})
    ++ source_chunks_triple(entity_uri, attrs[:source_chunk_ids])
    ++ embedding_flag_triple(entity_uri, attrs[:embedding])
  end

  defp properties_to_triples(subject, properties) do
    Enum.map(properties, fn {key, value} ->
      {subject, RDF.iri(U.prop(key)), value_to_literal(value)}
    end)
  end

  defp source_chunks_triple(_subject, nil), do: []
  defp source_chunks_triple(_subject, []), do: []
  defp source_chunks_triple(subject, chunk_ids) do
    [{subject, RDF.iri(U.meta(:source_chunk_ids)), RDF.literal(Jason.encode!(chunk_ids))}]
  end

  defp embedding_flag_triple(_subject, nil), do: []
  defp embedding_flag_triple(subject, _embedding) do
    [{subject, RDF.iri(U.meta(:has_embedding)), RDF.literal("true", datatype: RDF.XSD.Boolean)}]
  end

  @spec value_to_literal(term()) :: RDF.Literal.t()
  def value_to_literal(v) when is_binary(v), do: RDF.literal(v)
  def value_to_literal(v) when is_integer(v), do: RDF.literal(v)
  def value_to_literal(v) when is_float(v), do: RDF.literal(v)
  def value_to_literal(v) when is_boolean(v), do: RDF.literal(v)
  def value_to_literal(%DateTime{} = v), do: RDF.literal(v)
  def value_to_literal(%Decimal{} = v), do: RDF.literal(Decimal.to_string(v))
  def value_to_literal(v) when is_atom(v), do: RDF.literal(Atom.to_string(v))
  def value_to_literal(v) when is_map(v), do: RDF.literal(Jason.encode!(v))
  def value_to_literal(v) when is_list(v), do: RDF.literal(Jason.encode!(v))

  # Triples to Node

  @spec triples_to_node(non_neg_integer(), [RDF.Triple.t()]) :: graph_node()
  def triples_to_node(id, triples) do
    base = %{
      id: id,
      type: nil,
      name: nil,
      properties: %{},
      embedding: nil,
      source_chunk_ids: []
    }

    Enum.reduce(triples, base, fn triple, acc ->
      apply_triple_to_node(acc, triple)
    end)
  end

  defp apply_triple_to_node(node, {_s, p, o}) do
    p_str = to_string(p)

    cond do
      p_str == U.rdf_type() ->
        {:ok, {:type, type}} = U.parse(to_string(o))
        %{node | type: String.to_atom(type)}

      String.starts_with?(p_str, "urn:prop:name") ->
        %{node | name: literal_value(o)}

      String.starts_with?(p_str, "urn:prop:") ->
        {:ok, {:prop, key}} = U.parse(p_str)
        props = Map.put(node.properties, key, literal_value(o))
        %{node | properties: props}

      String.starts_with?(p_str, "urn:meta:source_chunk_ids") ->
        ids = Jason.decode!(literal_value(o))
        %{node | source_chunk_ids: ids}

      true ->
        node
    end
  end

  defp literal_value(%RDF.Literal{} = lit), do: RDF.Literal.value(lit)
  defp literal_value(other), do: to_string(other)

  # Edge to Triple

  @spec edge_to_triples(map(), term()) :: [RDF.Triple.t()]
  def edge_to_triples(attrs, edge_id) do
    from_uri = RDF.iri(U.entity(attrs.from_id))
    to_uri = RDF.iri(U.entity(attrs.to_id))
    rel_uri = RDF.iri(U.rel(attrs.type))

    # Always create the direct edge for traversal
    direct_triple = {from_uri, rel_uri, to_uri}

    if has_edge_properties?(attrs) do
      # Reify the edge for property storage
      edge_uri = RDF.iri(U.edge(edge_id))

      [
        direct_triple,
        {edge_uri, RDF.type(), RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#Statement")},
        {edge_uri, RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#subject"), from_uri},
        {edge_uri, RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#predicate"), rel_uri},
        {edge_uri, RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#object"), to_uri}
      ]
      ++ weight_triple(edge_uri, attrs[:weight])
      ++ properties_to_triples(edge_uri, attrs[:properties] || %{})
    else
      [direct_triple]
    end
  end

  defp has_edge_properties?(attrs) do
    weight = attrs[:weight]
    props = attrs[:properties] || %{}

    (weight != nil and weight != 1.0) or map_size(props) > 0
  end

  defp weight_triple(_subject, nil), do: []
  defp weight_triple(_subject, 1.0), do: []
  defp weight_triple(subject, weight) do
    [{subject, RDF.iri(U.prop(:weight)), RDF.literal(weight)}]
  end

  # Community to Triples

  @spec community_to_triples(map(), term()) :: [RDF.Triple.t()]
  def community_to_triples(attrs, id) do
    community_uri = RDF.iri(U.community(id))

    [
      {community_uri, RDF.type(), RDF.iri(U.type(:community))},
      {community_uri, RDF.iri(U.prop(:level)), RDF.literal(attrs[:level] || 0)}
    ]
    ++ summary_triple(community_uri, attrs[:summary])
    ++ membership_triples(community_uri, attrs[:entity_ids] || [])
  end

  defp summary_triple(_subject, nil), do: []
  defp summary_triple(subject, summary) do
    [{subject, RDF.iri(U.prop(:summary)), RDF.literal(summary)}]
  end

  defp membership_triples(community_uri, entity_ids) do
    Enum.flat_map(entity_ids, fn entity_id ->
      entity_uri = RDF.iri(U.entity(entity_id))
      [
        {community_uri, RDF.iri(U.rel(:has_member)), entity_uri},
        {entity_uri, RDF.iri(U.rel(:member_of)), community_uri}
      ]
    end)
  end
end
```

## Step 3: Traversal Module

Implement BFS and DFS algorithms:

```elixir
# lib/rag/graph_store/triple_store/traversal.ex
defmodule Rag.GraphStore.TripleStore.Traversal do
  @moduledoc """
  Graph traversal algorithms using TripleStore indices.
  """

  alias Rag.GraphStore.TripleStore.URI, as: U

  @doc """
  Breadth-first traversal from a starting node.
  Returns a list of {term_id, depth} tuples.
  """
  @spec bfs(reference(), non_neg_integer(), non_neg_integer(), keyword()) ::
    [{non_neg_integer(), non_neg_integer()}]
  def bfs(db, start_term_id, max_depth, opts \\ []) do
    direction = Keyword.get(opts, :direction, :out)
    edge_type_filter = Keyword.get(opts, :edge_type)

    initial_queue = :queue.from_list([{start_term_id, 0}])
    initial_visited = MapSet.new([start_term_id])

    do_bfs(db, initial_queue, initial_visited, max_depth, direction, edge_type_filter, [])
  end

  defp do_bfs(_db, queue, _visited, _max_depth, _direction, _filter, acc)
       when :queue.is_empty(queue) do
    Enum.reverse(acc)
  end

  defp do_bfs(db, queue, visited, max_depth, direction, filter, acc) do
    {{:value, {current_id, depth}}, rest_queue} = :queue.out(queue)
    acc = [{current_id, depth} | acc]

    if depth >= max_depth do
      do_bfs(db, rest_queue, visited, max_depth, direction, filter, acc)
    else
      neighbors = get_neighbors(db, current_id, direction, filter)

      {new_queue, new_visited} =
        Enum.reduce(neighbors, {rest_queue, visited}, fn neighbor_id, {q, v} ->
          if MapSet.member?(v, neighbor_id) do
            {q, v}
          else
            {:queue.in({neighbor_id, depth + 1}, q), MapSet.put(v, neighbor_id)}
          end
        end)

      do_bfs(db, new_queue, new_visited, max_depth, direction, filter, acc)
    end
  end

  @doc """
  Depth-first traversal from a starting node.
  Returns a list of {term_id, depth} tuples.
  """
  @spec dfs(reference(), non_neg_integer(), non_neg_integer(), keyword()) ::
    [{non_neg_integer(), non_neg_integer()}]
  def dfs(db, start_term_id, max_depth, opts \\ []) do
    direction = Keyword.get(opts, :direction, :out)
    edge_type_filter = Keyword.get(opts, :edge_type)

    do_dfs(db, start_term_id, 0, max_depth, direction, edge_type_filter, MapSet.new(), [])
  end

  defp do_dfs(_db, _current, depth, max_depth, _direction, _filter, _visited, acc)
       when depth > max_depth do
    acc
  end

  defp do_dfs(db, current_id, depth, max_depth, direction, filter, visited, acc) do
    if MapSet.member?(visited, current_id) do
      acc
    else
      visited = MapSet.put(visited, current_id)
      acc = [{current_id, depth} | acc]

      neighbors = get_neighbors(db, current_id, direction, filter)

      Enum.reduce(neighbors, acc, fn neighbor_id, inner_acc ->
        do_dfs(db, neighbor_id, depth + 1, max_depth, direction, filter, visited, inner_acc)
      end)
    end
  end

  @doc """
  Get immediate neighbors of a node.
  """
  @spec get_neighbors(reference(), non_neg_integer(), :in | :out | :both, term()) ::
    [non_neg_integer()]
  def get_neighbors(db, term_id, direction, edge_type_filter \\ nil) do
    patterns = build_patterns(term_id, direction)

    patterns
    |> Enum.flat_map(fn pattern ->
      case TripleStore.Index.lookup(db, pattern) do
        {:ok, stream} ->
          stream
          |> filter_by_edge_type(db, edge_type_filter)
          |> filter_to_entities(db)
          |> extract_neighbor_id(direction, term_id)
          |> Enum.to_list()

        {:error, _} ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp build_patterns(term_id, :out), do: [{{:bound, term_id}, :var, :var}]
  defp build_patterns(term_id, :in), do: [{:var, :var, {:bound, term_id}}]
  defp build_patterns(term_id, :both) do
    [
      {{:bound, term_id}, :var, :var},
      {:var, :var, {:bound, term_id}}
    ]
  end

  defp filter_by_edge_type(stream, _db, nil), do: stream
  defp filter_by_edge_type(stream, db, edge_type) do
    # Get the term ID for the relationship type
    rel_uri = U.rel(edge_type)

    case TripleStore.Dictionary.StringToId.lookup_id(db, {:iri, rel_uri}) do
      {:ok, rel_term_id} ->
        Stream.filter(stream, fn {_s, p, _o} -> p == rel_term_id end)

      :not_found ->
        # Edge type doesn't exist, return empty
        Stream.filter(stream, fn _ -> false end)
    end
  end

  defp filter_to_entities(stream, db) do
    Stream.filter(stream, fn {s, p, o} ->
      # Only include triples where predicate is a relationship (urn:rel:*)
      case TripleStore.Dictionary.IdToString.lookup_term(db, p) do
        {:ok, {:iri, uri}} -> U.relationship?(uri)
        _ -> false
      end
      and
      # Only include triples where object is an entity (urn:entity:*)
      case TripleStore.Dictionary.IdToString.lookup_term(db, o) do
        {:ok, {:iri, uri}} -> U.entity?(uri)
        _ -> false
      end
    end)
  end

  defp extract_neighbor_id(stream, :out, _term_id) do
    Stream.map(stream, fn {_s, _p, o} -> o end)
  end

  defp extract_neighbor_id(stream, :in, _term_id) do
    Stream.map(stream, fn {s, _p, _o} -> s end)
  end

  defp extract_neighbor_id(stream, :both, term_id) do
    Stream.map(stream, fn {s, _p, o} ->
      if s == term_id, do: o, else: s
    end)
  end
end
```

## Step 4: Main Implementation Module

Create the core `Rag.GraphStore.TripleStore` module:

```elixir
# lib/rag/graph_store/triple_store.ex
defmodule Rag.GraphStore.TripleStore do
  @moduledoc """
  RocksDB-backed TripleStore implementation of the GraphStore behaviour.

  This module adapts the RDF Triple model to the Property Graph API,
  enabling fast graph traversal while maintaining semantic compatibility.
  """

  @behaviour Rag.GraphStore

  alias Rag.GraphStore.TripleStore.{URI, Mapper, Traversal}
  alias TripleStore.{Dictionary, Index, Adapter}

  defstruct [:db, :manager, :data_dir, :vector_store]

  @type t :: %__MODULE__{
    db: reference(),
    manager: GenServer.server(),
    data_dir: String.t(),
    vector_store: struct() | nil
  }

  # Initialization

  @doc """
  Opens a TripleStore at the given data directory.
  """
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    vector_store = Keyword.get(opts, :vector_store)

    with {:ok, db} <- TripleStore.Backend.RocksDB.Nif.open(data_dir),
         {:ok, manager} <- Dictionary.Manager.start_link(db: db) do
      {:ok, %__MODULE__{
        db: db,
        manager: manager,
        data_dir: data_dir,
        vector_store: vector_store
      }}
    end
  end

  @doc """
  Closes the TripleStore and releases resources.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{db: db, manager: manager}) do
    Dictionary.Manager.stop(manager)
    TripleStore.Backend.RocksDB.Nif.close(db)
  end

  # Node Operations

  @impl Rag.GraphStore
  def create_node(store, attrs) do
    with :ok <- validate_node_attrs(attrs),
         id <- next_entity_id(),
         triples <- Mapper.node_to_triples(attrs, id),
         :ok <- insert_triples(store, triples) do
      node = Map.merge(attrs, %{id: id})

      # Store embedding in PostgreSQL if provided
      if attrs[:embedding] do
        store_embedding_in_postgres(store, id, attrs.embedding)
      end

      {:ok, node}
    end
  end

  @impl Rag.GraphStore
  def get_node(store, id) do
    entity_uri = URI.entity(id)

    case lookup_term_id(store, entity_uri) do
      {:ok, term_id} ->
        triples = get_entity_triples(store, term_id)

        if Enum.empty?(triples) do
          {:error, :not_found}
        else
          node = Mapper.triples_to_node(id, triples)
          {:ok, node}
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  # Edge Operations

  @impl Rag.GraphStore
  def create_edge(store, attrs) do
    with :ok <- validate_edge_attrs(attrs),
         :ok <- verify_entities_exist(store, attrs.from_id, attrs.to_id),
         edge_id <- next_edge_id(),
         triples <- Mapper.edge_to_triples(attrs, edge_id),
         :ok <- insert_triples(store, triples) do
      edge = Map.merge(attrs, %{id: edge_id})
      {:ok, edge}
    end
  end

  # Traversal Operations

  @impl Rag.GraphStore
  def find_neighbors(store, node_id, opts \\ []) do
    direction = Keyword.get(opts, :direction, :both)
    edge_type = Keyword.get(opts, :edge_type)
    limit = Keyword.get(opts, :limit, 10)

    case lookup_entity_term_id(store, node_id) do
      {:ok, term_id} ->
        neighbors = Traversal.get_neighbors(store.db, term_id, direction, edge_type)

        nodes = neighbors
        |> Enum.take(limit)
        |> Enum.map(&term_id_to_node(store, &1))
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, node} -> node end)

        {:ok, nodes}

      :not_found ->
        {:error, :not_found}
    end
  end

  @impl Rag.GraphStore
  def traverse(store, start_id, opts \\ []) do
    algorithm = Keyword.get(opts, :algorithm, :bfs)
    max_depth = Keyword.get(opts, :max_depth, 2)
    limit = Keyword.get(opts, :limit, 100)

    case lookup_entity_term_id(store, start_id) do
      {:ok, start_term_id} ->
        results = case algorithm do
          :bfs -> Traversal.bfs(store.db, start_term_id, max_depth, opts)
          :dfs -> Traversal.dfs(store.db, start_term_id, max_depth, opts)
        end

        nodes = results
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
    end
  end

  # Vector Search (Delegated to VectorStore)

  @impl Rag.GraphStore
  def vector_search(store, embedding, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    type_filter = Keyword.get(opts, :type)

    if is_nil(store.vector_store) do
      {:error, :vector_store_not_configured}
    else
      # Delegate to PostgreSQL VectorStore
      with {:ok, chunks} <- Rag.VectorStore.Pgvector.search(
             store.vector_store,
             embedding,
             limit: limit * 2
           ),
           chunk_ids <- Enum.map(chunks, & &1.id),
           {:ok, entities} <- find_entities_by_chunk_ids(store, chunk_ids) do

        entities = entities
        |> maybe_filter_by_type(type_filter)
        |> Enum.take(limit)

        {:ok, entities}
      end
    end
  end

  # Community Operations

  @impl Rag.GraphStore
  def create_community(store, attrs) do
    with :ok <- validate_community_attrs(attrs),
         id <- next_community_id(),
         triples <- Mapper.community_to_triples(attrs, id),
         :ok <- insert_triples(store, triples) do
      community = Map.merge(attrs, %{id: id})
      {:ok, community}
    end
  end

  @impl Rag.GraphStore
  def get_community_members(store, community_id) do
    community_uri = URI.community(community_id)
    has_member_uri = URI.rel(:has_member)

    with {:ok, community_term_id} <- lookup_term_id(store, community_uri),
         {:ok, has_member_term_id} <- lookup_term_id(store, has_member_uri) do
      pattern = {{:bound, community_term_id}, {:bound, has_member_term_id}, :var}

      case Index.lookup(store.db, pattern) do
        {:ok, stream} ->
          nodes = stream
          |> Stream.map(fn {_s, _p, o} -> o end)
          |> Enum.map(&term_id_to_node(store, &1))
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(fn {:ok, node} -> node end)

          {:ok, nodes}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :not_found -> {:error, :not_found}
      error -> error
    end
  end

  @impl Rag.GraphStore
  def update_community_summary(store, community_id, summary) do
    community_uri = URI.community(community_id)
    summary_prop_uri = URI.prop(:summary)

    with {:ok, community_term_id} <- lookup_term_id(store, community_uri),
         {:ok, summary_prop_term_id} <- get_or_create_term_id(store, summary_prop_uri) do

      # Delete old summary if exists
      pattern = {{:bound, community_term_id}, {:bound, summary_prop_term_id}, :var}
      {:ok, stream} = Index.lookup(store.db, pattern)
      old_triples = Enum.to_list(stream)
      Enum.each(old_triples, &Index.delete_triple(store.db, &1))

      # Insert new summary
      {:ok, summary_literal_id} <- get_or_create_term_id(store, {:literal, summary})
      :ok = Index.insert_triple(store.db, {community_term_id, summary_prop_term_id, summary_literal_id})

      {:ok, %{id: community_id, summary: summary}}
    else
      :not_found -> {:error, :not_found}
      error -> error
    end
  end

  # Private Helpers

  defp validate_node_attrs(attrs) do
    cond do
      is_nil(attrs[:type]) -> {:error, :type_required}
      is_nil(attrs[:name]) -> {:error, :name_required}
      true -> :ok
    end
  end

  defp validate_edge_attrs(attrs) do
    cond do
      is_nil(attrs[:from_id]) -> {:error, :from_id_required}
      is_nil(attrs[:to_id]) -> {:error, :to_id_required}
      is_nil(attrs[:type]) -> {:error, :type_required}
      attrs[:from_id] == attrs[:to_id] -> {:error, :self_loop_not_allowed}
      true -> :ok
    end
  end

  defp validate_community_attrs(attrs) do
    cond do
      is_nil(attrs[:entity_ids]) or Enum.empty?(attrs[:entity_ids]) ->
        {:error, :entity_ids_required}
      true ->
        :ok
    end
  end

  defp verify_entities_exist(store, from_id, to_id) do
    with {:ok, _} <- get_node(store, from_id),
         {:ok, _} <- get_node(store, to_id) do
      :ok
    else
      {:error, :not_found} -> {:error, :entity_not_found}
    end
  end

  defp insert_triples(store, rdf_triples) do
    term_ids = Adapter.terms_to_ids(store.manager,
      Enum.flat_map(rdf_triples, fn {s, p, o} -> [s, p, o] end))

    case term_ids do
      {:ok, ids} ->
        triples = rdf_triples
        |> Enum.zip(Enum.chunk_every(ids, 3))
        |> Enum.map(fn {_, [s, p, o]} -> {s, p, o} end)

        Index.insert_triples(store.db, triples)

      error -> error
    end
  end

  defp lookup_term_id(store, uri) when is_binary(uri) do
    Dictionary.StringToId.lookup_id(store.db, {:iri, uri})
  end

  defp lookup_entity_term_id(store, entity_id) do
    lookup_term_id(store, URI.entity(entity_id))
  end

  defp get_or_create_term_id(store, term) do
    Dictionary.Manager.get_or_create_id(store.manager, term)
  end

  defp get_entity_triples(store, term_id) do
    pattern = {{:bound, term_id}, :var, :var}

    case Index.lookup(store.db, pattern) do
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
      {to_rdf(s_term), to_rdf(p_term), to_rdf(o_term)}
    else
      _ -> nil
    end
  end

  defp to_rdf({:iri, uri}), do: RDF.iri(uri)
  defp to_rdf({:literal, value}), do: RDF.literal(value)
  defp to_rdf({:literal, value, type}), do: RDF.literal(value, datatype: type)
  defp to_rdf({:bnode, id}), do: RDF.bnode(id)

  defp term_id_to_node(store, term_id) do
    case Dictionary.IdToString.lookup_term(store.db, term_id) do
      {:ok, {:iri, uri}} ->
        case URI.parse(uri) do
          {:ok, {:entity, id}} -> get_node(store, id)
          _ -> {:error, :not_an_entity}
        end

      _ -> {:error, :not_found}
    end
  end

  defp find_entities_by_chunk_ids(store, chunk_ids) do
    source_chunks_uri = URI.meta(:source_chunk_ids)

    case lookup_term_id(store, source_chunks_uri) do
      {:ok, prop_term_id} ->
        pattern = {:var, {:bound, prop_term_id}, :var}

        case Index.lookup(store.db, pattern) do
          {:ok, stream} ->
            entities = stream
            |> Stream.filter(fn {_s, _p, o} ->
              case Dictionary.IdToString.lookup_term(store.db, o) do
                {:ok, {:literal, json}} ->
                  stored_ids = Jason.decode!(json)
                  Enum.any?(chunk_ids, &(&1 in stored_ids))
                _ -> false
              end
            end)
            |> Stream.map(fn {s, _p, _o} -> s end)
            |> Enum.map(&term_id_to_node(store, &1))
            |> Enum.filter(&match?({:ok, _}, &1))
            |> Enum.map(fn {:ok, node} -> node end)

            {:ok, entities}

          error -> error
        end

      :not_found ->
        {:ok, []}
    end
  end

  defp maybe_filter_by_type(entities, nil), do: entities
  defp maybe_filter_by_type(entities, type) do
    Enum.filter(entities, fn e -> e.type == type end)
  end

  defp store_embedding_in_postgres(_store, _id, _embedding) do
    # TODO: Store embedding in PostgreSQL graph_entities table
    # This maintains the hybrid architecture where vectors stay in Postgres
    :ok
  end

  # ID Generation (using ETS for simplicity)

  defp next_entity_id, do: :ets.update_counter(:triplestore_ids, :entity, 1, {:entity, 0})
  defp next_edge_id, do: :ets.update_counter(:triplestore_ids, :edge, 1, {:edge, 0})
  defp next_community_id, do: :ets.update_counter(:triplestore_ids, :community, 1, {:community, 0})
end
```

## Step 5: Supervisor Module

Create the supervision tree:

```elixir
# lib/rag/graph_store/triple_store/supervisor.ex
defmodule Rag.GraphStore.TripleStore.Supervisor do
  @moduledoc """
  Supervisor for TripleStore processes.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)

    # Create ETS table for ID generation
    :ets.new(:triplestore_ids, [:named_table, :public, :set])

    children = [
      # Add child processes here as needed
      # {TripleStore.Dictionary.Manager, [db: db]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

## Step 6: Configuration

Add configuration to the application:

```elixir
# config/config.exs
config :rag, Rag.GraphStore,
  impl: Rag.GraphStore.TripleStore,
  data_dir: System.get_env("TRIPLESTORE_DATA_DIR", "data/knowledge_graph")

# config/dev.exs
config :rag, Rag.GraphStore,
  data_dir: "priv/dev_knowledge_graph"

# config/test.exs
config :rag, Rag.GraphStore,
  data_dir: System.tmp_dir!() <> "/rag_test_kg_#{System.unique_integer()}"
```

## Step 7: Integration with Application

Update the application supervisor:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  graph_config = Application.get_env(:rag, Rag.GraphStore)

  children = [
    MyApp.Repo,
    {Rag.GraphStore.TripleStore.Supervisor, [
      data_dir: graph_config[:data_dir]
    ]},
    # ... other children
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

## Testing

Create test helpers:

```elixir
# test/support/graph_store_case.ex
defmodule Rag.GraphStoreCase do
  use ExUnit.CaseTemplate

  setup do
    data_dir = System.tmp_dir!() <> "/rag_test_#{System.unique_integer([:positive])}"
    File.mkdir_p!(data_dir)

    {:ok, store} = Rag.GraphStore.TripleStore.open(data_dir: data_dir)

    on_exit(fn ->
      Rag.GraphStore.TripleStore.close(store)
      File.rm_rf!(data_dir)
    end)

    %{store: store, data_dir: data_dir}
  end
end
```

## Next Steps

1. **Implement tests** for all GraphStore behaviour callbacks
2. **Add telemetry** for observability
3. **Implement batch operations** for ingestion performance
4. **Add caching** for frequently accessed nodes
5. **Integrate with existing Retriever.Graph** module
