defmodule Rag.GraphStore.TripleStoreTest do
  use ExUnit.Case

  alias Rag.GraphStore.TripleStore

  setup do
    data_dir = System.tmp_dir!() <> "/triplestore_test_#{System.unique_integer([:positive])}"

    {:ok, store} = TripleStore.open(data_dir: data_dir)

    on_exit(fn ->
      TripleStore.close(store)
      File.rm_rf!(data_dir)
    end)

    %{store: store}
  end

  describe "create_node/2" do
    test "creates node with required fields", %{store: store} do
      {:ok, node} =
        Rag.GraphStore.create_node(store, %{
          type: :function,
          name: "calculate_total"
        })

      assert node.id != nil
      assert node.type == :function
      assert node.name == "calculate_total"
    end

    test "stores properties", %{store: store} do
      {:ok, node} =
        Rag.GraphStore.create_node(store, %{
          type: :function,
          name: "foo",
          properties: %{file: "lib/foo.ex", line: 42}
        })

      assert node.properties.file == "lib/foo.ex"
      assert node.properties.line == 42
    end

    test "returns error without type", %{store: store} do
      assert {:error, :type_required} =
               Rag.GraphStore.create_node(store, %{name: "foo"})
    end

    test "returns error without name", %{store: store} do
      assert {:error, :name_required} =
               Rag.GraphStore.create_node(store, %{type: :function})
    end
  end

  describe "get_node/2" do
    test "retrieves existing node", %{store: store} do
      {:ok, created} =
        Rag.GraphStore.create_node(store, %{
          type: :function,
          name: "foo"
        })

      {:ok, retrieved} = Rag.GraphStore.get_node(store, created.id)

      assert retrieved.id == created.id
      assert retrieved.name == created.name
      assert retrieved.type == created.type
    end

    test "returns error for non-existent node", %{store: store} do
      assert {:error, :not_found} = Rag.GraphStore.get_node(store, 99999)
    end
  end

  describe "create_edge/2" do
    test "creates edge between existing nodes", %{store: store} do
      {:ok, from} = Rag.GraphStore.create_node(store, %{type: :function, name: "a"})
      {:ok, to} = Rag.GraphStore.create_node(store, %{type: :function, name: "b"})

      {:ok, edge} =
        Rag.GraphStore.create_edge(store, %{
          from_id: from.id,
          to_id: to.id,
          type: :calls
        })

      assert edge.from_id == from.id
      assert edge.to_id == to.id
      assert edge.type == :calls
    end

    test "returns error for self-loop", %{store: store} do
      {:ok, node} = Rag.GraphStore.create_node(store, %{type: :function, name: "a"})

      assert {:error, :self_loop_not_allowed} =
               Rag.GraphStore.create_edge(store, %{
                 from_id: node.id,
                 to_id: node.id,
                 type: :calls
               })
    end

    test "returns error for non-existent from node", %{store: store} do
      {:ok, to} = Rag.GraphStore.create_node(store, %{type: :function, name: "b"})

      assert {:error, :entity_not_found} =
               Rag.GraphStore.create_edge(store, %{
                 from_id: 99999,
                 to_id: to.id,
                 type: :calls
               })
    end
  end

  describe "find_neighbors/3" do
    setup %{store: store} do
      {:ok, a} = Rag.GraphStore.create_node(store, %{type: :function, name: "a"})
      {:ok, b} = Rag.GraphStore.create_node(store, %{type: :function, name: "b"})
      {:ok, c} = Rag.GraphStore.create_node(store, %{type: :function, name: "c"})
      {:ok, d} = Rag.GraphStore.create_node(store, %{type: :module, name: "d"})

      Rag.GraphStore.create_edge(store, %{from_id: a.id, to_id: b.id, type: :calls})
      Rag.GraphStore.create_edge(store, %{from_id: b.id, to_id: c.id, type: :calls})
      Rag.GraphStore.create_edge(store, %{from_id: a.id, to_id: d.id, type: :imports})

      %{a: a, b: b, c: c, d: d}
    end

    test "finds outgoing neighbors", %{store: store, a: a, b: b, d: d} do
      {:ok, neighbors} = Rag.GraphStore.find_neighbors(store, a.id, direction: :out)

      neighbor_ids = Enum.map(neighbors, & &1.id) |> Enum.sort()
      assert neighbor_ids == Enum.sort([b.id, d.id])
    end

    test "finds incoming neighbors", %{store: store, a: a, b: b} do
      {:ok, neighbors} = Rag.GraphStore.find_neighbors(store, b.id, direction: :in)

      assert length(neighbors) == 1
      assert hd(neighbors).id == a.id
    end

    test "filters by edge type", %{store: store, a: a, b: b} do
      {:ok, neighbors} =
        Rag.GraphStore.find_neighbors(store, a.id,
          direction: :out,
          edge_type: :calls
        )

      assert length(neighbors) == 1
      assert hd(neighbors).id == b.id
    end

    test "respects limit", %{store: store, a: a} do
      {:ok, neighbors} =
        Rag.GraphStore.find_neighbors(store, a.id,
          direction: :out,
          limit: 1
        )

      assert length(neighbors) == 1
    end
  end

  describe "traverse/3" do
    setup %{store: store} do
      {:ok, a} = Rag.GraphStore.create_node(store, %{type: :function, name: "a"})
      {:ok, b} = Rag.GraphStore.create_node(store, %{type: :function, name: "b"})
      {:ok, c} = Rag.GraphStore.create_node(store, %{type: :function, name: "c"})
      {:ok, d} = Rag.GraphStore.create_node(store, %{type: :function, name: "d"})

      Rag.GraphStore.create_edge(store, %{from_id: a.id, to_id: b.id, type: :calls})
      Rag.GraphStore.create_edge(store, %{from_id: b.id, to_id: c.id, type: :calls})
      Rag.GraphStore.create_edge(store, %{from_id: c.id, to_id: d.id, type: :calls})

      %{a: a, b: b, c: c, d: d}
    end

    test "BFS respects max_depth", %{store: store, a: a, b: b, c: c} do
      {:ok, nodes} =
        Rag.GraphStore.traverse(store, a.id,
          algorithm: :bfs,
          max_depth: 2
        )

      node_ids = Enum.map(nodes, & &1.id)
      assert a.id in node_ids
      assert b.id in node_ids
      assert c.id in node_ids
    end

    test "includes depth in results", %{store: store, a: a} do
      {:ok, nodes} = Rag.GraphStore.traverse(store, a.id, max_depth: 1)

      start_node = Enum.find(nodes, &(&1.id == a.id))
      assert start_node.depth == 0
    end
  end

  describe "community operations" do
    test "create_community/2 creates community", %{store: store} do
      {:ok, n1} = Rag.GraphStore.create_node(store, %{type: :function, name: "a"})
      {:ok, n2} = Rag.GraphStore.create_node(store, %{type: :function, name: "b"})

      {:ok, community} =
        Rag.GraphStore.create_community(store, %{
          entity_ids: [n1.id, n2.id],
          level: 1,
          summary: "Test community"
        })

      assert community.entity_ids == [n1.id, n2.id]
      assert community.level == 1
      assert community.summary == "Test community"
    end

    test "get_community_members/2 returns member nodes", %{store: store} do
      {:ok, n1} = Rag.GraphStore.create_node(store, %{type: :function, name: "a"})
      {:ok, n2} = Rag.GraphStore.create_node(store, %{type: :function, name: "b"})

      {:ok, community} =
        Rag.GraphStore.create_community(store, %{
          entity_ids: [n1.id, n2.id]
        })

      {:ok, members} = Rag.GraphStore.get_community_members(store, community.id)

      member_ids = Enum.map(members, & &1.id) |> Enum.sort()
      assert member_ids == Enum.sort([n1.id, n2.id])
    end

    test "update_community_summary/3 updates summary", %{store: store} do
      {:ok, n1} = Rag.GraphStore.create_node(store, %{type: :function, name: "a"})

      {:ok, community} =
        Rag.GraphStore.create_community(store, %{
          entity_ids: [n1.id]
        })

      {:ok, updated} =
        Rag.GraphStore.update_community_summary(
          store,
          community.id,
          "Updated summary"
        )

      assert updated.summary == "Updated summary"
    end
  end
end
