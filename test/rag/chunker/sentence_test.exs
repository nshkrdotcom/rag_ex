defmodule Rag.Chunker.SentenceTest do
  use ExUnit.Case, async: true

  alias Rag.Chunker
  alias Rag.Chunker.{Chunk, Sentence}

  describe "chunk/3" do
    test "returns list of Chunk structs" do
      chunker = %Sentence{}
      [chunk | _] = Chunker.chunk(chunker, "First sentence. Second sentence.")

      assert %Chunk{} = chunk
      assert is_binary(chunk.content)
      assert is_integer(chunk.start_byte)
      assert is_integer(chunk.end_byte)
      assert is_integer(chunk.index)
      assert is_map(chunk.metadata)
    end

    test "respects max_chars limit" do
      chunker = %Sentence{max_chars: 50}
      text = String.duplicate("Sentence here. ", 20)

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> String.length(chunk.content) <= 50 end)
    end

    test "byte positions are accurate" do
      chunker = %Sentence{max_chars: 40}
      text = "Hello world. This is a test. Another sentence here."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "handles empty text" do
      chunker = %Sentence{}

      assert Chunker.chunk(chunker, "") == []
    end

    test "handles text shorter than max_chars" do
      chunker = %Sentence{max_chars: 100}
      text = "This is just one sentence."

      [chunk] = Chunker.chunk(chunker, text)

      assert chunk.content == text
      assert chunk.start_byte == 0
      assert chunk.end_byte == byte_size(text)
    end

    test "handles Unicode correctly" do
      chunker = %Sentence{max_chars: 30}
      text = "Hello 世界. Привет мир. مرحبا العالم."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "handles emoji and composite graphemes" do
      chunker = %Sentence{max_chars: 12}
      text = "Hello 👩‍🚀. Hi 🇺🇸. Done."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "sequential indexes starting at 0" do
      chunker = %Sentence{max_chars: 20}
      text = "First. Second. Third. Fourth."

      chunks = Chunker.chunk(chunker, text)
      indexes = Enum.map(chunks, & &1.index)

      assert indexes == Enum.to_list(0..(length(chunks) - 1))
    end

    test "metadata includes chunker type" do
      chunker = %Sentence{}
      [chunk] = Chunker.chunk(chunker, "Hello world.")

      assert chunk.metadata.chunker == :sentence
    end

    test "combines short sentences to meet min_chars" do
      chunker = %Sentence{min_chars: 20, max_chars: 100}
      text = "Hi. Ok. Yes. No. Maybe. Sure."

      chunks = Chunker.chunk(chunker, text)

      non_last_chunks = Enum.drop(chunks, -1)

      Enum.each(non_last_chunks, fn chunk ->
        assert String.length(chunk.content) >= 15
      end)
    end

    test "handles text with no sentence boundaries" do
      chunker = %Sentence{max_chars: 30}
      text = "Just a long piece of text without any sentence boundaries at all"

      chunks = Chunker.chunk(chunker, text)

      assert length(chunks) >= 1
    end
  end
end
