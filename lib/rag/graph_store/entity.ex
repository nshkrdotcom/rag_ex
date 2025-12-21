defmodule Rag.GraphStore.Entity do
  @moduledoc """
  Ecto schema for graph entities (nodes) in the knowledge graph.

  Entities represent concepts, people, organizations, or any other
  named entity extracted from text chunks. Each entity can have:

  - A type (e.g., :person, :organization, :concept)
  - A name (the canonical name of the entity)
  - Properties (arbitrary metadata as a map)
  - An embedding vector for semantic similarity search
  - Links to source chunks where the entity was mentioned

  ## Fields

  - `type` - The type of entity (stored as string)
  - `name` - The canonical name of the entity
  - `properties` - Additional metadata as a map
  - `embedding` - Vector embedding for semantic search
  - `source_chunk_ids` - Array of chunk IDs where entity was mentioned

  ## Examples

      entity = Entity.new(%{
        type: :person,
        name: "Alice Smith",
        properties: %{role: "engineer", department: "AI"},
        embedding: [0.1, 0.2, ...],
        source_chunk_ids: [1, 2, 3]
      })

  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          type: String.t(),
          name: String.t(),
          properties: map(),
          embedding: [float()] | nil,
          source_chunk_ids: [integer()],
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "graph_entities" do
    field(:type, :string)
    field(:name, :string)
    field(:properties, :map, default: %{})
    field(:embedding, Pgvector.Ecto.Vector)
    field(:source_chunk_ids, {:array, :integer}, default: [])

    timestamps()
  end

  @doc """
  Creates a new Entity struct from the given attributes.

  Converts atom types to strings automatically.

  ## Parameters

  - `attrs` - Map with `:type`, `:name`, `:properties`, `:embedding`, `:source_chunk_ids`

  ## Examples

      iex> Entity.new(%{type: :person, name: "Alice"})
      %Entity{type: "person", name: "Alice", properties: %{}}

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
      type: type,
      name: Map.get(attrs, :name),
      properties: Map.get(attrs, :properties, %{}),
      embedding: Map.get(attrs, :embedding),
      source_chunk_ids: Map.get(attrs, :source_chunk_ids, [])
    }
  end

  @doc """
  Creates a changeset for inserting or updating an entity.

  Validates that `type` and `name` are present.

  ## Examples

      iex> Entity.changeset(%Entity{}, %{type: "person", name: "Alice"})
      #Ecto.Changeset<...>

  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entity, attrs) do
    # Convert atom type to string if necessary
    attrs = normalize_type(attrs)

    entity
    |> cast(attrs, [:type, :name, :properties, :embedding, :source_chunk_ids])
    |> validate_required([:type, :name])
    |> validate_name_not_empty()
  end

  @doc """
  Creates a changeset for updating only the embedding.

  ## Examples

      iex> Entity.embedding_changeset(entity, %{embedding: [0.1, 0.2, ...]})
      #Ecto.Changeset<...>

  """
  @spec embedding_changeset(t(), map()) :: Ecto.Changeset.t()
  def embedding_changeset(entity, attrs) do
    entity
    |> cast(attrs, [:embedding])
  end

  @doc """
  Converts an Entity struct to a plain map (node format).

  Useful for GraphStore operations that return node maps.

  ## Examples

      iex> Entity.to_node(%Entity{id: 1, type: "person", name: "Alice"})
      %{id: 1, type: "person", name: "Alice", properties: %{}, ...}

  """
  @spec to_node(t()) :: map()
  def to_node(%__MODULE__{} = entity) do
    %{
      id: entity.id,
      type: entity.type,
      name: entity.name,
      properties: entity.properties,
      embedding: entity.embedding,
      source_chunk_ids: entity.source_chunk_ids
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

  defp validate_name_not_empty(changeset) do
    validate_change(changeset, :name, fn :name, name ->
      if is_binary(name) and String.trim(name) == "" do
        [name: "can't be blank"]
      else
        []
      end
    end)
  end
end
