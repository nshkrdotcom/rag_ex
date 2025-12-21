defmodule Rag.Embedding.ServiceTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Rag.Embedding.Service
  alias Rag.VectorStore

  setup :set_mimic_global
  setup :verify_on_exit!

  describe "start_link/1" do
    test "starts the service with default options" do
      {:ok, pid} = Service.start_link(name: :test_service_1)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts with custom batch size" do
      {:ok, pid} = Service.start_link(name: :test_service_2, batch_size: 50)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "accepts provider as atom and resolves to module" do
      mock_embedding = List.duplicate(0.5, 768)

      expect(Rag.Ai.Gemini, :generate_embeddings, fn _provider, _texts, _opts ->
        {:ok, [mock_embedding]}
      end)

      # Pass :gemini atom instead of Rag.Ai.Gemini module
      {:ok, pid} = Service.start_link(name: :test_service_atom, provider: :gemini)
      assert Process.alive?(pid)

      # Should work - provider atom resolved to module
      {:ok, embedding} = Service.embed_text(pid, "Test")
      assert embedding == mock_embedding
      GenServer.stop(pid)
    end
  end

  describe "embed_text/2" do
    test "generates embedding for a single text" do
      mock_embedding = List.duplicate(0.5, 768)

      expect(Rag.Ai.Gemini, :generate_embeddings, fn _provider, texts, _opts ->
        assert texts == ["Hello world"]
        {:ok, [mock_embedding]}
      end)

      {:ok, pid} = Service.start_link(name: :test_embed_1)
      {:ok, embedding} = Service.embed_text(pid, "Hello world")

      assert embedding == mock_embedding
      GenServer.stop(pid)
    end

    test "returns error when provider fails" do
      expect(Rag.Ai.Gemini, :generate_embeddings, fn _provider, _texts, _opts ->
        {:error, :api_error}
      end)

      {:ok, pid} = Service.start_link(name: :test_embed_2)
      result = Service.embed_text(pid, "Test")

      assert {:error, :api_error} = result
      GenServer.stop(pid)
    end
  end

  describe "embed_texts/2" do
    test "generates embeddings for multiple texts" do
      texts = ["First", "Second", "Third"]
      mock_embeddings = Enum.map(1..3, fn _ -> List.duplicate(0.5, 768) end)

      expect(Rag.Ai.Gemini, :generate_embeddings, fn _provider, ^texts, _opts ->
        {:ok, mock_embeddings}
      end)

      {:ok, pid} = Service.start_link(name: :test_embed_batch_1)
      {:ok, embeddings} = Service.embed_texts(pid, texts)

      assert length(embeddings) == 3
      GenServer.stop(pid)
    end

    test "batches large requests" do
      texts = Enum.map(1..25, fn i -> "Text #{i}" end)
      batch_size = 10

      # Expect 3 calls: 10 + 10 + 5
      expect(Rag.Ai.Gemini, :generate_embeddings, 3, fn _provider, batch, _opts ->
        {:ok, Enum.map(batch, fn _ -> List.duplicate(0.5, 768) end)}
      end)

      {:ok, pid} = Service.start_link(name: :test_embed_batch_2, batch_size: batch_size)
      {:ok, embeddings} = Service.embed_texts(pid, texts)

      assert length(embeddings) == 25
      GenServer.stop(pid)
    end
  end

  describe "embed_chunks/2" do
    test "adds embeddings to chunks" do
      chunks = [
        VectorStore.build_chunk(%{content: "First"}),
        VectorStore.build_chunk(%{content: "Second"})
      ]

      mock_embeddings = [
        List.duplicate(0.1, 768),
        List.duplicate(0.2, 768)
      ]

      expect(Rag.Ai.Gemini, :generate_embeddings, fn _provider, texts, _opts ->
        assert texts == ["First", "Second"]
        {:ok, mock_embeddings}
      end)

      {:ok, pid} = Service.start_link(name: :test_embed_chunks_1)
      {:ok, result_chunks} = Service.embed_chunks(pid, chunks)

      assert length(result_chunks) == 2
      assert Enum.at(result_chunks, 0).embedding == List.duplicate(0.1, 768)
      assert Enum.at(result_chunks, 1).embedding == List.duplicate(0.2, 768)
      GenServer.stop(pid)
    end

    test "handles empty chunk list" do
      {:ok, pid} = Service.start_link(name: :test_embed_chunks_2)
      {:ok, result} = Service.embed_chunks(pid, [])

      assert result == []
      GenServer.stop(pid)
    end

    test "returns error when embedding fails" do
      chunks = [VectorStore.build_chunk(%{content: "Test"})]

      expect(Rag.Ai.Gemini, :generate_embeddings, fn _provider, _texts, _opts ->
        {:error, :rate_limited}
      end)

      {:ok, pid} = Service.start_link(name: :test_embed_chunks_3)
      result = Service.embed_chunks(pid, chunks)

      assert {:error, :rate_limited} = result
      GenServer.stop(pid)
    end
  end

  describe "embed_and_prepare/2" do
    test "embeds chunks and prepares for database insert" do
      chunks = [
        VectorStore.build_chunk(%{content: "Test", source: "file.ex"})
      ]

      mock_embedding = List.duplicate(0.5, 768)

      expect(Rag.Ai.Gemini, :generate_embeddings, fn _provider, _texts, _opts ->
        {:ok, [mock_embedding]}
      end)

      {:ok, pid} = Service.start_link(name: :test_prepare_1)
      {:ok, prepared} = Service.embed_and_prepare(pid, chunks)

      assert length(prepared) == 1
      [first] = prepared
      assert is_map(first)
      assert first.content == "Test"
      assert first.source == "file.ex"
      assert first.embedding == mock_embedding
      GenServer.stop(pid)
    end
  end

  describe "get_stats/1" do
    test "returns service statistics" do
      {:ok, pid} = Service.start_link(name: :test_stats_1)
      stats = Service.get_stats(pid)

      assert is_map(stats)
      assert Map.has_key?(stats, :texts_embedded)
      assert Map.has_key?(stats, :batches_processed)
      assert Map.has_key?(stats, :errors)
      GenServer.stop(pid)
    end

    test "tracks embedding operations" do
      mock_embedding = List.duplicate(0.5, 768)

      expect(Rag.Ai.Gemini, :generate_embeddings, 2, fn _provider, texts, _opts ->
        {:ok, Enum.map(texts, fn _ -> mock_embedding end)}
      end)

      {:ok, pid} = Service.start_link(name: :test_stats_2)

      # Perform some operations
      Service.embed_text(pid, "First")
      Service.embed_texts(pid, ["A", "B", "C"])

      stats = Service.get_stats(pid)
      assert stats.texts_embedded == 4
      assert stats.batches_processed == 2
      GenServer.stop(pid)
    end
  end
end
