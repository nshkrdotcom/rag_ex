defmodule Rag.Chunker.RecursiveTest do
  use ExUnit.Case, async: true

  alias Rag.Chunker
  alias Rag.Chunker.{Chunk, Recursive}

  describe "chunk/3" do
    test "returns list of Chunk structs" do
      chunker = %Recursive{}
      [chunk | _] = Chunker.chunk(chunker, "Paragraph one.\n\nParagraph two.")

      assert %Chunk{} = chunk
      assert is_binary(chunk.content)
      assert is_integer(chunk.start_byte)
      assert is_integer(chunk.end_byte)
      assert is_integer(chunk.index)
      assert is_map(chunk.metadata)
    end

    test "respects max_chars limit" do
      chunker = %Recursive{max_chars: 80}
      text = String.duplicate("Sentence here. ", 30)

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> String.length(chunk.content) <= 80 end)
    end

    test "byte positions are accurate" do
      chunker = %Recursive{max_chars: 60}
      text = "First paragraph.\n\nSecond paragraph with more content.\n\nThird paragraph."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "handles empty text" do
      chunker = %Recursive{}

      [chunk] = Chunker.chunk(chunker, "")

      assert chunk.content == ""
      assert chunk.start_byte == 0
      assert chunk.end_byte == 0
    end

    test "handles text shorter than max_chars" do
      chunker = %Recursive{max_chars: 200}
      text = "Short text with one sentence."

      [chunk] = Chunker.chunk(chunker, text)

      assert chunk.content == text
      assert chunk.start_byte == 0
      assert chunk.end_byte == byte_size(text)
    end

    test "handles Unicode correctly" do
      chunker = %Recursive{max_chars: 40}
      text = "Hello 世界.\n\nПривет мир.\n\nمرحبا العالم."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "handles emoji and composite graphemes" do
      chunker = %Recursive{max_chars: 20}
      text = "Hello 👩‍🚀.\n\nHi 🇺🇸.\n\nDone."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "sequential indexes starting at 0" do
      chunker = %Recursive{max_chars: 25}
      text = "First. Second. Third. Fourth."

      chunks = Chunker.chunk(chunker, text)
      indexes = Enum.map(chunks, & &1.index)

      assert indexes == Enum.to_list(0..(length(chunks) - 1))
    end

    test "metadata includes chunker type" do
      chunker = %Recursive{}
      [chunk] = Chunker.chunk(chunker, "Test")

      assert chunk.metadata.chunker == :recursive
    end

    test "tries paragraph first for long text" do
      chunker = %Recursive{max_chars: 100}
      text = "First paragraph.\n\nSecond paragraph with more content.\n\nThird paragraph."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.any?(chunks, fn chunk -> chunk.metadata.hierarchy == :paragraph end)
    end

    test "falls back to sentence when paragraphs are too long" do
      chunker = %Recursive{max_chars: 80}
      long_para = String.duplicate("Sentence here. ", 20)
      text = long_para

      chunks = Chunker.chunk(chunker, text)

      assert length(chunks) > 1
      assert Enum.any?(chunks, fn chunk -> chunk.metadata.hierarchy == :sentence end)
    end

    test "falls back to character when sentences are too long" do
      chunker = %Recursive{max_chars: 50}
      very_long = String.duplicate("word", 200)

      chunks = Chunker.chunk(chunker, very_long)

      assert length(chunks) >= 1
      assert Enum.any?(chunks, fn chunk -> chunk.metadata.hierarchy == :character end)
    end

    test "maintains hierarchy metadata" do
      chunker = %Recursive{max_chars: 50}
      text = "Para 1.\n\nPara 2 with sentence. Another sentence."

      chunks = Chunker.chunk(chunker, text)

      Enum.each(chunks, fn chunk ->
        assert Map.has_key?(chunk.metadata, :hierarchy)
        assert chunk.metadata.hierarchy in [:paragraph, :sentence, :character]
      end)
    end
  end
end
