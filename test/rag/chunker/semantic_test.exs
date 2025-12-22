defmodule Rag.Chunker.SemanticTest do
  use ExUnit.Case, async: true

  alias Rag.Chunker
  alias Rag.Chunker.{Chunk, Semantic}

  describe "chunk/3" do
    test "returns list of Chunk structs" do
      chunker = %Semantic{embedding_fn: fn _ -> [1.0, 0.0, 0.0] end}
      [chunk | _] = Chunker.chunk(chunker, "First sentence. Second sentence.")

      assert %Chunk{} = chunk
      assert is_binary(chunk.content)
      assert is_integer(chunk.start_byte)
      assert is_integer(chunk.end_byte)
      assert is_integer(chunk.index)
      assert is_map(chunk.metadata)
    end

    test "respects max_chars limit" do
      chunker = %Semantic{embedding_fn: fn _ -> [1.0, 0.0, 0.0] end, max_chars: 80}
      text = String.duplicate("Similar topic sentence. ", 50)

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> String.length(chunk.content) <= 80 end)
    end

    test "byte positions are accurate" do
      chunker = %Semantic{embedding_fn: fn _ -> [1.0, 0.0, 0.0] end, max_chars: 80}
      text = "Hello world. This is a test. Another sentence here."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "handles empty text" do
      chunker = %Semantic{embedding_fn: fn _ -> [1.0, 0.0, 0.0] end}

      assert Chunker.chunk(chunker, "") == []
    end

    test "handles text shorter than max_chars" do
      chunker = %Semantic{embedding_fn: fn _ -> [1.0, 0.0, 0.0] end, max_chars: 200}
      text = "Short sentence."

      [chunk] = Chunker.chunk(chunker, text)

      assert chunk.content == text
      assert chunk.start_byte == 0
      assert chunk.end_byte == byte_size(text)
    end

    test "handles Unicode correctly" do
      chunker = %Semantic{embedding_fn: fn _ -> [1.0, 0.0, 0.0] end, max_chars: 60}
      text = "Hello 世界. Привет мир. مرحبا العالم."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "handles emoji and composite graphemes" do
      chunker = %Semantic{embedding_fn: fn _ -> [1.0, 0.0, 0.0] end, max_chars: 30}
      text = "Hello 👩‍🚀. Hi 🇺🇸. Done."

      chunks = Chunker.chunk(chunker, text)

      assert Enum.all?(chunks, fn chunk -> Chunk.valid?(chunk, text) end)
    end

    test "sequential indexes starting at 0" do
      chunker = %Semantic{embedding_fn: fn _ -> [1.0, 0.0, 0.0] end, max_chars: 20}
      text = "First. Second. Third. Fourth."

      chunks = Chunker.chunk(chunker, text)
      indexes = Enum.map(chunks, & &1.index)

      assert indexes == Enum.to_list(0..(length(chunks) - 1))
    end

    test "metadata includes chunker type" do
      chunker = %Semantic{embedding_fn: fn _ -> [1.0, 0.0, 0.0] end}
      [chunk] = Chunker.chunk(chunker, "Test sentence.")

      assert chunk.metadata.chunker == :semantic
    end

    test "groups sentences by embedding similarity" do
      text =
        "First sentence about dogs. Second sentence about dogs. " <>
          "Now about cats. More about cats."

      embedding_fn = fn sentence ->
        cond do
          String.contains?(sentence, "dog") -> [1.0, 0.0, 0.0]
          String.contains?(sentence, "cat") -> [0.0, 1.0, 0.0]
          true -> [0.0, 0.0, 1.0]
        end
      end

      chunker = %Semantic{embedding_fn: embedding_fn, threshold: 0.8}
      chunks = Chunker.chunk(chunker, text)

      assert length(chunks) >= 1
      assert Enum.all?(chunks, fn chunk -> chunk.metadata.chunker == :semantic end)
    end

    test "respects similarity threshold" do
      text = "Sentence one. Sentence two. Sentence three."

      counter = :counters.new(1, [:atomics])

      embedding_fn = fn _sentence ->
        idx = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        List.duplicate(idx / 10, 3)
      end

      low_threshold_chunks =
        Chunker.chunk(%Semantic{embedding_fn: embedding_fn, threshold: 0.99}, text)

      :counters.put(counter, 1, 0)

      high_threshold_chunks =
        Chunker.chunk(%Semantic{embedding_fn: embedding_fn, threshold: 0.01}, text)

      assert is_list(low_threshold_chunks)
      assert is_list(high_threshold_chunks)
    end

    test "requires embedding_fn parameter" do
      text = "Some text here."

      assert_raise ArgumentError, ~r/embedding_fn/, fn ->
        Chunker.chunk(%Semantic{embedding_fn: nil}, text)
      end
    end

    test "uses default threshold when not provided" do
      text = "First. Second."
      embedding_fn = fn _sentence -> [1.0, 0.0, 0.0] end

      chunks = Chunker.chunk(%Semantic{embedding_fn: embedding_fn}, text)

      assert is_list(chunks)
    end

    test "handles single sentence" do
      text = "Just one sentence."
      embedding_fn = fn _sentence -> [1.0, 0.0, 0.0] end

      chunks = Chunker.chunk(%Semantic{embedding_fn: embedding_fn}, text)

      assert [chunk] = chunks
      assert String.contains?(chunk.content, "Just one sentence")
    end
  end
end
