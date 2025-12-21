defmodule Rag.GraphStoreTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Rag.GraphStore
  alias Rag.GraphStore.Pgvector
  alias Rag.GraphStore.{Entity, Edge, Community}
  alias Rag.GraphStoreTest.MockRepo

  @embedding_dimension 768

  setup :verify_on_exit!

  describe "GraphStore behaviour" do
    test "defines required callbacks" do
      # Verify the behaviour exists and has required functions
      assert Code.ensure_loaded?(Rag.GraphStore)
      functions = Rag.GraphStore.__info__(:functions)

      # Check that the dispatch functions exist
      assert {:create_node, 2} in functions
      assert {:create_edge, 2} in functions
      assert {:get_node, 2} in functions
      assert {:find_neighbors, 3} in functions
      assert {:vector_search, 3} in functions
      assert {:traverse, 3} in functions
      assert {:create_community, 2} in functions
      assert {:get_community_members, 2} in functions
      assert {:update_community_summary, 3} in functions
    end
  end

  describe "Pgvector.create_node/2" do
    test "creates a node with valid attributes" do
      node_attrs = %{
        type: :person,
        name: "Alice",
        properties: %{age: 30},
        embedding: random_embedding(),
        source_chunk_ids: [1, 2, 3]
      }

      # Mock the Repo.insert call
      expected_entity = %Entity{
        id: 1,
        type: "person",
        name: "Alice",
        properties: %{age: 30},
        embedding: node_attrs.embedding,
        source_chunk_ids: [1, 2, 3]
      }

      expect(MockRepo, :insert, fn changeset ->
        assert changeset.valid?
        {:ok, expected_entity}
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, node} = Pgvector.create_node(store, node_attrs)
      assert node.id == 1
      assert node.name == "Alice"
      assert node.type == "person"
    end

    test "handles repo errors" do
      node_attrs = %{
        type: :person,
        name: "Bob",
        properties: %{},
        embedding: nil,
        source_chunk_ids: []
      }

      expect(MockRepo, :insert, fn _changeset ->
        {:error, :database_error}
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:error, :database_error} = Pgvector.create_node(store, node_attrs)
    end

    test "converts atom type to string" do
      node_attrs = %{
        type: :organization,
        name: "Acme Corp",
        properties: %{},
        embedding: nil,
        source_chunk_ids: []
      }

      expect(MockRepo, :insert, fn changeset ->
        assert get_field(changeset, :type) == "organization"
        {:ok, %Entity{id: 1, type: "organization", name: "Acme Corp"}}
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, _node} = Pgvector.create_node(store, node_attrs)
    end
  end

  describe "Pgvector.create_edge/2" do
    test "creates an edge between two nodes" do
      edge_attrs = %{
        from_id: 1,
        to_id: 2,
        type: :knows,
        weight: 0.8,
        properties: %{since: "2020"}
      }

      expected_edge = %Edge{
        id: 1,
        from_id: 1,
        to_id: 2,
        type: "knows",
        weight: 0.8,
        properties: %{since: "2020"}
      }

      expect(MockRepo, :insert, fn changeset ->
        assert changeset.valid?
        {:ok, expected_edge}
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, edge} = Pgvector.create_edge(store, edge_attrs)
      assert edge.from_id == 1
      assert edge.to_id == 2
      assert edge.type == "knows"
    end

    test "defaults weight to 1.0 if not provided" do
      edge_attrs = %{
        from_id: 1,
        to_id: 2,
        type: :related,
        properties: %{}
      }

      expect(MockRepo, :insert, fn changeset ->
        assert get_field(changeset, :weight) == 1.0
        {:ok, %Edge{id: 1, from_id: 1, to_id: 2, type: "related", weight: 1.0}}
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, edge} = Pgvector.create_edge(store, edge_attrs)
      assert edge.weight == 1.0
    end
  end

  describe "Pgvector.get_node/2" do
    test "retrieves a node by id" do
      entity = %Entity{
        id: 1,
        type: "person",
        name: "Alice",
        properties: %{age: 30},
        embedding: random_embedding(),
        source_chunk_ids: [1]
      }

      expect(MockRepo, :get, fn Entity, 1 ->
        entity
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, node} = Pgvector.get_node(store, 1)
      assert node.id == 1
      assert node.name == "Alice"
    end

    test "returns error when node not found" do
      expect(MockRepo, :get, fn Entity, 999 ->
        nil
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:error, :not_found} = Pgvector.get_node(store, 999)
    end
  end

  describe "Pgvector.find_neighbors/3" do
    test "finds direct neighbors of a node" do
      # Mock the query execution
      neighbors = [
        %{
          id: 2,
          name: "Bob",
          type: "person",
          properties: %{},
          embedding: nil,
          source_chunk_ids: [],
          edge_type: "knows",
          weight: 0.8
        },
        %{
          id: 3,
          name: "Carol",
          type: "person",
          properties: %{},
          embedding: nil,
          source_chunk_ids: [],
          edge_type: "knows",
          weight: 0.9
        }
      ]

      expect(MockRepo, :all, fn _query ->
        neighbors
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, result} = Pgvector.find_neighbors(store, 1, limit: 10)
      assert length(result) == 2
      assert Enum.any?(result, fn n -> n.name == "Bob" end)
    end

    test "supports direction option for outgoing edges only" do
      neighbors = [
        %{
          id: 2,
          name: "Bob",
          type: "person",
          properties: %{},
          embedding: nil,
          source_chunk_ids: [],
          edge_type: "knows",
          weight: 0.8
        }
      ]

      expect(MockRepo, :all, fn _query ->
        neighbors
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, result} = Pgvector.find_neighbors(store, 1, direction: :out, limit: 10)
      assert length(result) == 1
    end

    test "supports direction option for incoming edges only" do
      neighbors = [
        %{
          id: 3,
          name: "Carol",
          type: "person",
          properties: %{},
          embedding: nil,
          source_chunk_ids: [],
          edge_type: "knows",
          weight: 0.9
        }
      ]

      expect(MockRepo, :all, fn _query ->
        neighbors
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, result} = Pgvector.find_neighbors(store, 1, direction: :in, limit: 10)
      assert length(result) == 1
    end

    test "filters by edge type" do
      neighbors = [
        %{
          id: 2,
          name: "Acme",
          type: "organization",
          properties: %{},
          embedding: nil,
          source_chunk_ids: [],
          edge_type: "works_at",
          weight: 1.0
        }
      ]

      expect(MockRepo, :all, fn _query ->
        neighbors
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, result} = Pgvector.find_neighbors(store, 1, edge_type: :works_at)
      assert length(result) == 1
      assert hd(result).type == "organization"
    end
  end

  describe "Pgvector.vector_search/3" do
    test "finds similar nodes by embedding" do
      query_embedding = random_embedding()

      similar_nodes = [
        %Entity{
          id: 1,
          name: "Alice",
          type: "person",
          properties: %{},
          embedding: random_embedding()
        },
        %Entity{
          id: 2,
          name: "Bob",
          type: "person",
          properties: %{},
          embedding: random_embedding()
        }
      ]

      expect(MockRepo, :all, fn _query ->
        similar_nodes
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, results} = Pgvector.vector_search(store, query_embedding, limit: 10)
      assert length(results) == 2
    end

    test "respects limit option" do
      query_embedding = random_embedding()

      similar_nodes = [
        %Entity{
          id: 1,
          name: "Alice",
          type: "person",
          properties: %{},
          embedding: random_embedding()
        }
      ]

      expect(MockRepo, :all, fn _query ->
        similar_nodes
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, results} = Pgvector.vector_search(store, query_embedding, limit: 5)
      assert length(results) == 1
    end

    test "filters by node type" do
      query_embedding = random_embedding()

      organizations = [
        %Entity{
          id: 5,
          name: "Acme",
          type: "organization",
          properties: %{},
          embedding: random_embedding()
        }
      ]

      expect(MockRepo, :all, fn _query ->
        organizations
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, results} = Pgvector.vector_search(store, query_embedding, type: :organization)
      assert length(results) == 1
      assert hd(results).type == "organization"
    end
  end

  describe "Pgvector.traverse/3" do
    test "traverses graph from starting node using BFS" do
      # Mock recursive CTE query results
      traversal_results = [
        %{
          id: 1,
          name: "Alice",
          type: "person",
          properties: %{},
          embedding: nil,
          source_chunk_ids: [],
          depth: 0
        },
        %{
          id: 2,
          name: "Bob",
          type: "person",
          properties: %{},
          embedding: nil,
          source_chunk_ids: [],
          depth: 1
        },
        %{
          id: 3,
          name: "Carol",
          type: "person",
          properties: %{},
          embedding: nil,
          source_chunk_ids: [],
          depth: 2
        }
      ]

      expect(MockRepo, :all, fn _query ->
        traversal_results
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, results} = Pgvector.traverse(store, 1, max_depth: 2)
      assert length(results) == 3
    end

    test "respects max_depth option" do
      traversal_results = [
        %{
          id: 1,
          name: "Alice",
          type: "person",
          properties: %{},
          embedding: nil,
          source_chunk_ids: [],
          depth: 0
        },
        %{
          id: 2,
          name: "Bob",
          type: "person",
          properties: %{},
          embedding: nil,
          source_chunk_ids: [],
          depth: 1
        }
      ]

      expect(MockRepo, :all, fn _query ->
        traversal_results
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, results} = Pgvector.traverse(store, 1, max_depth: 1)
      assert length(results) == 2
      assert Enum.all?(results, fn r -> r.depth <= 1 end)
    end

    test "supports algorithm option for DFS" do
      traversal_results = [
        %{
          id: 1,
          name: "Alice",
          type: "person",
          properties: %{},
          embedding: nil,
          source_chunk_ids: [],
          depth: 0
        },
        %{
          id: 3,
          name: "Carol",
          type: "person",
          properties: %{},
          embedding: nil,
          source_chunk_ids: [],
          depth: 2
        },
        %{
          id: 2,
          name: "Bob",
          type: "person",
          properties: %{},
          embedding: nil,
          source_chunk_ids: [],
          depth: 1
        }
      ]

      expect(MockRepo, :all, fn _query ->
        traversal_results
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, results} = Pgvector.traverse(store, 1, algorithm: :dfs, max_depth: 2)
      assert length(results) == 3
    end
  end

  describe "Pgvector.create_community/2" do
    test "creates a community with entity ids" do
      community_attrs = %{
        level: 0,
        summary: "A group of people",
        entity_ids: [1, 2, 3]
      }

      expected_community = %Community{
        id: 1,
        level: 0,
        summary: "A group of people",
        entity_ids: [1, 2, 3]
      }

      expect(MockRepo, :insert, fn changeset ->
        assert changeset.valid?
        {:ok, expected_community}
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, community} = Pgvector.create_community(store, community_attrs)
      assert community.id == 1
      assert community.level == 0
      assert length(community.entity_ids) == 3
    end

    test "creates community without summary" do
      community_attrs = %{
        level: 1,
        summary: nil,
        entity_ids: [4, 5]
      }

      expected_community = %Community{
        id: 2,
        level: 1,
        summary: nil,
        entity_ids: [4, 5]
      }

      expect(MockRepo, :insert, fn _changeset ->
        {:ok, expected_community}
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, community} = Pgvector.create_community(store, community_attrs)
      assert is_nil(community.summary)
    end
  end

  describe "Pgvector.get_community_members/2" do
    test "retrieves all entities in a community" do
      community = %Community{
        id: 1,
        level: 0,
        summary: "Test community",
        entity_ids: [1, 2, 3]
      }

      entities = [
        %Entity{id: 1, name: "Alice", type: "person", properties: %{}},
        %Entity{id: 2, name: "Bob", type: "person", properties: %{}},
        %Entity{id: 3, name: "Carol", type: "person", properties: %{}}
      ]

      expect(MockRepo, :get, fn Community, 1 ->
        community
      end)

      expect(MockRepo, :all, fn _query ->
        entities
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, members} = Pgvector.get_community_members(store, 1)
      assert length(members) == 3
      # Members are returned as node maps, not Entity structs
      assert Enum.all?(members, fn m ->
               is_map(m) and Map.has_key?(m, :id) and Map.has_key?(m, :name)
             end)
    end

    test "returns error when community not found" do
      expect(MockRepo, :get, fn Community, 999 ->
        nil
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:error, :not_found} = Pgvector.get_community_members(store, 999)
    end
  end

  describe "Pgvector.update_community_summary/3" do
    test "updates community summary" do
      community = %Community{
        id: 1,
        level: 0,
        summary: "Old summary",
        entity_ids: [1, 2]
      }

      updated_community = %Community{
        id: 1,
        level: 0,
        summary: "New summary",
        entity_ids: [1, 2]
      }

      expect(MockRepo, :get, fn Community, 1 ->
        community
      end)

      expect(MockRepo, :update, fn changeset ->
        assert get_field(changeset, :summary) == "New summary"
        {:ok, updated_community}
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, result} = Pgvector.update_community_summary(store, 1, "New summary")
      assert result.summary == "New summary"
    end

    test "returns error when community not found" do
      expect(MockRepo, :get, fn Community, 999 ->
        nil
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:error, :not_found} = Pgvector.update_community_summary(store, 999, "New")
    end
  end

  describe "GraphStore convenience functions" do
    test "create_node delegates to implementation" do
      node_attrs = %{
        type: :person,
        name: "Alice",
        properties: %{},
        embedding: nil,
        source_chunk_ids: []
      }

      expected_entity = %Entity{
        id: 1,
        type: "person",
        name: "Alice",
        properties: %{},
        embedding: nil,
        source_chunk_ids: []
      }

      expect(MockRepo, :insert, fn _changeset ->
        {:ok, expected_entity}
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, node} = GraphStore.create_node(store, node_attrs)
      assert node.name == "Alice"
    end

    test "create_edge delegates to implementation" do
      edge_attrs = %{
        from_id: 1,
        to_id: 2,
        type: :knows,
        weight: 0.8,
        properties: %{}
      }

      expected_edge = %Edge{
        id: 1,
        from_id: 1,
        to_id: 2,
        type: "knows",
        weight: 0.8,
        properties: %{}
      }

      expect(MockRepo, :insert, fn changeset ->
        assert changeset.valid?
        {:ok, expected_edge}
      end)

      store = %Pgvector{repo: MockRepo}
      assert {:ok, edge} = GraphStore.create_edge(store, edge_attrs)
      assert edge.type == "knows"
    end
  end

  # Helper to generate random embeddings for testing
  defp random_embedding do
    Enum.map(1..@embedding_dimension, fn _ -> :rand.uniform() end)
  end

  # Helper to get field from changeset
  defp get_field(changeset, field) do
    Ecto.Changeset.get_field(changeset, field)
  end
end
