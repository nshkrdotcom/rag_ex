defmodule Rag.GraphRAG.ExtractorTest do
  use ExUnit.Case, async: false
  use Mimic

  setup :set_mimic_global

  alias Rag.GraphRAG.Extractor
  alias Rag.Router

  setup :verify_on_exit!

  describe "extract/2" do
    test "extracts entities and relationships from text" do
      text = "Alice works for Acme Corp in New York. Bob also works there."

      # Mock Router.execute to return JSON with entities and relationships
      entities_json =
        Jason.encode!([
          %{
            "name" => "Alice",
            "type" => "person",
            "description" => "A person mentioned in the text",
            "aliases" => []
          },
          %{
            "name" => "Bob",
            "type" => "person",
            "description" => "Another person mentioned",
            "aliases" => []
          },
          %{
            "name" => "Acme Corp",
            "type" => "organization",
            "description" => "A company",
            "aliases" => []
          },
          %{
            "name" => "New York",
            "type" => "location",
            "description" => "A city",
            "aliases" => ["NYC"]
          }
        ])

      relationships_json =
        Jason.encode!([
          %{
            "source" => "Alice",
            "target" => "Acme Corp",
            "type" => "works_for",
            "description" => "Alice is employed by Acme Corp",
            "weight" => 1.0
          },
          %{
            "source" => "Bob",
            "target" => "Acme Corp",
            "type" => "works_for",
            "description" => "Bob is employed by Acme Corp",
            "weight" => 1.0
          },
          %{
            "source" => "Acme Corp",
            "target" => "New York",
            "type" => "located_in",
            "description" => "Acme Corp is located in New York",
            "weight" => 1.0
          }
        ])

      stub(Router, :execute, fn router, :text, prompt, _opts ->
        response =
          cond do
            String.contains?(prompt, "Extract entities") ->
              {:ok, entities_json, router}

            String.contains?(prompt, "Extract relationships") ->
              {:ok, relationships_json, router}

            true ->
              {:error, :unknown_prompt}
          end

        response
      end)

      {:ok, router} = Router.new(providers: [:gemini])

      assert {:ok, result} = Extractor.extract(text, router: router)

      assert length(result.entities) == 4
      assert length(result.relationships) == 3

      # Check entities
      alice = Enum.find(result.entities, fn e -> e.name == "Alice" end)
      assert alice.type == :person
      assert alice.description == "A person mentioned in the text"

      # Check relationships
      alice_works = Enum.find(result.relationships, fn r -> r.source == "Alice" end)
      assert alice_works.target == "Acme Corp"
      assert alice_works.type == :works_for
      assert alice_works.weight == 1.0
    end

    test "returns error when router is not provided" do
      text = "Some text"

      assert {:error, :router_required} = Extractor.extract(text, [])
    end

    test "handles LLM errors gracefully" do
      text = "Some text"

      stub(Router, :execute, fn _router, :text, _prompt, _opts ->
        {:error, :api_error}
      end)

      {:ok, router} = Router.new(providers: [:gemini])

      assert {:error, :api_error} = Extractor.extract(text, router: router)
    end

    test "handles invalid JSON responses" do
      text = "Some text"

      stub(Router, :execute, fn router, :text, _prompt, _opts ->
        {:ok, "invalid json {", router}
      end)

      {:ok, router} = Router.new(providers: [:gemini])

      assert {:error, %Jason.DecodeError{}} = Extractor.extract(text, router: router)
    end
  end

  describe "extract_entities/2" do
    test "extracts only entities from text" do
      text = "Alice works for Acme Corp."

      entities_json =
        Jason.encode!([
          %{
            "name" => "Alice",
            "type" => "person",
            "description" => "A person",
            "aliases" => []
          },
          %{
            "name" => "Acme Corp",
            "type" => "organization",
            "description" => "A company",
            "aliases" => []
          }
        ])

      stub(Router, :execute, fn router, :text, _prompt, _opts ->
        {:ok, entities_json, router}
      end)

      {:ok, router} = Router.new(providers: [:gemini])

      assert {:ok, entities} = Extractor.extract_entities(text, router: router)

      assert length(entities) == 2
      assert Enum.any?(entities, fn e -> e.name == "Alice" end)
      assert Enum.any?(entities, fn e -> e.name == "Acme Corp" end)
    end

    test "supports custom entity types" do
      text = "Python is used by Django framework."

      entities_json =
        Jason.encode!([
          %{
            "name" => "Python",
            "type" => "technology",
            "description" => "Programming language",
            "aliases" => []
          },
          %{
            "name" => "Django",
            "type" => "technology",
            "description" => "Web framework",
            "aliases" => []
          }
        ])

      stub(Router, :execute, fn router, :text, prompt, _opts ->
        # Verify custom types are in prompt
        assert String.contains?(prompt, "technology")
        {:ok, entities_json, router}
      end)

      {:ok, router} = Router.new(providers: [:gemini])

      assert {:ok, entities} =
               Extractor.extract_entities(text,
                 router: router,
                 entity_types: [:technology]
               )

      assert length(entities) == 2
    end

    test "returns error when router is not provided" do
      assert {:error, :router_required} = Extractor.extract_entities("text", [])
    end
  end

  describe "extract_relationships/3" do
    test "extracts relationships between known entities" do
      text = "Alice works for Acme Corp in New York."

      entities = [
        %{name: "Alice", type: :person, description: "Person", aliases: []},
        %{name: "Acme Corp", type: :organization, description: "Company", aliases: []},
        %{name: "New York", type: :location, description: "City", aliases: []}
      ]

      relationships_json =
        Jason.encode!([
          %{
            "source" => "Alice",
            "target" => "Acme Corp",
            "type" => "works_for",
            "description" => "Employment relationship",
            "weight" => 1.0
          },
          %{
            "source" => "Acme Corp",
            "target" => "New York",
            "type" => "located_in",
            "description" => "Location relationship",
            "weight" => 1.0
          }
        ])

      stub(Router, :execute, fn router, :text, _prompt, _opts ->
        {:ok, relationships_json, router}
      end)

      {:ok, router} = Router.new(providers: [:gemini])

      assert {:ok, relationships} =
               Extractor.extract_relationships(text, entities, router: router)

      assert length(relationships) == 2

      works_for = Enum.find(relationships, fn r -> r.type == :works_for end)
      assert works_for.source == "Alice"
      assert works_for.target == "Acme Corp"
      assert works_for.weight == 1.0
    end

    test "supports custom relationship types" do
      text = "Django depends on Python."

      entities = [
        %{name: "Django", type: :technology, description: "Framework", aliases: []},
        %{name: "Python", type: :technology, description: "Language", aliases: []}
      ]

      relationships_json =
        Jason.encode!([
          %{
            "source" => "Django",
            "target" => "Python",
            "type" => "depends_on",
            "description" => "Dependency relationship",
            "weight" => 1.0
          }
        ])

      stub(Router, :execute, fn router, :text, prompt, _opts ->
        # Verify custom types are in prompt
        assert String.contains?(prompt, "depends_on")
        {:ok, relationships_json, router}
      end)

      {:ok, router} = Router.new(providers: [:gemini])

      assert {:ok, relationships} =
               Extractor.extract_relationships(text, entities,
                 router: router,
                 relationship_types: [:depends_on, :uses]
               )

      assert length(relationships) == 1
      assert hd(relationships).type == :depends_on
    end

    test "returns error when router is not provided" do
      entities = [%{name: "Alice", type: :person, description: "Person", aliases: []}]
      assert {:error, :router_required} = Extractor.extract_relationships("text", entities, [])
    end
  end

  describe "resolve_entities/2" do
    test "resolves duplicate entities to canonical forms" do
      entities = [
        %{name: "New York", type: :location, description: "City", aliases: []},
        %{name: "NYC", type: :location, description: "City", aliases: []},
        %{name: "New York City", type: :location, description: "City", aliases: []},
        %{name: "Alice", type: :person, description: "Person", aliases: []}
      ]

      resolution_json =
        Jason.encode!(%{
          "New York" => ["NYC", "New York City"],
          "Alice" => []
        })

      stub(Router, :execute, fn router, :text, _prompt, _opts ->
        {:ok, resolution_json, router}
      end)

      {:ok, router} = Router.new(providers: [:gemini])

      assert {:ok, resolved} = Extractor.resolve_entities(entities, router: router)

      # Should have 2 entities: New York (with aliases) and Alice
      assert length(resolved) == 2

      new_york = Enum.find(resolved, fn e -> e.name == "New York" end)
      assert "NYC" in new_york.aliases
      assert "New York City" in new_york.aliases

      alice = Enum.find(resolved, fn e -> e.name == "Alice" end)
      assert alice.aliases == []
    end

    test "handles entities with no duplicates" do
      entities = [
        %{name: "Alice", type: :person, description: "Person", aliases: []},
        %{name: "Bob", type: :person, description: "Person", aliases: []}
      ]

      resolution_json =
        Jason.encode!(%{
          "Alice" => [],
          "Bob" => []
        })

      stub(Router, :execute, fn router, :text, _prompt, _opts ->
        {:ok, resolution_json, router}
      end)

      {:ok, router} = Router.new(providers: [:gemini])

      assert {:ok, resolved} = Extractor.resolve_entities(entities, router: router)

      assert length(resolved) == 2
    end

    test "returns error when router is not provided" do
      entities = [%{name: "Alice", type: :person, description: "Person", aliases: []}]
      assert {:error, :router_required} = Extractor.resolve_entities(entities, [])
    end
  end

  describe "extract_batch/2" do
    test "extracts from multiple texts concurrently" do
      texts = [
        "Alice works for Acme Corp.",
        "Bob works for Tech Inc.",
        "Carol studies at MIT."
      ]

      # Mock responses for each text
      stub(Router, :execute, fn router, :text, prompt, _opts ->
        response =
          cond do
            String.contains?(prompt, "Alice") and String.contains?(prompt, "Extract entities") ->
              Jason.encode!([
                %{
                  "name" => "Alice",
                  "type" => "person",
                  "description" => "Person",
                  "aliases" => []
                },
                %{
                  "name" => "Acme Corp",
                  "type" => "organization",
                  "description" => "Company",
                  "aliases" => []
                }
              ])

            String.contains?(prompt, "Bob") and String.contains?(prompt, "Extract entities") ->
              Jason.encode!([
                %{
                  "name" => "Bob",
                  "type" => "person",
                  "description" => "Person",
                  "aliases" => []
                },
                %{
                  "name" => "Tech Inc",
                  "type" => "organization",
                  "description" => "Company",
                  "aliases" => []
                }
              ])

            String.contains?(prompt, "Carol") and String.contains?(prompt, "Extract entities") ->
              Jason.encode!([
                %{
                  "name" => "Carol",
                  "type" => "person",
                  "description" => "Person",
                  "aliases" => []
                },
                %{
                  "name" => "MIT",
                  "type" => "organization",
                  "description" => "University",
                  "aliases" => []
                }
              ])

            String.contains?(prompt, "Extract relationships") ->
              Jason.encode!([
                %{
                  "source" => "person",
                  "target" => "org",
                  "type" => "related_to",
                  "description" => "Related",
                  "weight" => 1.0
                }
              ])

            true ->
              Jason.encode!([])
          end

        {:ok, response, router}
      end)

      {:ok, router} = Router.new(providers: [:gemini])

      assert {:ok, results} = Extractor.extract_batch(texts, router: router)

      assert length(results) == 3

      # Each result should be successful and have entities
      assert Enum.all?(results, fn
               {:ok, result} -> length(result.entities) > 0
               _ -> false
             end)
    end

    test "handles partial failures in batch processing" do
      texts = [
        "Alice works for Acme Corp.",
        "This will fail"
      ]

      stub(Router, :execute, fn router, :text, prompt, _opts ->
        # Fail if the prompt contains "This will fail"
        if String.contains?(prompt, "This will fail") do
          {:error, :api_error}
        else
          response =
            if String.contains?(prompt, "Extract entities") do
              Jason.encode!([
                %{
                  "name" => "Alice",
                  "type" => "person",
                  "description" => "Person",
                  "aliases" => []
                }
              ])
            else
              Jason.encode!([])
            end

          {:ok, response, router}
        end
      end)

      {:ok, router} = Router.new(providers: [:gemini])

      assert {:ok, results} = Extractor.extract_batch(texts, router: router)

      # Results include both successes and errors
      assert length(results) == 2
      assert Enum.any?(results, &match?({:ok, _}, &1))
      assert Enum.any?(results, &match?({:error, _}, &1))
    end

    test "returns error when router is not provided" do
      assert {:error, :router_required} = Extractor.extract_batch(["text"], [])
    end

    test "handles empty batch" do
      {:ok, router} = Router.new(providers: [:gemini])

      assert {:ok, []} = Extractor.extract_batch([], router: router)
    end
  end

  describe "provider selection" do
    test "uses specified provider from options" do
      text = "Test text"

      entities_json =
        Jason.encode!([
          %{"name" => "Test", "type" => "concept", "description" => "Test", "aliases" => []}
        ])

      stub(Router, :execute, fn router, :text, _prompt, opts ->
        # Verify provider option is passed
        assert Keyword.get(opts, :provider) == :claude
        {:ok, entities_json, router}
      end)

      {:ok, router} = Router.new(providers: [:gemini, :claude])

      assert {:ok, _entities} =
               Extractor.extract_entities(text, router: router, provider: :claude)
    end

    test "uses default provider when not specified" do
      text = "Test text"

      entities_json =
        Jason.encode!([
          %{"name" => "Test", "type" => "concept", "description" => "Test", "aliases" => []}
        ])

      stub(Router, :execute, fn router, :text, _prompt, opts ->
        # Should use gemini as default (first in list)
        assert Keyword.get(opts, :provider) == :gemini
        {:ok, entities_json, router}
      end)

      {:ok, router} = Router.new(providers: [:gemini, :claude])

      assert {:ok, _entities} =
               Extractor.extract_entities(text, router: router, provider: :gemini)
    end
  end
end
