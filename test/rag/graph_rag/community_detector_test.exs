defmodule Rag.GraphRAG.CommunityDetectorTest do
  use ExUnit.Case, async: true

  alias Rag.GraphRAG.CommunityDetector

  # Simple test implementation of graph store
  defmodule TestGraphStore do
    defstruct [:entities, :edges, :get_entities_fn, :get_relationships_fn]

    def get_all_entities(%{entities: entities}) when is_list(entities), do: {:ok, entities}
    def get_all_entities(%{entities: fun}) when is_function(fun), do: fun.()

    def get_all_edges(%{edges: edges}) when is_list(edges), do: {:ok, edges}
    def get_all_edges(%{edges: fun}) when is_function(fun), do: fun.()

    def get_entities_by_ids(%{get_entities_fn: fun}, ids) when is_function(fun),
      do: fun.(ids)

    def get_entities_by_ids(%{entities: all_entities}, ids) when is_list(all_entities) do
      entities = Enum.filter(all_entities, fn e -> e.id in ids end)
      {:ok, entities}
    end

    def get_relationships_between(%{get_relationships_fn: fun}, ids) when is_function(fun),
      do: fun.(ids)

    def get_relationships_between(%{edges: all_edges}, ids) when is_list(all_edges) do
      relationships = Enum.filter(all_edges, fn e -> e.from_id in ids and e.to_id in ids end)
      {:ok, relationships}
    end
  end

  # Simple test implementation of router
  defmodule TestRouter do
    defstruct [:execute_fn]

    def execute(%{execute_fn: fun}, type, prompt, opts), do: fun.(type, prompt, opts)
  end

  describe "detect/2" do
    test "detects communities using label propagation with default options" do
      graph_store = %TestGraphStore{
        entities: [
          %{id: 1, name: "Alice"},
          %{id: 2, name: "Bob"},
          %{id: 3, name: "Charlie"},
          %{id: 4, name: "Dave"}
        ],
        edges: [
          %{from_id: 1, to_id: 2},
          %{from_id: 2, to_id: 3},
          %{from_id: 4, to_id: 4}
        ]
      }

      {:ok, communities} = CommunityDetector.detect(graph_store)

      assert is_list(communities)
      assert length(communities) > 0

      # Each community should have required fields
      for community <- communities do
        assert Map.has_key?(community, :id)
        assert Map.has_key?(community, :level)
        assert Map.has_key?(community, :entity_ids)
        assert is_list(community.entity_ids)
        assert community.level == 0
      end
    end

    test "detects communities with custom max_iterations" do
      graph_store = %TestGraphStore{
        entities: [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}],
        edges: [%{from_id: 1, to_id: 2}]
      }

      {:ok, communities} = CommunityDetector.detect(graph_store, max_iterations: 50)

      assert is_list(communities)
    end

    test "handles empty graph" do
      graph_store = %TestGraphStore{
        entities: [],
        edges: []
      }

      {:ok, communities} = CommunityDetector.detect(graph_store)

      assert communities == []
    end

    test "handles graph with single node" do
      graph_store = %TestGraphStore{
        entities: [%{id: 1, name: "Alice"}],
        edges: []
      }

      {:ok, communities} = CommunityDetector.detect(graph_store)

      assert length(communities) == 1
      assert hd(communities).entity_ids == [1]
    end

    test "groups connected nodes into same community" do
      # Triangle graph: 1-2-3-1
      graph_store = %TestGraphStore{
        entities: [
          %{id: 1, name: "Alice"},
          %{id: 2, name: "Bob"},
          %{id: 3, name: "Charlie"}
        ],
        edges: [
          %{from_id: 1, to_id: 2},
          %{from_id: 2, to_id: 3},
          %{from_id: 3, to_id: 1}
        ]
      }

      {:ok, communities} = CommunityDetector.detect(graph_store)

      # All three nodes should be in the same community
      assert length(communities) == 1
      assert Enum.sort(hd(communities).entity_ids) == [1, 2, 3]
    end

    test "separates disconnected components" do
      # Two separate pairs: 1-2 and 3-4
      graph_store = %TestGraphStore{
        entities: [
          %{id: 1, name: "Alice"},
          %{id: 2, name: "Bob"},
          %{id: 3, name: "Charlie"},
          %{id: 4, name: "Dave"}
        ],
        edges: [
          %{from_id: 1, to_id: 2},
          %{from_id: 3, to_id: 4}
        ]
      }

      {:ok, communities} = CommunityDetector.detect(graph_store)

      # Should have 2 communities
      assert length(communities) == 2

      entity_sets =
        Enum.map(communities, fn c ->
          MapSet.new(c.entity_ids)
        end)

      # Check that we have {1,2} and {3,4} as separate communities
      assert MapSet.new([1, 2]) in entity_sets
      assert MapSet.new([3, 4]) in entity_sets
    end

    test "returns error when graph_store fails" do
      graph_store = %TestGraphStore{
        entities: fn -> {:error, :database_error} end,
        edges: []
      }

      assert {:error, :database_error} = CommunityDetector.detect(graph_store)
    end
  end

  describe "summarize_communities/3" do
    test "generates summaries for communities using LLM" do
      graph_store = %TestGraphStore{
        entities: [
          %{id: 1, name: "Alice", type: "PERSON", properties: %{role: "Engineer"}},
          %{id: 2, name: "TechCorp", type: "ORGANIZATION", properties: %{industry: "Tech"}}
        ],
        edges: [%{from_id: 1, to_id: 2, type: "WORKS_FOR", properties: %{}}],
        get_entities_fn: fn [1, 2] ->
          {:ok,
           [
             %{id: 1, name: "Alice", type: "PERSON", properties: %{role: "Engineer"}},
             %{id: 2, name: "TechCorp", type: "ORGANIZATION", properties: %{industry: "Tech"}}
           ]}
        end,
        get_relationships_fn: fn [1, 2] ->
          {:ok, [%{from_id: 1, to_id: 2, type: "WORKS_FOR", properties: %{}}]}
        end
      }

      router = %TestRouter{
        execute_fn: fn :text, prompt, _opts ->
          assert String.contains?(prompt, "Alice")
          assert String.contains?(prompt, "TechCorp")
          {:ok, "Alice is an engineer who works at TechCorp, a technology company."}
        end
      }

      communities = [
        %{
          id: "comm1",
          level: 0,
          entity_ids: [1, 2],
          summary: nil
        }
      ]

      {:ok, summarized} =
        CommunityDetector.summarize_communities(graph_store, communities, router: router)

      assert length(summarized) == 1

      assert hd(summarized).summary ==
               "Alice is an engineer who works at TechCorp, a technology company."
    end

    test "handles multiple communities" do
      graph_store = %TestGraphStore{
        entities: [
          %{id: 1, name: "Alice", type: "PERSON", properties: %{}},
          %{id: 2, name: "Bob", type: "PERSON", properties: %{}}
        ],
        edges: [],
        get_entities_fn: fn
          [1] -> {:ok, [%{id: 1, name: "Alice", type: "PERSON", properties: %{}}]}
          [2] -> {:ok, [%{id: 2, name: "Bob", type: "PERSON", properties: %{}}]}
        end,
        get_relationships_fn: fn _ -> {:ok, []} end
      }

      router = %TestRouter{
        execute_fn: fn :text, _prompt, _opts -> {:ok, "Community summary"} end
      }

      communities = [
        %{id: "comm1", level: 0, entity_ids: [1], summary: nil},
        %{id: "comm2", level: 0, entity_ids: [2], summary: nil}
      ]

      {:ok, summarized} =
        CommunityDetector.summarize_communities(graph_store, communities, router: router)

      assert length(summarized) == 2
      assert Enum.all?(summarized, fn c -> c.summary == "Community summary" end)
    end

    test "handles empty communities list" do
      graph_store = %TestGraphStore{entities: [], edges: []}

      {:ok, result} = CommunityDetector.summarize_communities(graph_store, [])

      assert result == []
    end

    test "returns error when entity fetch fails" do
      graph_store = %TestGraphStore{
        entities: [],
        edges: [],
        get_entities_fn: fn [1] -> {:error, :not_found} end
      }

      router = %TestRouter{execute_fn: fn _, _, _ -> {:ok, "test"} end}

      communities = [
        %{id: "comm1", level: 0, entity_ids: [1], summary: nil}
      ]

      assert {:error, :not_found} =
               CommunityDetector.summarize_communities(graph_store, communities, router: router)
    end

    test "returns error when LLM call fails" do
      graph_store = %TestGraphStore{
        entities: [%{id: 1, name: "Alice", type: "PERSON", properties: %{}}],
        edges: [],
        get_entities_fn: fn [1] ->
          {:ok, [%{id: 1, name: "Alice", type: "PERSON", properties: %{}}]}
        end,
        get_relationships_fn: fn [1] -> {:ok, []} end
      }

      router = %TestRouter{
        execute_fn: fn :text, _prompt, _opts -> {:error, :rate_limit} end
      }

      communities = [
        %{id: "comm1", level: 0, entity_ids: [1], summary: nil}
      ]

      assert {:error, :rate_limit} =
               CommunityDetector.summarize_communities(graph_store, communities, router: router)
    end
  end

  describe "detect_and_summarize/2" do
    test "detects and summarizes communities in one step" do
      graph_store = %TestGraphStore{
        entities: [%{id: 1, name: "Alice", type: "PERSON", properties: %{}}],
        edges: [],
        get_entities_fn: fn [1] ->
          {:ok, [%{id: 1, name: "Alice", type: "PERSON", properties: %{}}]}
        end,
        get_relationships_fn: fn [1] -> {:ok, []} end
      }

      router = %TestRouter{
        execute_fn: fn :text, _prompt, _opts -> {:ok, "Alice community"} end
      }

      {:ok, communities} = CommunityDetector.detect_and_summarize(graph_store, router: router)

      assert length(communities) == 1
      assert hd(communities).summary == "Alice community"
    end

    test "returns error if detection fails" do
      graph_store = %TestGraphStore{
        entities: fn -> {:error, :connection_failed} end,
        edges: []
      }

      assert {:error, :connection_failed} = CommunityDetector.detect_and_summarize(graph_store)
    end

    test "returns error if summarization fails" do
      graph_store = %TestGraphStore{
        entities: [%{id: 1, name: "Alice"}],
        edges: [],
        get_entities_fn: fn [1] -> {:error, :timeout} end
      }

      router = %TestRouter{execute_fn: fn _, _, _ -> {:ok, "test"} end}

      assert {:error, :timeout} =
               CommunityDetector.detect_and_summarize(graph_store, router: router)
    end
  end

  describe "build_hierarchy/2" do
    test "builds single level hierarchy by default" do
      graph_store = %TestGraphStore{
        entities: [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}],
        edges: [%{from_id: 1, to_id: 2}]
      }

      {:ok, hierarchy} = CommunityDetector.build_hierarchy(graph_store)

      assert is_list(hierarchy)
      assert length(hierarchy) == 1
      assert is_list(hd(hierarchy))

      # First level communities
      for community <- hd(hierarchy) do
        assert community.level == 0
      end
    end

    test "builds multi-level hierarchy when levels > 1" do
      graph_store = %TestGraphStore{
        entities: [
          %{id: 1, name: "A"},
          %{id: 2, name: "B"},
          %{id: 3, name: "C"},
          %{id: 4, name: "D"}
        ],
        edges: [
          %{from_id: 1, to_id: 2},
          %{from_id: 3, to_id: 4}
        ]
      }

      {:ok, hierarchy} = CommunityDetector.build_hierarchy(graph_store, levels: 2)

      assert length(hierarchy) == 2

      # Level 0 communities
      assert Enum.all?(Enum.at(hierarchy, 0), fn c -> c.level == 0 end)

      # Level 1 communities
      assert Enum.all?(Enum.at(hierarchy, 1), fn c -> c.level == 1 end)
    end

    test "handles empty graph for hierarchy" do
      graph_store = %TestGraphStore{
        entities: [],
        edges: []
      }

      {:ok, hierarchy} = CommunityDetector.build_hierarchy(graph_store)

      assert hierarchy == [[]]
    end

    test "returns error if any level detection fails" do
      graph_store = %TestGraphStore{
        entities: [%{id: 1, name: "Alice"}],
        edges: fn -> {:error, :network_error} end
      }

      assert {:error, :network_error} = CommunityDetector.build_hierarchy(graph_store)
    end
  end
end
