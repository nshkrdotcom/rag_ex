defmodule Rag.Chunker.CharacterTest do
  use ExUnit.Case, async: true

  alias Rag.Chunker
  alias Rag.Chunker.{Character, Chunk}

  describe "chunk/3" do
    test "returns list of Chunk structs" do
      chunker = %Character{}
      [chunk | _] = Chunker.chunk(chunker, "Hello world")

      assert %Chunk{} = chunk
      assert is_binary(chunk.content)
      assert is_integer(chunk.start_byte)
      assert is_integer(chunk.end_byte)
      assert is_integer(chunk.index)
      assert is_map(chunk.metadata)
    end

    test "respects max_chars limit" do
      chunker = %Character{max_chars: 50}
      text = String.duplicate("word ", 100)

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> String.length(chunk.content) <= 50 end)
    end

    test "byte positions are accurate" do
      chunker = %Character{max_chars: 30, overlap: 0}
      text = "Hello world. This is a test. Another sentence here."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "handles empty text" do
      chunker = %Character{}

      [chunk] = Chunker.chunk(chunker, "")

      assert chunk.content == ""
      assert chunk.start_byte == 0
      assert chunk.end_byte == 0
      assert chunk.index == 0
    end

    test "handles text shorter than max_chars" do
      chunker = %Character{max_chars: 100}
      text = "Short text"

      [chunk] = Chunker.chunk(chunker, text)

      assert chunk.content == text
      assert chunk.start_byte == 0
      assert chunk.end_byte == byte_size(text)
    end

    test "handles Unicode correctly" do
      chunker = %Character{max_chars: 20}
      text = "Hello 世界. Привет мир."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "handles emoji and composite graphemes" do
      chunker = %Character{max_chars: 10, overlap: 0}
      text = "Hello 👩‍🚀 world 🇺🇸 test"

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "sequential indexes starting at 0" do
      chunker = %Character{max_chars: 15}
      text = String.duplicate("Hello world. ", 5)

      chunks = Chunker.chunk(chunker, text)
      indexes = Enum.map(chunks, & &1.index)

      assert indexes == Enum.to_list(0..(length(chunks) - 1))
    end

    test "metadata includes chunker type" do
      chunker = %Character{}

      [chunk] = Chunker.chunk(chunker, "Test")

      assert chunk.metadata.chunker == :character
    end

    test "respects overlap option" do
      chunker = %Character{max_chars: 40, overlap: 5}
      text = "First sentence. Second sentence. Third sentence."

      chunks = Chunker.chunk(chunker, text)

      assert length(chunks) > 1

      [first, second | _] = chunks
      overlap_text = String.slice(first.content, -5, 5)

      assert String.starts_with?(second.content, overlap_text)
    end
  end
end
