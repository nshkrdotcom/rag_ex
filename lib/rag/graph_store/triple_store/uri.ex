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

  @doc """
  Build an entity URI.
  """
  @spec entity(term()) :: String.t()
  def entity(id), do: @entity_prefix <> to_string(id)

  @doc """
  Build a type URI.
  """
  @spec type(atom() | String.t()) :: String.t()
  def type(t) when is_atom(t), do: @type_prefix <> Atom.to_string(t)
  def type(t) when is_binary(t), do: @type_prefix <> t

  @doc """
  Build a relationship URI.
  """
  @spec rel(atom() | String.t()) :: String.t()
  def rel(r) when is_atom(r), do: @rel_prefix <> Atom.to_string(r)
  def rel(r) when is_binary(r), do: @rel_prefix <> r

  @doc """
  Build a property URI.
  """
  @spec prop(atom() | String.t()) :: String.t()
  def prop(p) when is_atom(p), do: @prop_prefix <> Atom.to_string(p)
  def prop(p) when is_binary(p), do: @prop_prefix <> p

  @doc """
  Build a reified edge URI.
  """
  @spec edge(term()) :: String.t()
  def edge(id), do: @edge_prefix <> to_string(id)

  @doc """
  Build a community URI.
  """
  @spec community(term()) :: String.t()
  def community(id), do: @community_prefix <> to_string(id)

  @doc """
  Build a metadata URI.
  """
  @spec meta(atom() | String.t()) :: String.t()
  def meta(m) when is_atom(m), do: @meta_prefix <> Atom.to_string(m)
  def meta(m) when is_binary(m), do: @meta_prefix <> m

  @doc """
  RDF type predicate URI.
  """
  @spec rdf_type() :: String.t()
  def rdf_type, do: @rdf_type

  @doc """
  Parse a URI into its namespace and identifier.
  """
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

  @doc """
  Check if a URI is an entity URI.
  """
  @spec entity?(String.t()) :: boolean()
  def entity?(@entity_prefix <> _), do: true
  def entity?(_), do: false

  @doc """
  Check if a URI is a relationship URI.
  """
  @spec relationship?(String.t()) :: boolean()
  def relationship?(@rel_prefix <> _), do: true
  def relationship?(_), do: false

  @doc """
  Check if a URI is a property URI.
  """
  @spec property?(String.t()) :: boolean()
  def property?(@prop_prefix <> _), do: true
  def property?(_), do: false

  defp parse_id(str) do
    case Integer.parse(str) do
      {id, ""} -> id
      _ -> str
    end
  end
end
