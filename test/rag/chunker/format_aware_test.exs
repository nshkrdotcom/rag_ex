defmodule Rag.Chunker.FormatAwareTest do
  use ExUnit.Case, async: true

  alias Rag.Chunker
  alias Rag.Chunker.{Chunk, FormatAware}

  @moduletag :format_aware

  setup do
    unless Code.ensure_loaded?(TextChunker) do
      raise ExUnit.AssertionError, "TextChunker required for these tests"
    end

    :ok
  end

  describe "chunk/3" do
    test "returns list of Chunk structs" do
      chunker = %FormatAware{format: :plaintext, chunk_size: 30, chunk_overlap: 0}
      [chunk | _] = Chunker.chunk(chunker, "Hello world. This is a test.")

      assert %Chunk{} = chunk
      assert is_binary(chunk.content)
      assert is_integer(chunk.start_byte)
      assert is_integer(chunk.end_byte)
      assert is_integer(chunk.index)
      assert is_map(chunk.metadata)
    end

    test "respects chunk_size limit" do
      chunker = %FormatAware{format: :plaintext, chunk_size: 20, chunk_overlap: 0}
      text = String.duplicate("word ", 50)

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> String.length(chunk.content) <= 20 end)
    end

    test "byte positions are accurate" do
      chunker = %FormatAware{format: :plaintext, chunk_size: 25, chunk_overlap: 0}
      text = "Hello world. This is a test. Another sentence here."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "handles empty text" do
      chunker = %FormatAware{format: :plaintext, chunk_size: 50, chunk_overlap: 0}

      [chunk] = Chunker.chunk(chunker, "")

      assert chunk.content == ""
      assert chunk.start_byte == 0
      assert chunk.end_byte == 0
    end

    test "handles text shorter than chunk_size" do
      chunker = %FormatAware{format: :plaintext, chunk_size: 200, chunk_overlap: 0}
      text = "Short text"

      [chunk] = Chunker.chunk(chunker, text)

      assert chunk.content == text
      assert chunk.start_byte == 0
      assert chunk.end_byte == byte_size(text)
    end

    test "handles Unicode correctly" do
      chunker = %FormatAware{format: :plaintext, chunk_size: 40, chunk_overlap: 0}
      text = "Hello 世界. Привет мир. مرحبا العالم."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "handles emoji and composite graphemes" do
      chunker = %FormatAware{format: :plaintext, chunk_size: 20, chunk_overlap: 0}
      text = "Hello 👩‍🚀. Hi 🇺🇸. Done."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "sequential indexes starting at 0" do
      chunker = %FormatAware{format: :plaintext, chunk_size: 10, chunk_overlap: 0}
      text = "First. Second. Third. Fourth."

      chunks = Chunker.chunk(chunker, text)
      indexes = Enum.map(chunks, & &1.index)

      assert indexes == Enum.to_list(0..(length(chunks) - 1))
    end

    test "metadata includes chunker type" do
      chunker = %FormatAware{format: :plaintext, chunk_size: 50, chunk_overlap: 0}
      [chunk] = Chunker.chunk(chunker, "Test")

      assert chunk.metadata.chunker == :format_aware
    end

    test "metadata includes format" do
      chunker = %FormatAware{format: :markdown, chunk_size: 50, chunk_overlap: 0}
      [chunk] = Chunker.chunk(chunker, "# Title\n\nContent here.")

      assert chunk.metadata.format == :markdown
    end
  end
end
