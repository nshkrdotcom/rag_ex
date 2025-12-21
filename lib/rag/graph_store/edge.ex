defmodule Rag.GraphStore.Edge do
  @moduledoc """
  Ecto schema for graph edges (relationships) in the knowledge graph.

  Edges represent relationships between entities. Each edge has:

  - A source entity (from_id)
  - A target entity (to_id)
  - A type describing the relationship
  - A weight indicating the strength or confidence
  - Properties for additional metadata

  ## Fields

  - `from_id` - ID of the source entity
  - `to_id` - ID of the target entity
  - `type` - The type of relationship (stored as string)
  - `weight` - Relationship strength/confidence (0.0 to 1.0)
  - `properties` - Additional metadata as a map

  ## Examples

      edge = Edge.new(%{
        from_id: 1,
        to_id: 2,
        type: :knows,
        weight: 0.8,
        properties: %{since: "2020", context: "work"}
      })

  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Rag.GraphStore.Entity

  @type t :: %__MODULE__{
          id: integer() | nil,
          from_id: integer(),
          to_id: integer(),
          type: String.t(),
          weight: float(),
          properties: map(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "graph_edges" do
    belongs_to(:from_entity, Entity, foreign_key: :from_id)
    belongs_to(:to_entity, Entity, foreign_key: :to_id)
    field(:type, :string)
    field(:weight, :float, default: 1.0)
    field(:properties, :map, default: %{})

    timestamps()
  end

  @doc """
  Creates a new Edge struct from the given attributes.

  Converts atom types to strings automatically.
  Defaults weight to 1.0 if not provided.

  ## Parameters

  - `attrs` - Map with `:from_id`, `:to_id`, `:type`, `:weight`, `:properties`

  ## Examples

      iex> Edge.new(%{from_id: 1, to_id: 2, type: :knows})
      %Edge{from_id: 1, to_id: 2, type: "knows", weight: 1.0}

  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    type =
      case Map.get(attrs, :type) do
        type when is_atom(type) -> Atom.to_string(type)
        type when is_binary(type) -> type
        _ -> nil
      end

    %__MODULE__{
      from_id: Map.get(attrs, :from_id),
      to_id: Map.get(attrs, :to_id),
      type: type,
      weight: Map.get(attrs, :weight, 1.0),
      properties: Map.get(attrs, :properties, %{})
    }
  end

  @doc """
  Creates a changeset for inserting or updating an edge.

  Validates that `from_id`, `to_id`, and `type` are present.
  Validates that weight is between 0.0 and 1.0.

  ## Examples

      iex> Edge.changeset(%Edge{}, %{from_id: 1, to_id: 2, type: "knows"})
      #Ecto.Changeset<...>

  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(edge, attrs) do
    # Convert atom type to string if necessary
    attrs = normalize_type(attrs)

    edge
    |> cast(attrs, [:from_id, :to_id, :type, :weight, :properties])
    |> validate_required([:from_id, :to_id, :type])
    |> validate_number(:weight, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_different_nodes()
  end

  @doc """
  Converts an Edge struct to a plain map.

  Useful for GraphStore operations that return edge maps.

  ## Examples

      iex> Edge.to_map(%Edge{id: 1, from_id: 1, to_id: 2, type: "knows"})
      %{id: 1, from_id: 1, to_id: 2, type: "knows", weight: 1.0, ...}

  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = edge) do
    %{
      id: edge.id,
      from_id: edge.from_id,
      to_id: edge.to_id,
      type: edge.type,
      weight: edge.weight,
      properties: edge.properties
    }
  end

  # Private helpers

  defp normalize_type(attrs) do
    case Map.get(attrs, :type) do
      type when is_atom(type) ->
        Map.put(attrs, :type, Atom.to_string(type))

      _ ->
        attrs
    end
  end

  defp validate_different_nodes(changeset) do
    from_id = get_field(changeset, :from_id)
    to_id = get_field(changeset, :to_id)

    if from_id && to_id && from_id == to_id do
      add_error(changeset, :to_id, "must be different from from_id (no self-loops)")
    else
      changeset
    end
  end
end
