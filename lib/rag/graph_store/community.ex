if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Rag.GraphStore.Community do
    @moduledoc """
    Ecto schema for graph communities in the knowledge graph.

    Communities represent clusters of related entities discovered through
    graph algorithms (e.g., Louvain, Leiden). They support hierarchical
    clustering with multiple levels.

    In GraphRAG, communities are used to:
    - Group related entities for summarization
    - Enable multi-level reasoning (bottom-up)
    - Provide context for entity disambiguation

    ## Fields

    - `level` - Hierarchy level (0 = leaf, higher = more abstract)
    - `summary` - Human-readable summary of the community
    - `entity_ids` - Array of entity IDs in this community

    ## Examples

        community = Community.new(%{
          level: 0,
          summary: "Engineering team members and their technologies",
          entity_ids: [1, 2, 3, 4]
        })

    """

    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{
            id: integer() | nil,
            level: non_neg_integer(),
            summary: String.t() | nil,
            entity_ids: [integer()],
            inserted_at: NaiveDateTime.t() | nil,
            updated_at: NaiveDateTime.t() | nil
          }

    schema "graph_communities" do
      field(:level, :integer, default: 0)
      field(:summary, :string)
      field(:entity_ids, {:array, :integer}, default: [])

      timestamps()
    end

    @doc """
    Creates a new Community struct from the given attributes.

    ## Parameters

    - `attrs` - Map with `:level`, `:summary`, `:entity_ids`

    ## Examples

        iex> Community.new(%{level: 0, entity_ids: [1, 2, 3]})
        %Community{level: 0, entity_ids: [1, 2, 3]}

    """
    @spec new(map()) :: t()
    def new(attrs) when is_map(attrs) do
      %__MODULE__{
        level: Map.get(attrs, :level, 0),
        summary: Map.get(attrs, :summary),
        entity_ids: Map.get(attrs, :entity_ids, [])
      }
    end

    @doc """
    Creates a changeset for inserting or updating a community.

    Validates that `level` and `entity_ids` are present.
    Validates that level is non-negative.

    ## Examples

        iex> Community.changeset(%Community{}, %{level: 0, entity_ids: [1, 2]})
        #Ecto.Changeset<...>

    """
    @spec changeset(t(), map()) :: Ecto.Changeset.t()
    def changeset(community, attrs) do
      community
      |> cast(attrs, [:level, :summary, :entity_ids])
      |> validate_required([:level, :entity_ids])
      |> validate_number(:level, greater_than_or_equal_to: 0)
      |> validate_entity_ids_not_empty()
    end

    @doc """
    Creates a changeset for updating only the summary.

    Used when generating community summaries via LLM.

    ## Examples

        iex> Community.summary_changeset(community, %{summary: "New summary"})
        #Ecto.Changeset<...>

    """
    @spec summary_changeset(t(), map()) :: Ecto.Changeset.t()
    def summary_changeset(community, attrs) do
      community
      |> cast(attrs, [:summary])
    end

    @doc """
    Converts a Community struct to a plain map.

    Useful for GraphStore operations that return community maps.

    ## Examples

        iex> Community.to_map(%Community{id: 1, level: 0, entity_ids: [1, 2]})
        %{id: 1, level: 0, summary: nil, entity_ids: [1, 2]}

    """
    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = community) do
      %{
        id: community.id,
        level: community.level,
        summary: community.summary,
        entity_ids: community.entity_ids
      }
    end

    # Private helpers

    defp validate_entity_ids_not_empty(changeset) do
      validate_change(changeset, :entity_ids, fn :entity_ids, entity_ids ->
        if is_list(entity_ids) and length(entity_ids) == 0 do
          [entity_ids: "must contain at least one entity"]
        else
          []
        end
      end)
    end
  end
end
