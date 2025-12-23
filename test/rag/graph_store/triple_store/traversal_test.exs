defmodule Rag.GraphStore.TripleStore.TraversalTest do
  use ExUnit.Case

  alias Rag.GraphStore.TripleStore.{Mapper, Traversal, URI}
  alias TripleStore.Adapter
  alias TripleStore.Dictionary.{IdToString, Manager, StringToId}
  alias TripleStore.Index
  alias TripleStore.Backend.RocksDB.NIF

  setup do
    data_dir = System.tmp_dir!() <> "/traversal_test_#{System.unique_integer([:positive])}"
    File.mkdir_p!(data_dir)

    {:ok, db} = NIF.open(data_dir)
    {:ok, manager} = Manager.start_link(db: db)

    on_exit(fn ->
      if Process.alive?(manager) do
        Manager.stop(manager)
      end

      NIF.close(db)
      File.rm_rf!(data_dir)
    end)

    %{db: db, manager: manager}
  end

  describe "bfs/4" do
    test "returns start node at depth 0", %{db: db, manager: manager} do
      insert_edge(db, manager, 1, 2, :calls)

      start_term_id = entity_term_id(db, 1)
      results = Traversal.bfs(db, start_term_id, 1)

      assert {start_term_id, 0} in results
    end

    test "finds neighbors at depth 1", %{db: db, manager: manager} do
      insert_edge(db, manager, 1, 2, :calls)
      insert_edge(db, manager, 2, 3, :calls)

      start_term_id = entity_term_id(db, 1)
      results = Traversal.bfs(db, start_term_id, 2)

      depths = results |> Enum.map(fn {id, depth} -> {decode_entity_id(db, id), depth} end)
      assert {2, 1} in depths
    end

    test "respects max_depth", %{db: db, manager: manager} do
      insert_edge(db, manager, 1, 2, :calls)
      insert_edge(db, manager, 2, 3, :calls)
      insert_edge(db, manager, 3, 4, :calls)

      start_term_id = entity_term_id(db, 1)
      results = Traversal.bfs(db, start_term_id, 1)

      ids = results |> Enum.map(fn {id, _depth} -> decode_entity_id(db, id) end)

      assert 1 in ids
      assert 2 in ids
      refute 3 in ids
      refute 4 in ids
    end
  end

  describe "dfs/4" do
    test "explores depth-first", %{db: db, manager: manager} do
      insert_edge(db, manager, 1, 2, :calls)
      insert_edge(db, manager, 2, 3, :calls)
      insert_edge(db, manager, 1, 4, :calls)

      start_term_id = entity_term_id(db, 1)

      bfs_ids =
        db
        |> Traversal.bfs(start_term_id, 3)
        |> Enum.map(fn {id, _} -> decode_entity_id(db, id) end)

      dfs_ids =
        db
        |> Traversal.dfs(start_term_id, 3)
        |> Enum.map(fn {id, _} -> decode_entity_id(db, id) end)

      assert Enum.find_index(bfs_ids, &(&1 == 4)) < Enum.find_index(bfs_ids, &(&1 == 3))
      assert Enum.find_index(dfs_ids, &(&1 == 3)) < Enum.find_index(dfs_ids, &(&1 == 4))
    end
  end

  describe "get_neighbors/4" do
    test "finds outgoing neighbors", %{db: db, manager: manager} do
      insert_edge(db, manager, 1, 2, :calls)
      insert_edge(db, manager, 1, 3, :calls)

      start_term_id = entity_term_id(db, 1)
      neighbors = Traversal.get_neighbors(db, start_term_id, :out)

      ids = neighbors |> Enum.map(&decode_entity_id(db, &1)) |> Enum.sort()
      assert ids == [2, 3]
    end

    test "finds incoming neighbors", %{db: db, manager: manager} do
      insert_edge(db, manager, 2, 1, :calls)
      insert_edge(db, manager, 3, 1, :calls)

      start_term_id = entity_term_id(db, 1)
      neighbors = Traversal.get_neighbors(db, start_term_id, :in)

      ids = neighbors |> Enum.map(&decode_entity_id(db, &1)) |> Enum.sort()
      assert ids == [2, 3]
    end

    test "filters by edge type", %{db: db, manager: manager} do
      insert_edge(db, manager, 1, 2, :calls)
      insert_edge(db, manager, 1, 3, :imports)

      start_term_id = entity_term_id(db, 1)
      neighbors = Traversal.get_neighbors(db, start_term_id, :out, :calls)

      ids = neighbors |> Enum.map(&decode_entity_id(db, &1))
      assert ids == [2]
    end
  end

  defp insert_edge(db, manager, from_id, to_id, type) do
    edge_id = System.unique_integer([:positive])
    triples = Mapper.edge_to_triples(%{from_id: from_id, to_id: to_id, type: type}, edge_id)
    terms = Enum.flat_map(triples, fn {s, p, o} -> [s, p, o] end)
    {:ok, ids} = Adapter.terms_to_ids(manager, terms)

    id_triples =
      ids
      |> Enum.chunk_every(3)
      |> Enum.map(fn [s, p, o] -> {s, p, o} end)

    :ok = Index.insert_triples(db, id_triples)
  end

  defp entity_term_id(db, entity_id) do
    {:ok, term_id} = StringToId.lookup_id(db, RDF.iri(URI.entity(entity_id)))
    term_id
  end

  defp decode_entity_id(db, term_id) do
    {:ok, %RDF.IRI{value: uri}} = IdToString.lookup_term(db, term_id)
    {:ok, {:entity, entity_id}} = URI.parse(uri)
    entity_id
  end
end
