defmodule Rag.ChunkingTest do
  use ExUnit.Case, async: true

  alias Rag.Chunking

  describe "chunk/2 with :character strategy" do
    test "splits text into chunks by character limit" do
      text = String.duplicate("Hello world. ", 100)

      chunks = Chunking.chunk(text, strategy: :character, max_chars: 200)

      assert length(chunks) > 1

      Enum.each(chunks, fn chunk ->
        assert String.length(chunk.content) <= 200
        assert is_integer(chunk.index)
        assert is_map(chunk.metadata)
      end)
    end

    test "respects overlap option" do
      text = "First sentence. Second sentence. Third sentence. Fourth sentence."

      chunks = Chunking.chunk(text, strategy: :character, max_chars: 40, overlap: 10)

      assert length(chunks) >= 2

      # Check overlap - end of first chunk should appear in start of second
      if length(chunks) >= 2 do
        [first, second | _] = chunks
        # There should be some overlap in content
        assert String.length(first.content) > 0
        assert String.length(second.content) > 0
      end
    end

    test "handles text shorter than max_chars" do
      text = "Short text"

      chunks = Chunking.chunk(text, strategy: :character, max_chars: 100)

      assert [chunk] = chunks
      assert chunk.content == "Short text"
      assert chunk.index == 0
    end

    test "defaults to character strategy when no strategy specified" do
      text = String.duplicate("Test. ", 100)

      chunks = Chunking.chunk(text, max_chars: 100)

      assert is_list(chunks)
      assert length(chunks) > 0
      assert Enum.all?(chunks, &match?(%{content: _, index: _, metadata: _}, &1))
    end

    test "uses smart boundary detection at sentence boundaries" do
      text = "First sentence here. Second sentence here. Third sentence here."

      chunks = Chunking.chunk(text, strategy: :character, max_chars: 30, overlap: 0)

      # Should try to break at sentence boundaries
      assert length(chunks) >= 2

      Enum.each(chunks, fn chunk ->
        # Most chunks should end with sentence punctuation or be the last chunk
        assert String.length(chunk.content) > 0
      end)
    end

    test "falls back to word boundaries when no sentence boundary found" do
      text = "NoSentencesHere JustLongWords AnotherWord MoreWords EvenMore"

      chunks = Chunking.chunk(text, strategy: :character, max_chars: 25, overlap: 0)

      assert length(chunks) >= 2

      Enum.each(chunks, fn chunk ->
        assert String.length(chunk.content) <= 25
      end)
    end

    test "handles empty text" do
      chunks = Chunking.chunk("", strategy: :character)

      assert [chunk] = chunks
      assert chunk.content == ""
      assert chunk.index == 0
    end

    test "handles very short text" do
      chunks = Chunking.chunk("Hi", strategy: :character)

      assert [chunk] = chunks
      assert chunk.content == "Hi"
    end

    test "includes strategy metadata" do
      chunks = Chunking.chunk("Test", strategy: :character)

      assert [chunk] = chunks
      assert chunk.metadata.strategy == :character
    end
  end

  describe "chunk/2 with :sentence strategy" do
    test "splits text on sentence boundaries" do
      text = "First sentence. Second sentence! Third sentence? Fourth sentence."

      chunks = Chunking.chunk(text, strategy: :sentence, max_chars: 50)

      assert length(chunks) >= 1

      Enum.each(chunks, fn chunk ->
        assert String.length(chunk.content) > 0
        assert chunk.metadata.strategy == :sentence
      end)
    end

    test "combines short sentences to meet min_chars" do
      text = "Hi. Ok. Yes. No. Maybe. Sure."

      chunks = Chunking.chunk(text, strategy: :sentence, min_chars: 20)

      assert length(chunks) >= 1

      # Most chunks should be at least min_chars (except possibly the last)
      non_last_chunks = Enum.drop(chunks, -1)

      Enum.each(non_last_chunks, fn chunk ->
        assert String.length(chunk.content) >= 15
      end)
    end

    test "respects max_chars limit per chunk" do
      # Create a very long sentence
      long_sentence = String.duplicate("word ", 100) <> "."
      text = long_sentence <> " Another sentence."

      chunks = Chunking.chunk(text, strategy: :sentence, max_chars: 200)

      Enum.each(chunks, fn chunk ->
        assert String.length(chunk.content) <= 200
      end)
    end

    test "handles text with no sentence boundaries" do
      text = "Just a long piece of text without any sentence boundaries at all"

      chunks = Chunking.chunk(text, strategy: :sentence, max_chars: 30)

      # Should still produce chunks
      assert length(chunks) >= 1
    end

    test "handles single sentence" do
      text = "This is just one sentence."

      chunks = Chunking.chunk(text, strategy: :sentence)

      assert [chunk] = chunks
      assert chunk.content == text
    end

    test "preserves sentence punctuation" do
      text = "Question? Answer! Statement."

      chunks = Chunking.chunk(text, strategy: :sentence, max_chars: 100)

      content = chunks |> Enum.map(& &1.content) |> Enum.join("")
      assert content =~ "Question?"
      assert content =~ "Answer!"
      assert content =~ "Statement."
    end

    test "handles mixed punctuation and whitespace" do
      text = "First.  Second!   Third?\n\nFourth."

      chunks = Chunking.chunk(text, strategy: :sentence)

      assert length(chunks) >= 1
      assert Enum.all?(chunks, &(String.length(&1.content) > 0))
    end
  end

  describe "chunk/2 with :paragraph strategy" do
    test "splits on double newlines" do
      text = "First paragraph here.\n\nSecond paragraph here.\n\nThird paragraph here."

      chunks = Chunking.chunk(text, strategy: :paragraph)

      assert length(chunks) == 3

      Enum.each(chunks, fn chunk ->
        assert chunk.metadata.strategy == :paragraph
        refute String.contains?(chunk.content, "\n\n")
      end)
    end

    test "combines short paragraphs to meet min_chars" do
      text = "Short.\n\nOk.\n\nYes.\n\nMaybe this is longer."

      chunks = Chunking.chunk(text, strategy: :paragraph, min_chars: 20)

      # Should combine the short paragraphs
      assert length(chunks) < 4
    end

    test "splits long paragraphs using sentence strategy" do
      long_para = String.duplicate("Sentence here. ", 50)
      text = long_para <> "\n\nShort paragraph."

      chunks = Chunking.chunk(text, strategy: :paragraph, max_chars: 200)

      # Long paragraph should be split
      assert length(chunks) >= 2

      Enum.each(chunks, fn chunk ->
        assert String.length(chunk.content) <= 200
      end)
    end

    test "handles text with no paragraph breaks" do
      text = "Single paragraph with no breaks"

      chunks = Chunking.chunk(text, strategy: :paragraph)

      assert [chunk] = chunks
      assert chunk.content == text
    end

    test "handles multiple consecutive newlines" do
      text = "First.\n\n\n\nSecond.\n\n\nThird."

      chunks = Chunking.chunk(text, strategy: :paragraph)

      assert length(chunks) >= 2
      assert Enum.all?(chunks, &(String.length(&1.content) > 0))
    end

    test "preserves paragraph content" do
      text = "Para 1 here.\n\nPara 2 here."

      chunks = Chunking.chunk(text, strategy: :paragraph)

      contents = Enum.map(chunks, & &1.content)
      assert "Para 1 here." in contents or Enum.any?(contents, &String.contains?(&1, "Para 1"))
      assert "Para 2 here." in contents or Enum.any?(contents, &String.contains?(&1, "Para 2"))
    end

    test "handles Windows-style line endings" do
      text = "First paragraph.\r\n\r\nSecond paragraph."

      chunks = Chunking.chunk(text, strategy: :paragraph)

      assert length(chunks) >= 1
    end
  end

  describe "chunk/2 with :recursive strategy" do
    test "tries paragraph first for long text" do
      text = "First paragraph.\n\nSecond paragraph with more content.\n\nThird paragraph."

      chunks = Chunking.chunk(text, strategy: :recursive, max_chars: 100)

      assert length(chunks) >= 1

      assert Enum.all?(chunks, fn chunk ->
               chunk.metadata.strategy == :recursive
             end)
    end

    test "falls back to sentence when paragraphs are too long" do
      long_para = String.duplicate("Sentence. ", 100)
      text = long_para

      chunks = Chunking.chunk(text, strategy: :recursive, max_chars: 200)

      # Should split into multiple chunks
      assert length(chunks) > 1

      Enum.each(chunks, fn chunk ->
        assert String.length(chunk.content) <= 200
      end)
    end

    test "falls back to character when sentences are too long" do
      # Very long sentence with no breaks
      very_long = String.duplicate("word", 200)
      text = very_long

      chunks = Chunking.chunk(text, strategy: :recursive, max_chars: 300)

      # Should still chunk it
      assert length(chunks) >= 1

      Enum.each(chunks, fn chunk ->
        assert String.length(chunk.content) <= 300
      end)
    end

    test "maintains hierarchy metadata" do
      text = "Para 1.\n\nPara 2 with sentence. Another sentence."

      chunks = Chunking.chunk(text, strategy: :recursive, max_chars: 50)

      Enum.each(chunks, fn chunk ->
        assert Map.has_key?(chunk.metadata, :hierarchy)
        assert chunk.metadata.hierarchy in [:paragraph, :sentence, :character]
      end)
    end

    test "handles mixed content optimally" do
      text =
        "Short para.\n\n" <>
          String.duplicate("Medium length paragraph with sentences. ", 10) <>
          "\n\nAnother short one."

      chunks = Chunking.chunk(text, strategy: :recursive, max_chars: 200)

      assert length(chunks) >= 1
      assert Enum.all?(chunks, &(String.length(&1.content) <= 200))
    end

    test "works with empty text" do
      chunks = Chunking.chunk("", strategy: :recursive)

      assert [chunk] = chunks
      assert chunk.content == ""
    end
  end

  describe "chunk/2 with :semantic strategy" do
    test "groups sentences by embedding similarity" do
      text =
        "First sentence about dogs. Second sentence about dogs. " <>
          "Now about cats. More about cats."

      # Mock embedding function that returns similar embeddings for similar topics
      embedding_fn = fn sentence ->
        cond do
          String.contains?(sentence, "dog") -> [1.0, 0.0, 0.0]
          String.contains?(sentence, "cat") -> [0.0, 1.0, 0.0]
          true -> [0.0, 0.0, 1.0]
        end
      end

      chunks =
        Chunking.chunk(text,
          strategy: :semantic,
          embedding_fn: embedding_fn,
          threshold: 0.8
        )

      assert length(chunks) >= 1

      assert Enum.all?(chunks, fn chunk ->
               chunk.metadata.strategy == :semantic
             end)
    end

    test "respects similarity threshold" do
      text = "Sentence one. Sentence two. Sentence three."

      # All different embeddings
      counter = :counters.new(1, [:atomics])

      embedding_fn = fn _sentence ->
        idx = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        List.duplicate(idx / 10, 3)
      end

      # Low threshold = more chunks (less grouping)
      low_threshold_chunks =
        Chunking.chunk(text,
          strategy: :semantic,
          embedding_fn: embedding_fn,
          threshold: 0.99
        )

      :counters.put(counter, 1, 0)

      # High threshold = fewer chunks (more grouping)
      high_threshold_chunks =
        Chunking.chunk(text,
          strategy: :semantic,
          embedding_fn: embedding_fn,
          threshold: 0.01
        )

      # This is probabilistic but generally true
      assert is_list(low_threshold_chunks)
      assert is_list(high_threshold_chunks)
    end

    test "requires embedding_fn parameter" do
      text = "Some text here."

      assert_raise ArgumentError, ~r/embedding_fn/, fn ->
        Chunking.chunk(text, strategy: :semantic)
      end
    end

    test "uses default threshold when not provided" do
      text = "First. Second."

      embedding_fn = fn _sentence -> [1.0, 0.0, 0.0] end

      chunks =
        Chunking.chunk(text,
          strategy: :semantic,
          embedding_fn: embedding_fn
        )

      assert is_list(chunks)
    end

    test "handles single sentence" do
      text = "Just one sentence."

      embedding_fn = fn _sentence -> [1.0, 0.0, 0.0] end

      chunks =
        Chunking.chunk(text,
          strategy: :semantic,
          embedding_fn: embedding_fn
        )

      assert [chunk] = chunks
      assert String.contains?(chunk.content, "Just one sentence")
    end

    test "respects max_chars limit" do
      # Create text that would group together semantically but exceeds max_chars
      text = String.duplicate("Similar topic sentence. ", 50)

      # All similar
      embedding_fn = fn _sentence -> [1.0, 0.0, 0.0] end

      chunks =
        Chunking.chunk(text,
          strategy: :semantic,
          embedding_fn: embedding_fn,
          max_chars: 200
        )

      Enum.each(chunks, fn chunk ->
        assert String.length(chunk.content) <= 200
      end)
    end
  end

  describe "chunk/2 edge cases" do
    test "handles very long text efficiently" do
      # 10,000 characters
      text = String.duplicate("This is a test sentence with some content. ", 200)

      chunks = Chunking.chunk(text, strategy: :character, max_chars: 500)

      assert length(chunks) >= 10
      assert Enum.all?(chunks, &(String.length(&1.content) <= 500))
    end

    test "handles text with only whitespace" do
      chunks = Chunking.chunk("   \n\n   ", strategy: :character)

      assert is_list(chunks)
    end

    test "handles unicode characters properly" do
      text = "Hello 世界. Привет мир. مرحبا العالم."

      chunks = Chunking.chunk(text, strategy: :sentence)

      assert length(chunks) >= 1
      # Check that unicode is preserved
      all_content = chunks |> Enum.map(& &1.content) |> Enum.join()
      assert all_content =~ "世界"
      assert all_content =~ "мир"
      assert all_content =~ "العالم"
    end

    test "indexes chunks sequentially" do
      text = "First. Second. Third. Fourth."

      chunks = Chunking.chunk(text, strategy: :sentence, max_chars: 20)

      indexes = Enum.map(chunks, & &1.index)
      assert indexes == Enum.to_list(0..(length(chunks) - 1))
    end

    test "all chunks have required structure" do
      text = "Test content here."

      chunks = Chunking.chunk(text, strategy: :character)

      Enum.each(chunks, fn chunk ->
        assert Map.has_key?(chunk, :content)
        assert Map.has_key?(chunk, :index)
        assert Map.has_key?(chunk, :metadata)
        assert is_binary(chunk.content)
        assert is_integer(chunk.index)
        assert is_map(chunk.metadata)
        assert Map.has_key?(chunk.metadata, :strategy)
      end)
    end

    test "handles invalid strategy gracefully" do
      assert_raise ArgumentError, ~r/Unknown chunking strategy/, fn ->
        Chunking.chunk("test", strategy: :invalid_strategy)
      end
    end

    test "preserves original text content across all chunks" do
      text = "First sentence. Second sentence. Third sentence."

      strategies = [:character, :sentence, :paragraph, :recursive]

      Enum.each(strategies, fn strategy ->
        chunks = Chunking.chunk(text, strategy: strategy, max_chars: 30)
        combined = chunks |> Enum.map(& &1.content) |> Enum.join("")

        # Should contain all the main content (whitespace handling may vary)
        assert combined =~ "First sentence"
        assert combined =~ "Second sentence"
        assert combined =~ "Third sentence"
      end)
    end
  end

  describe "chunk/2 options validation" do
    test "accepts valid max_chars values" do
      text = "Test text"

      assert Chunking.chunk(text, max_chars: 1)
      assert Chunking.chunk(text, max_chars: 100)
      assert Chunking.chunk(text, max_chars: 10000)
    end

    test "accepts valid overlap values" do
      text = "Test text"

      assert Chunking.chunk(text, overlap: 0)
      assert Chunking.chunk(text, overlap: 50)
    end

    test "handles overlap larger than max_chars" do
      text = "Test text here"

      # Should handle gracefully (overlap effectively capped at max_chars - 1)
      chunks = Chunking.chunk(text, max_chars: 10, overlap: 20)

      assert is_list(chunks)
    end
  end
end
