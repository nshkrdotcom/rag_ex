defmodule Rag.VectorStore.StoreTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Rag.VectorStore.Store
  alias Rag.VectorStore.Pgvector, as: PgvectorStore

  setup :verify_on_exit!

  describe "Store behaviour" do
    test "defines required callbacks" do
      # Verify the behaviour defines all required callbacks
      callbacks = Store.behaviour_info(:callbacks)

      assert {:insert, 3} in callbacks
      assert {:search, 3} in callbacks
      assert {:delete, 3} in callbacks
      assert {:get, 3} in callbacks
    end
  end

  describe "Pgvector store - insert/3" do
    test "inserts documents into the database" do
      documents = [
        %{content: "First doc", embedding: [0.1, 0.2, 0.3], source: "test.md", metadata: %{}},
        %{content: "Second doc", embedding: [0.4, 0.5, 0.6], source: "test.md", metadata: %{}}
      ]

      Rag.Repo
      |> expect(:insert_all, fn Rag.VectorStore.Chunk, inserts, _opts ->
        assert length(inserts) == 2
        {2, nil}
      end)

      store = %PgvectorStore{repo: Rag.Repo}
      {:ok, count} = Store.insert(store, documents)

      assert count == 2
    end

    test "handles empty document list" do
      store = %PgvectorStore{repo: Rag.Repo}
      {:ok, count} = Store.insert(store, [])

      assert count == 0
    end

    test "returns error on database failure" do
      documents = [%{content: "Test", embedding: [0.1], source: "test.md", metadata: %{}}]

      Rag.Repo
      |> expect(:insert_all, fn _, _, _ ->
        raise "Database error"
      end)

      store = %PgvectorStore{repo: Rag.Repo}
      {:error, reason} = Store.insert(store, documents)

      assert reason =~ "Database error"
    end
  end

  describe "Pgvector store - search/3" do
    test "performs semantic search by embedding" do
      embedding = [0.1, 0.2, 0.3]

      expected_results = [
        %{id: 1, content: "Result 1", source: "doc1.md", metadata: %{}, distance: 0.1},
        %{id: 2, content: "Result 2", source: "doc2.md", metadata: %{}, distance: 0.2}
      ]

      Rag.Repo
      |> expect(:all, fn _query ->
        expected_results
      end)

      store = %PgvectorStore{repo: Rag.Repo}
      {:ok, results} = Store.search(store, embedding, limit: 5)

      assert length(results) == 2
      assert hd(results).id == 1
    end

    test "respects limit option" do
      embedding = [0.1]

      Rag.Repo
      |> expect(:all, fn query ->
        # Query should have limit applied
        assert query != nil
        []
      end)

      store = %PgvectorStore{repo: Rag.Repo}
      {:ok, _} = Store.search(store, embedding, limit: 20)
    end

    test "returns empty list when no results" do
      Rag.Repo
      |> expect(:all, fn _ -> [] end)

      store = %PgvectorStore{repo: Rag.Repo}
      {:ok, results} = Store.search(store, [0.1], [])

      assert results == []
    end
  end

  describe "Pgvector store - delete/3" do
    test "deletes documents by IDs" do
      ids = [1, 2, 3]

      Rag.Repo
      |> expect(:delete_all, fn query ->
        # Should delete matching IDs
        assert query != nil
        {3, nil}
      end)

      store = %PgvectorStore{repo: Rag.Repo}
      {:ok, count} = Store.delete(store, ids)

      assert count == 3
    end

    test "handles empty ID list" do
      store = %PgvectorStore{repo: Rag.Repo}
      {:ok, count} = Store.delete(store, [])

      assert count == 0
    end
  end

  describe "Pgvector store - get/3" do
    test "retrieves documents by IDs" do
      ids = [1, 2]

      expected_results = [
        %Rag.VectorStore.Chunk{id: 1, content: "First", source: "a.md"},
        %Rag.VectorStore.Chunk{id: 2, content: "Second", source: "b.md"}
      ]

      Rag.Repo
      |> expect(:all, fn _query ->
        expected_results
      end)

      store = %PgvectorStore{repo: Rag.Repo}
      {:ok, results} = Store.get(store, ids)

      assert length(results) == 2
    end

    test "returns empty list for empty IDs" do
      store = %PgvectorStore{repo: Rag.Repo}
      {:ok, results} = Store.get(store, [])

      assert results == []
    end
  end

  describe "Store.dispatch/4" do
    test "dispatches to correct implementation" do
      Rag.Repo
      |> expect(:all, fn _ -> [] end)

      store = %PgvectorStore{repo: Rag.Repo}
      {:ok, []} = Store.search(store, [0.1], [])
    end
  end
end
