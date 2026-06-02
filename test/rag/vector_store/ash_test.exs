defmodule Rag.VectorStore.AshTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Rag.VectorStore.AshTest.Chunk do
  @moduledoc false
  use Ash.Resource,
    domain: Rag.VectorStore.AshTest.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :content, :string, public?: true
    attribute :embedding, {:array, :float}, public?: true
    attribute :source, :string, public?: true
    attribute :metadata, :map, public?: true, default: %{}
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end

defmodule Rag.VectorStore.AshTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Rag.VectorStore.Store
  alias Rag.VectorStore.Ash, as: AshStore
  alias Rag.VectorStore.AshTest.Chunk

  setup :verify_on_exit!

  defp store(opts \\ []) do
    Keyword.merge(
      [
        resource: Chunk,
        embedding_attribute: :embedding,
        content_attribute: :content,
        source_attribute: :source,
        metadata_attribute: :metadata,
        domain: Rag.VectorStore.AshTest.Domain
      ],
      opts
    )
    |> AshStore.new()
  end

  describe "new/1" do
    test "builds the struct with defaults" do
      built = AshStore.new(resource: Chunk, embedding_attribute: :embedding)

      assert built.resource == Chunk
      assert built.embedding_attribute == :embedding
      assert built.content_attribute == :content
      assert built.source_attribute == nil
      assert built.metadata_attribute == nil
      assert built.id_attribute == nil
    end

    test "raises when :resource is missing" do
      assert_raise KeyError, fn -> AshStore.new(embedding_attribute: :embedding) end
    end

    test "raises when :embedding_attribute is missing" do
      assert_raise KeyError, fn -> AshStore.new(resource: Chunk) end
    end
  end

  describe "insert/3" do
    test "inserts documents via Ash.bulk_create" do
      documents = [
        %{content: "First", embedding: [0.1, 0.2], source: "a.md", metadata: %{}},
        %{content: "Second", embedding: [0.3, 0.4], source: "b.md", metadata: %{tag: "x"}}
      ]

      Ash
      |> expect(:bulk_create, fn resource, inputs, action, _opts ->
        assert resource == Chunk
        assert action == :create
        assert length(inputs) == 2

        [first, second] = inputs
        assert first.content == "First"
        assert first.embedding == [0.1, 0.2]
        assert first.source == "a.md"
        assert second.metadata == %{tag: "x"}

        %Ash.BulkResult{status: :success, records: [%Chunk{}, %Chunk{}]}
      end)

      {:ok, count} = Store.insert(store(), documents)
      assert count == 2
    end

    test "handles empty document list" do
      {:ok, count} = Store.insert(store(), [])
      assert count == 0
    end

    test "returns error on failure" do
      documents = [%{content: "Test", embedding: [0.1], source: nil, metadata: %{}}]

      Ash
      |> expect(:bulk_create, fn _, _, _, _ -> raise "boom" end)

      {:error, reason} = Store.insert(store(), documents)
      assert reason =~ "boom"
    end

    test "returns error when BulkResult carries errors" do
      documents = [%{content: "Test", embedding: [0.1], source: nil, metadata: %{}}]

      Ash
      |> expect(:bulk_create, fn _, _, _, _ ->
        %Ash.BulkResult{status: :error, errors: [:bad_input]}
      end)

      {:error, [:bad_input]} = Store.insert(store(), documents)
    end
  end

  describe "search/3" do
    test "returns mapped results with scores" do
      records = [
        struct(Chunk, %{
          id: "id-1",
          content: "First",
          source: "a.md",
          metadata: %{},
          calculations: %{_rag_distance: 0.0}
        }),
        struct(Chunk, %{
          id: "id-2",
          content: "Second",
          source: "b.md",
          metadata: %{tag: "x"},
          calculations: %{_rag_distance: 1.0}
        })
      ]

      Ash
      |> expect(:read, fn %Ash.Query{} = query, _opts ->
        assert query.resource == Chunk
        assert query.limit == 5
        {:ok, records}
      end)

      {:ok, results} = Store.search(store(), [0.1, 0.2], limit: 5)

      assert [
               %{id: "id-1", content: "First", source: "a.md", metadata: %{}, score: 1.0},
               %{id: "id-2", content: "Second", source: "b.md", metadata: %{tag: "x"}, score: 0.5}
             ] = results
    end

    test "uses default limit when none provided" do
      Ash
      |> expect(:read, fn %Ash.Query{} = query, _opts ->
        assert query.limit == 10
        {:ok, []}
      end)

      {:ok, []} = Store.search(store(), [0.1], [])
    end

    test "returns empty results when no records match" do
      Ash
      |> expect(:read, fn _, _ -> {:ok, []} end)

      {:ok, []} = Store.search(store(), [0.1], [])
    end

    test "returns error when Ash.read fails" do
      Ash
      |> expect(:read, fn _, _ -> {:error, :boom} end)

      {:error, :boom} = Store.search(store(), [0.1], [])
    end

    test "rescues raised exceptions" do
      Ash
      |> expect(:read, fn _, _ -> raise "kaboom" end)

      {:error, reason} = Store.search(store(), [0.1], [])
      assert reason =~ "kaboom"
    end
  end

  describe "delete/3" do
    test "deletes by IDs via Ash.bulk_destroy" do
      Ash
      |> expect(:bulk_destroy, fn %Ash.Query{} = query, :destroy, %{}, _opts ->
        assert query.resource == Chunk
        %Ash.BulkResult{status: :success, records: [%Chunk{}, %Chunk{}, %Chunk{}]}
      end)

      {:ok, count} = Store.delete(store(), ["a", "b", "c"])
      assert count == 3
    end

    test "handles empty ID list" do
      {:ok, count} = Store.delete(store(), [])
      assert count == 0
    end

    test "rescues raised exceptions" do
      Ash
      |> expect(:bulk_destroy, fn _, _, _, _ -> raise "no" end)

      {:error, reason} = Store.delete(store(), ["a"])
      assert reason =~ "no"
    end
  end

  describe "get/3" do
    test "retrieves documents by IDs" do
      records = [
        struct(Chunk, %{
          id: "id-1",
          content: "First",
          embedding: [0.1],
          source: "a.md",
          metadata: %{}
        }),
        struct(Chunk, %{
          id: "id-2",
          content: "Second",
          embedding: [0.2],
          source: "b.md",
          metadata: %{tag: "x"}
        })
      ]

      Ash
      |> expect(:read, fn %Ash.Query{} = query, _opts ->
        assert query.resource == Chunk
        {:ok, records}
      end)

      {:ok, [first, second]} = Store.get(store(), ["id-1", "id-2"])
      assert first.id == "id-1"
      assert first.content == "First"
      assert first.embedding == [0.1]
      assert second.metadata == %{tag: "x"}
    end

    test "returns empty list for empty IDs" do
      {:ok, []} = Store.get(store(), [])
    end

    test "rescues raised exceptions" do
      Ash
      |> expect(:read, fn _, _ -> raise "nope" end)

      {:error, reason} = Store.get(store(), ["id-1"])
      assert reason =~ "nope"
    end
  end

  describe "round-trip mapping" do
    test "preserves all configured attributes through insert + get" do
      Ash
      |> expect(:bulk_create, fn _resource, [input], :create, _opts ->
        record =
          struct(Chunk, Map.put(input, :id, "round-trip-id"))

        %Ash.BulkResult{status: :success, records: [record]}
      end)

      doc = %{
        content: "Round trip",
        embedding: [0.5, 0.5],
        source: "src.md",
        metadata: %{kind: "test"}
      }

      {:ok, 1} = Store.insert(store(), [doc])

      Ash
      |> expect(:read, fn _, _ ->
        {:ok,
         [
           struct(Chunk, %{
             id: "round-trip-id",
             content: doc.content,
             embedding: doc.embedding,
             source: doc.source,
             metadata: doc.metadata
           })
         ]}
      end)

      {:ok, [returned]} = Store.get(store(), ["round-trip-id"])
      assert returned.content == doc.content
      assert returned.embedding == doc.embedding
      assert returned.source == doc.source
      assert returned.metadata == doc.metadata
    end
  end
end
