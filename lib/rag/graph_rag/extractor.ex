defmodule Rag.GraphRAG.Extractor do
  @moduledoc """
  Extract entities and relationships from text using LLM.

  Used in GraphRAG pipelines to build knowledge graphs
  from document chunks.

  ## Example

      {:ok, router} = Rag.Router.new(providers: [:gemini])

      {:ok, result} = Extractor.extract(
        "Alice works for Acme Corp in New York.",
        router: router
      )

      # result contains:
      # %{
      #   entities: [
      #     %{name: "Alice", type: :person, description: "...", aliases: []},
      #     %{name: "Acme Corp", type: :organization, ...},
      #     %{name: "New York", type: :location, ...}
      #   ],
      #   relationships: [
      #     %{source: "Alice", target: "Acme Corp", type: :works_for, ...}
      #   ]
      # }
  """

  alias Rag.Router

  @entity_types [:person, :organization, :location, :event, :concept, :technology, :document]

  @relationship_types [
    :works_for,
    :located_in,
    :created_by,
    :part_of,
    :related_to,
    :uses,
    :depends_on
  ]

  @entity_extraction_prompt """
  Extract entities from the following text. Return a JSON array of entities.

  Entity types to extract: {entity_types}

  Each entity should have:
  - name: The entity name (string)
  - type: The entity type (one of the allowed types)
  - description: A brief description of the entity (string)
  - aliases: Array of alternative names or abbreviations (array of strings)

  Text:
  {text}

  Return ONLY a valid JSON array of entities, nothing else.
  """

  @relationship_extraction_prompt """
  Extract relationships between the following entities from the text.

  Known entities:
  {entities}

  Relationship types to extract: {relationship_types}

  Each relationship should have:
  - source: The source entity name (string)
  - target: The target entity name (string)
  - type: The relationship type (one of the allowed types)
  - description: A brief description of the relationship (string)
  - weight: Confidence/strength of the relationship, 0.0 to 1.0 (float)

  Text:
  {text}

  Return ONLY a valid JSON array of relationships, nothing else.
  """

  @entity_resolution_prompt """
  Analyze the following entities and identify which ones refer to the same thing.

  Entities:
  {entities}

  For each canonical entity name, list all aliases (other entity names that refer to the same thing).
  Return a JSON object mapping canonical names to arrays of aliases.

  Example:
  {
    "New York": ["NYC", "New York City"],
    "Alice Smith": ["Alice", "A. Smith"],
    "Bob": []
  }

  Return ONLY a valid JSON object, nothing else.
  """

  @type entity :: %{
          name: String.t(),
          type: atom(),
          description: String.t(),
          aliases: [String.t()]
        }

  @type relationship :: %{
          source: String.t(),
          target: String.t(),
          type: atom(),
          description: String.t(),
          weight: float()
        }

  @type extraction_result :: %{
          entities: [entity()],
          relationships: [relationship()]
        }

  @doc """
  Extract entities and relationships from text.

  ## Options

  - `:router` - (required) The Router to use for LLM calls
  - `:provider` - Which provider to use (optional, router will select)
  - `:entity_types` - Custom entity types to extract (default: #{inspect(@entity_types)})
  - `:relationship_types` - Custom relationship types (default: #{inspect(@relationship_types)})

  ## Examples

      {:ok, router} = Router.new(providers: [:gemini])
      {:ok, result} = Extractor.extract("text", router: router)
  """
  @spec extract(text :: String.t(), opts :: keyword()) ::
          {:ok, extraction_result()} | {:error, term()}
  def extract(text, opts \\ []) do
    with {:ok, _router} <- get_router(opts),
         {:ok, entities} <- extract_entities(text, opts),
         {:ok, relationships} <- extract_relationships(text, entities, opts) do
      {:ok, %{entities: entities, relationships: relationships}}
    end
  end

  @doc """
  Extract entities only from text.

  ## Options

  Same as `extract/2`.

  ## Examples

      {:ok, entities} = Extractor.extract_entities("text", router: router)
  """
  @spec extract_entities(text :: String.t(), opts :: keyword()) ::
          {:ok, [entity()]} | {:error, term()}
  def extract_entities(text, opts \\ []) do
    with {:ok, router} <- get_router(opts) do
      entity_types = Keyword.get(opts, :entity_types, @entity_types)

      prompt =
        @entity_extraction_prompt
        |> String.replace("{entity_types}", Enum.join(entity_types, ", "))
        |> String.replace("{text}", text)

      provider = Keyword.get(opts, :provider)
      llm_opts = if provider, do: [provider: provider], else: []

      case Router.execute(router, :text, prompt, llm_opts) do
        {:ok, response, _router} ->
          parse_entities(response)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Extract relationships between known entities from text.

  ## Options

  Same as `extract/2`.

  ## Examples

      entities = [%{name: "Alice", type: :person, ...}]
      {:ok, relationships} = Extractor.extract_relationships("text", entities, router: router)
  """
  @spec extract_relationships(text :: String.t(), entities :: [entity()], opts :: keyword()) ::
          {:ok, [relationship()]} | {:error, term()}
  def extract_relationships(text, entities, opts \\ []) do
    with {:ok, router} <- get_router(opts) do
      relationship_types = Keyword.get(opts, :relationship_types, @relationship_types)

      entity_list =
        entities
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn e -> is_map(e) && Map.has_key?(e, :name) end)
        |> Enum.map(fn e -> "- #{e.name} (#{e.type})" end)
        |> Enum.join("\n")

      prompt =
        @relationship_extraction_prompt
        |> String.replace("{entities}", entity_list)
        |> String.replace("{relationship_types}", Enum.join(relationship_types, ", "))
        |> String.replace("{text}", text)

      provider = Keyword.get(opts, :provider)
      llm_opts = if provider, do: [provider: provider], else: []

      case Router.execute(router, :text, prompt, llm_opts) do
        {:ok, response, _router} ->
          parse_relationships(response)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Resolve duplicate entities to canonical forms.

  This uses the LLM to identify which entity names refer to the same thing
  and consolidates them into canonical entities with aliases.

  ## Options

  - `:router` - (required) The Router to use for LLM calls
  - `:provider` - Which provider to use (optional)

  ## Examples

      entities = [
        %{name: "New York", type: :location, ...},
        %{name: "NYC", type: :location, ...}
      ]
      {:ok, resolved} = Extractor.resolve_entities(entities, router: router)
      # Returns: [%{name: "New York", aliases: ["NYC"], ...}]
  """
  @spec resolve_entities(entities :: [entity()], opts :: keyword()) ::
          {:ok, [entity()]} | {:error, term()}
  def resolve_entities(entities, opts \\ []) do
    with {:ok, router} <- get_router(opts) do
      entity_list =
        entities
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn e -> is_map(e) && Map.has_key?(e, :name) end)
        |> Enum.map(fn e -> "- #{e.name} (#{e.type}): #{Map.get(e, :description, "")}" end)
        |> Enum.join("\n")

      prompt = String.replace(@entity_resolution_prompt, "{entities}", entity_list)

      provider = Keyword.get(opts, :provider)
      llm_opts = if provider, do: [provider: provider], else: []

      case Router.execute(router, :text, prompt, llm_opts) do
        {:ok, response, _router} ->
          resolve_with_mapping(entities, response)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Extract from multiple texts in batch.

  Uses `Task.async_stream` for concurrent processing.

  ## Options

  Same as `extract/2`, plus:
  - `:max_concurrency` - Maximum concurrent tasks (default: System.schedulers_online())
  - `:timeout` - Timeout per task in milliseconds (default: 30_000)

  ## Examples

      texts = ["text1", "text2", "text3"]
      {:ok, results} = Extractor.extract_batch(texts, router: router)
  """
  @spec extract_batch(texts :: [String.t()], opts :: keyword()) ::
          {:ok, [extraction_result() | {:error, term()}]} | {:error, term()}
  def extract_batch(texts, opts \\ []) do
    case get_router(opts) do
      {:ok, _router} ->
        max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
        timeout = Keyword.get(opts, :timeout, 30_000)

        results =
          texts
          |> Task.async_stream(
            fn text -> extract(text, opts) end,
            max_concurrency: max_concurrency,
            timeout: timeout,
            on_timeout: :kill_task
          )
          |> Enum.map(fn
            {:ok, result} -> result
            {:exit, :timeout} -> {:error, :timeout}
            {:exit, reason} -> {:error, reason}
          end)

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp get_router(opts) do
    case Keyword.get(opts, :router) do
      nil -> {:error, :router_required}
      router -> {:ok, router}
    end
  end

  # Extract JSON from LLM response, stripping markdown code blocks if present
  defp extract_json(response) do
    response = String.trim(response)

    cond do
      String.starts_with?(response, "```json") ->
        response
        |> String.replace_prefix("```json", "")
        |> String.replace_suffix("```", "")
        |> String.trim()

      String.starts_with?(response, "```") ->
        response
        |> String.replace_prefix("```", "")
        |> String.replace_suffix("```", "")
        |> String.trim()

      true ->
        response
    end
  end

  defp parse_entities(json_string) do
    case Jason.decode(extract_json(json_string)) do
      {:ok, entities} when is_list(entities) ->
        parsed =
          entities
          |> Enum.filter(fn entity -> is_map(entity) && Map.get(entity, "name") end)
          |> Enum.map(fn entity ->
            type_str = Map.get(entity, "type", "concept")
            type = if type_str, do: String.to_atom(type_str), else: :concept

            %{
              name: Map.get(entity, "name"),
              type: type,
              description: Map.get(entity, "description", ""),
              aliases: Map.get(entity, "aliases", [])
            }
          end)

        {:ok, parsed}

      {:ok, _} ->
        {:error, :invalid_entity_format}

      {:error, _} = error ->
        error
    end
  end

  defp parse_relationships(json_string) do
    case Jason.decode(extract_json(json_string)) do
      {:ok, relationships} when is_list(relationships) ->
        parsed =
          relationships
          |> Enum.filter(fn rel ->
            is_map(rel) && Map.get(rel, "source") && Map.get(rel, "target")
          end)
          |> Enum.map(fn rel ->
            type_str = Map.get(rel, "type", "related_to")
            type = if type_str, do: String.to_atom(type_str), else: :related_to

            %{
              source: Map.get(rel, "source"),
              target: Map.get(rel, "target"),
              type: type,
              description: Map.get(rel, "description", ""),
              weight: Map.get(rel, "weight", 1.0)
            }
          end)

        {:ok, parsed}

      {:ok, _} ->
        {:error, :invalid_relationship_format}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_with_mapping(entities, json_string) do
    # Filter out nil and invalid entities upfront
    valid_entities =
      entities
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn e -> is_map(e) && Map.has_key?(e, :name) end)

    case Jason.decode(extract_json(json_string)) do
      {:ok, mapping} when is_map(mapping) ->
        # Build a map of entity names to entities
        entity_map =
          valid_entities
          |> Enum.map(fn e -> {e.name, e} end)
          |> Map.new()

        # Get canonical entity names (keys in mapping)
        canonical_names = Map.keys(mapping)

        # Build set of all alias names
        all_aliases =
          mapping
          |> Map.values()
          |> List.flatten()
          |> MapSet.new()

        # For each canonical entity, merge in aliases
        resolved =
          canonical_names
          |> Enum.map(fn canonical_name ->
            entity = Map.get(entity_map, canonical_name)
            aliases = Map.get(mapping, canonical_name, [])

            if entity do
              # Update entity with all aliases
              existing_aliases = Map.get(entity, :aliases) || []
              all_entity_aliases = Enum.uniq(existing_aliases ++ aliases)
              %{entity | aliases: all_entity_aliases}
            else
              # Canonical name not in original entities, use first alias as template
              first_alias = List.first(aliases)
              template = if first_alias, do: Map.get(entity_map, first_alias), else: nil

              if template do
                %{template | name: canonical_name, aliases: aliases}
              else
                nil
              end
            end
          end)
          |> Enum.reject(&is_nil/1)

        # Add any entities that weren't mentioned in the mapping
        remaining =
          valid_entities
          |> Enum.reject(fn e ->
            e.name in canonical_names or e.name in all_aliases
          end)

        {:ok, resolved ++ remaining}

      {:ok, _} ->
        {:error, :invalid_resolution_format}

      {:error, _} = error ->
        error
    end
  end
end
