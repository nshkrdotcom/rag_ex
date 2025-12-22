defmodule Rag.ChunkerTest do
  use ExUnit.Case, async: true

  alias Rag.Chunker

  defmodule TestChunker do
    @behaviour Rag.Chunker
    defstruct prefix: "chunk"

    @impl true
    def default_opts, do: [prefix: "chunk"]

    @impl true
    def chunk(%__MODULE__{} = chunker, text, opts) do
      prefix = opts[:prefix] || chunker.prefix

      [
        Rag.Chunker.Chunk.new(%{
          content: "#{prefix}: #{text}",
          start_byte: 0,
          end_byte: byte_size(text),
          index: 0,
          metadata: %{chunker: :test}
        })
      ]
    end
  end

  describe "chunk/3" do
    test "dispatches to chunker implementation" do
      chunker = %TestChunker{}
      [chunk] = Chunker.chunk(chunker, "hello")

      assert chunk.content == "chunk: hello"
    end

    test "merges default opts with runtime opts" do
      chunker = %TestChunker{prefix: "default"}
      [chunk] = Chunker.chunk(chunker, "hello", prefix: "override")

      assert chunk.content == "override: hello"
    end
  end

  describe "chunk_ingestion/3" do
    test "adds chunks to ingestion map" do
      chunker = %TestChunker{}
      ingestion = %{source: "test.txt", document: "hello"}

      result = Chunker.chunk_ingestion(chunker, ingestion)

      assert Map.has_key?(result, :chunks)
      assert length(result.chunks) == 1
      assert result.source == "test.txt"
    end
  end
end
