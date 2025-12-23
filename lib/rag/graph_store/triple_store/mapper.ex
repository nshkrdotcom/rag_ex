defmodule Rag.GraphStore.TripleStore.Mapper do
  @moduledoc """
  Converts between Property Graph structures and RDF triples.
  """

  alias Rag.GraphStore.TripleStore.URI, as: U

  @type rdf_triple :: {RDF.Term.t(), RDF.Term.t(), RDF.Term.t()}

  @doc """
  Convert a node attribute map into RDF triples.
  """
  @spec node_to_triples(map(), term()) :: [rdf_triple()]
  def node_to_triples(attrs, id) do
    entity_uri = RDF.iri(U.entity(id))

    [
      {entity_uri, RDF.type(), RDF.iri(U.type(attrs.type))},
      {entity_uri, RDF.iri(U.prop(:name)), RDF.literal(attrs.name)}
    ]
    |> Kernel.++(properties_to_triples(entity_uri, Map.get(attrs, :properties, %{})))
    |> Kernel.++(source_chunks_triple(entity_uri, attrs[:source_chunk_ids]))
    |> Kernel.++(embedding_flag_triple(entity_uri, attrs[:embedding]))
  end

  @doc """
  Convert an edge attribute map into RDF triples.
  """
  @spec edge_to_triples(map(), term()) :: [rdf_triple()]
  def edge_to_triples(attrs, edge_id) do
    from_uri = RDF.iri(U.entity(attrs.from_id))
    to_uri = RDF.iri(U.entity(attrs.to_id))
    rel_uri = RDF.iri(U.rel(attrs.type))

    direct_triple = {from_uri, rel_uri, to_uri}

    if has_edge_properties?(attrs) do
      edge_uri = RDF.iri(U.edge(edge_id))

      [
        direct_triple,
        {edge_uri, RDF.type(), RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#Statement")},
        {edge_uri, RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#subject"), from_uri},
        {edge_uri, RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#predicate"), rel_uri},
        {edge_uri, RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#object"), to_uri}
      ]
      |> Kernel.++(weight_triple(edge_uri, attrs[:weight]))
      |> Kernel.++(properties_to_triples(edge_uri, Map.get(attrs, :properties, %{})))
    else
      [direct_triple]
    end
  end

  @doc """
  Convert community attributes into RDF triples.
  """
  @spec community_to_triples(map(), term()) :: [rdf_triple()]
  def community_to_triples(attrs, id) do
    community_uri = RDF.iri(U.community(id))

    [
      {community_uri, RDF.type(), RDF.iri(U.type(:community))},
      {community_uri, RDF.iri(U.prop(:level)), RDF.literal(Map.get(attrs, :level, 0))}
    ]
    |> Kernel.++(summary_triple(community_uri, attrs[:summary]))
    |> Kernel.++(membership_triples(community_uri, Map.get(attrs, :entity_ids, [])))
  end

  @doc """
  Reconstruct a node map from RDF triples.
  """
  @spec triples_to_node(term(), [rdf_triple()]) :: map()
  def triples_to_node(id, triples) do
    base = %{
      id: id,
      type: nil,
      name: nil,
      properties: %{},
      embedding: nil,
      source_chunk_ids: []
    }

    Enum.reduce(triples, base, &apply_triple_to_node/2)
  end

  defp properties_to_triples(subject, properties) when is_map(properties) do
    Enum.flat_map(properties, fn {key, value} ->
      case value_to_literal(value) do
        nil -> []
        literal -> [{subject, RDF.iri(U.prop(key)), literal}]
      end
    end)
  end

  defp source_chunks_triple(_subject, nil), do: []
  defp source_chunks_triple(_subject, []), do: []

  defp source_chunks_triple(subject, chunk_ids) do
    [{subject, RDF.iri(U.meta(:source_chunk_ids)), RDF.literal(Jason.encode!(chunk_ids))}]
  end

  defp embedding_flag_triple(_subject, nil), do: []

  defp embedding_flag_triple(subject, _embedding) do
    [{subject, RDF.iri(U.meta(:has_embedding)), RDF.literal(true)}]
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

  defp has_edge_properties?(attrs) do
    weight = attrs[:weight]
    props = Map.get(attrs, :properties, %{})

    (weight != nil and weight != 1.0) or map_size(props) > 0
  end

  defp weight_triple(_subject, nil), do: []
  defp weight_triple(_subject, 1.0), do: []

  defp weight_triple(subject, weight) do
    [{subject, RDF.iri(U.prop(:weight)), RDF.literal(weight)}]
  end

  @doc """
  Convert a value into an RDF literal.
  """
  @spec value_to_literal(term()) :: RDF.Literal.t() | nil
  def value_to_literal(nil), do: nil
  def value_to_literal(v) when is_binary(v), do: RDF.literal(v)
  def value_to_literal(v) when is_integer(v), do: RDF.literal(v)
  def value_to_literal(v) when is_float(v), do: RDF.literal(v)
  def value_to_literal(v) when is_boolean(v), do: RDF.literal(v)
  def value_to_literal(%DateTime{} = v), do: RDF.literal(v)
  def value_to_literal(%Decimal{} = v), do: RDF.literal(Decimal.to_string(v))
  def value_to_literal(v) when is_atom(v), do: RDF.literal(Atom.to_string(v))
  def value_to_literal(v) when is_map(v), do: RDF.literal(Jason.encode!(v))
  def value_to_literal(v) when is_list(v), do: RDF.literal(Jason.encode!(v))

  defp apply_triple_to_node({_s, p, o}, node) do
    p_value = iri_value(p)

    case U.parse(p_value) do
      {:ok, {:rdf, :type}} ->
        case iri_value(o) do
          nil ->
            node

          type_uri ->
            case U.parse(type_uri) do
              {:ok, {:type, type}} -> %{node | type: String.to_atom(type)}
              _ -> node
            end
        end

      {:ok, {:prop, :name}} ->
        %{node | name: literal_value(o)}

      {:ok, {:prop, key}} ->
        props = Map.put(node.properties, key, literal_value(o))
        %{node | properties: props}

      {:ok, {:meta, :source_chunk_ids}} ->
        ids = decode_json_list(literal_value(o))
        %{node | source_chunk_ids: ids}

      _ ->
        node
    end
  end

  defp decode_json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_json_list(_value), do: []

  defp iri_value(%RDF.IRI{value: value}), do: value
  defp iri_value(%RDF.Literal{}), do: nil
  defp iri_value(value) when is_binary(value), do: value
  defp iri_value(value), do: to_string(value)

  defp literal_value(%RDF.Literal{} = lit), do: RDF.Literal.value(lit)
  defp literal_value(value), do: value
end
