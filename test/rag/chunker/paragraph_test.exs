defmodule Rag.Chunker.ParagraphTest do
  use ExUnit.Case, async: true

  alias Rag.Chunker
  alias Rag.Chunker.{Chunk, Paragraph}

  describe "chunk/3" do
    test "returns list of Chunk structs" do
      chunker = %Paragraph{}
      [chunk | _] = Chunker.chunk(chunker, "First paragraph.\n\nSecond paragraph.")

      assert %Chunk{} = chunk
      assert is_binary(chunk.content)
      assert is_integer(chunk.start_byte)
      assert is_integer(chunk.end_byte)
      assert is_integer(chunk.index)
      assert is_map(chunk.metadata)
    end

    test "respects max_chars limit" do
      chunker = %Paragraph{max_chars: 80}
      text = String.duplicate("Sentence here. ", 30) <> "\n\nShort paragraph."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> String.length(chunk.content) <= 80 end)
    end

    test "byte positions are accurate" do
      chunker = %Paragraph{max_chars: 100}
      text = "First paragraph here.\n\nSecond paragraph here.\n\nThird paragraph here."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "handles empty text" do
      chunker = %Paragraph{}

      assert Chunker.chunk(chunker, "") == []
    end

    test "handles text shorter than max_chars" do
      chunker = %Paragraph{max_chars: 200}
      text = "Single paragraph with no breaks"

      [chunk] = Chunker.chunk(chunker, text)

      assert chunk.content == text
      assert chunk.start_byte == 0
      assert chunk.end_byte == byte_size(text)
    end

    test "handles Unicode correctly" do
      chunker = %Paragraph{max_chars: 50}
      text = "Hello 世界.\n\nПривет мир.\n\nمرحبا العالم."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "handles emoji and composite graphemes" do
      chunker = %Paragraph{max_chars: 30}
      text = "Hello 👩‍🚀.\n\nHi 🇺🇸.\n\nDone."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "sequential indexes starting at 0" do
      chunker = %Paragraph{max_chars: 50}
      text = "Para 1.\n\nPara 2.\n\nPara 3."

      chunks = Chunker.chunk(chunker, text)
      indexes = Enum.map(chunks, & &1.index)

      assert indexes == Enum.to_list(0..(length(chunks) - 1))
    end

    test "metadata includes chunker type" do
      chunker = %Paragraph{}
      [chunk] = Chunker.chunk(chunker, "Paragraph text")

      assert chunk.metadata.chunker == :paragraph
    end

    test "splits on double newlines" do
      chunker = %Paragraph{}
      text = "First paragraph here.\n\nSecond paragraph here.\n\nThird paragraph here."

      chunks = Chunker.chunk(chunker, text)

      assert length(chunks) == 3

      Enum.each(chunks, fn chunk ->
        refute String.contains?(chunk.content, "\n\n")
      end)
    end

    test "combines short paragraphs to meet min_chars" do
      chunker = %Paragraph{min_chars: 20}
      text = "Short.\n\nOk.\n\nYes.\n\nMaybe this is longer."

      chunks = Chunker.chunk(chunker, text)

      assert length(chunks) < 4
    end

    test "splits long paragraphs using sentence strategy" do
      chunker = %Paragraph{max_chars: 80}
      long_para = String.duplicate("Sentence here. ", 20)
      text = long_para <> "\n\nShort paragraph."

      chunks = Chunker.chunk(chunker, text)

      assert length(chunks) >= 2
      assert Enum.all?(chunks, fn chunk -> String.length(chunk.content) <= 80 end)
    end

    test "handles multiple consecutive newlines" do
      chunker = %Paragraph{}
      text = "First.\n\n\n\nSecond.\n\n\nThird."

      chunks = Chunker.chunk(chunker, text)

      assert length(chunks) >= 2
      assert Enum.all?(chunks, fn chunk -> String.length(chunk.content) > 0 end)
    end

    test "handles Windows-style line endings" do
      chunker = %Paragraph{}
      text = "First paragraph.\r\n\r\nSecond paragraph."

      chunks = Chunker.chunk(chunker, text)

      assert length(chunks) >= 1
    end
  end
end
