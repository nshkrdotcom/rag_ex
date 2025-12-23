defmodule Rag.GraphStore.TripleStore.Traversal do
  @moduledoc """
  Graph traversal algorithms using TripleStore indices.
  """

  alias Rag.GraphStore.TripleStore.URI, as: U
  alias TripleStore.Dictionary.{IdToString, StringToId}
  alias TripleStore.Index

  @doc """
  Breadth-first traversal from a starting node.

  Returns a list of {term_id, depth} tuples.
  """
  @spec bfs(reference(), non_neg_integer(), non_neg_integer(), keyword()) ::
          [{non_neg_integer(), non_neg_integer()}]
  def bfs(db, start_term_id, max_depth, opts \\ []) do
    direction = Keyword.get(opts, :direction, :out)
    edge_type_filter = Keyword.get(opts, :edge_type)

    queue = :queue.from_list([{start_term_id, 0}])
    visited = %{start_term_id => true}

    do_bfs(db, queue, visited, max_depth, direction, edge_type_filter, [])
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

    do_dfs(db, [{start_term_id, 0}], %{}, max_depth, direction, edge_type_filter, [])
    |> Enum.reverse()
  end

  @doc """
  Get immediate neighbors of a node.
  """
  @spec get_neighbors(reference(), non_neg_integer(), :in | :out | :both, term()) ::
          [non_neg_integer()]
  def get_neighbors(db, term_id, direction, edge_type_filter \\ nil) do
    patterns = build_patterns(term_id, direction)

    edge_type_id = lookup_edge_type_id(db, edge_type_filter)

    case edge_type_id do
      {:error, _} ->
        []

      _ ->
        patterns
        |> Enum.flat_map(fn {pattern, pattern_direction} ->
          case Index.lookup(db, pattern) do
            {:ok, stream} ->
              stream
              |> maybe_filter_by_edge_type(edge_type_id)
              |> Stream.filter(&relationship_predicate?(db, &1, edge_type_id))
              |> Stream.filter(&neighbor_entity?(db, &1, pattern_direction))
              |> Stream.map(&neighbor_id(&1, pattern_direction))
              |> Enum.to_list()

            {:error, _} ->
              []
          end
        end)
        |> Enum.uniq()
    end
  end

  defp do_bfs(db, queue, visited, max_depth, direction, filter, acc) do
    case :queue.out(queue) do
      {:empty, _} ->
        Enum.reverse(acc)

      {{:value, {current_id, depth}}, rest_queue} ->
        acc = [{current_id, depth} | acc]

        if depth >= max_depth do
          do_bfs(db, rest_queue, visited, max_depth, direction, filter, acc)
        else
          neighbors = get_neighbors(db, current_id, direction, filter)

          {new_queue, new_visited} =
            Enum.reduce(neighbors, {rest_queue, visited}, fn neighbor_id, {q, v} ->
              if Map.has_key?(v, neighbor_id) do
                {q, v}
              else
                {:queue.in({neighbor_id, depth + 1}, q), Map.put(v, neighbor_id, true)}
              end
            end)

          do_bfs(db, new_queue, new_visited, max_depth, direction, filter, acc)
        end
    end
  end

  defp do_dfs(_db, [], _visited, _max_depth, _direction, _filter, acc), do: acc

  defp do_dfs(db, [{current_id, depth} | rest], visited, max_depth, direction, filter, acc) do
    if Map.has_key?(visited, current_id) do
      do_dfs(db, rest, visited, max_depth, direction, filter, acc)
    else
      visited = Map.put(visited, current_id, true)
      acc = [{current_id, depth} | acc]

      if depth >= max_depth do
        do_dfs(db, rest, visited, max_depth, direction, filter, acc)
      else
        neighbors = get_neighbors(db, current_id, direction, filter)
        next = Enum.map(neighbors, &{&1, depth + 1})
        do_dfs(db, next ++ rest, visited, max_depth, direction, filter, acc)
      end
    end
  end

  defp build_patterns(term_id, :out), do: [{{{:bound, term_id}, :var, :var}, :out}]
  defp build_patterns(term_id, :in), do: [{{:var, :var, {:bound, term_id}}, :in}]

  defp build_patterns(term_id, :both) do
    [
      {{{:bound, term_id}, :var, :var}, :out},
      {{:var, :var, {:bound, term_id}}, :in}
    ]
  end

  defp lookup_edge_type_id(_db, nil), do: nil

  defp lookup_edge_type_id(db, edge_type) do
    rel_uri = U.rel(edge_type)

    case StringToId.lookup_id(db, RDF.iri(rel_uri)) do
      {:ok, rel_term_id} -> rel_term_id
      :not_found -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp maybe_filter_by_edge_type(stream, nil), do: stream

  defp maybe_filter_by_edge_type(stream, edge_type_id) when is_integer(edge_type_id) do
    Stream.filter(stream, fn {_s, p, _o} -> p == edge_type_id end)
  end

  defp relationship_predicate?(_db, {_s, _p, _o}, rel_id) when is_integer(rel_id), do: true

  defp relationship_predicate?(db, {_s, p, _o}, _rel_id) do
    case IdToString.lookup_term(db, p) do
      {:ok, %RDF.IRI{value: uri}} -> U.relationship?(uri)
      _ -> false
    end
  end

  defp neighbor_entity?(db, {_s, _p, o}, :out), do: entity_term_id?(db, o)
  defp neighbor_entity?(db, {s, _p, _o}, :in), do: entity_term_id?(db, s)

  defp neighbor_id({_s, _p, o}, :out), do: o
  defp neighbor_id({s, _p, _o}, :in), do: s

  defp entity_term_id?(db, term_id) do
    case IdToString.lookup_term(db, term_id) do
      {:ok, %RDF.IRI{value: uri}} -> U.entity?(uri)
      _ -> false
    end
  end
end
