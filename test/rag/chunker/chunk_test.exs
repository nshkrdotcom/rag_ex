defmodule Rag.Chunker.ChunkTest do
  use ExUnit.Case, async: true

  alias Rag.Chunker.Chunk

  describe "new/1" do
    test "creates chunk with required fields" do
      chunk =
        Chunk.new(%{
          content: "hello",
          start_byte: 0,
          end_byte: 5,
          index: 0
        })

      assert chunk.content == "hello"
      assert chunk.start_byte == 0
      assert chunk.end_byte == 5
      assert chunk.index == 0
      assert chunk.metadata == %{}
    end

    test "accepts metadata" do
      chunk =
        Chunk.new(%{
          content: "hello",
          start_byte: 0,
          end_byte: 5,
          index: 0,
          metadata: %{chunker: :test}
        })

      assert chunk.metadata == %{chunker: :test}
    end

    test "raises on missing required fields" do
      assert_raise KeyError, fn ->
        Chunk.new(%{content: "hello"})
      end
    end
  end

  describe "extract_from_source/2" do
    test "extracts content using byte positions" do
      source = "Hello world, this is a test."
      chunk = Chunk.new(%{content: "world", start_byte: 6, end_byte: 11, index: 0})

      assert Chunk.extract_from_source(chunk, source) == "world"
    end

    test "handles Unicode" do
      source = "Hello 世界 test"
      # "世界" is 6 bytes (2 chars × 3 bytes each)
      chunk = Chunk.new(%{content: "世界", start_byte: 6, end_byte: 12, index: 0})

      assert Chunk.extract_from_source(chunk, source) == "世界"
    end
  end

  describe "valid?/2" do
    test "returns true when positions match content" do
      source = "Hello world"
      chunk = Chunk.new(%{content: "Hello", start_byte: 0, end_byte: 5, index: 0})

      assert Chunk.valid?(chunk, source)
    end

    test "returns false when positions don't match" do
      source = "Hello world"
      chunk = Chunk.new(%{content: "Hello", start_byte: 0, end_byte: 6, index: 0})

      refute Chunk.valid?(chunk, source)
    end
  end
end
