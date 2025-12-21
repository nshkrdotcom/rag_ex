defmodule Rag.Ai.GeminiTest do
  use ExUnit.Case, async: true

  alias Rag.Ai.Gemini

  @moduletag :skip_without_gemini_api_key

  setup do
    if System.get_env("GEMINI_API_KEY") do
      :ok
    else
      {:ok, skip: true}
    end
  end

  describe "new/1" do
    test "creates a provider with default model" do
      provider = Gemini.new(%{})

      assert %Gemini{} = provider
      assert provider.model == "gemini-2.0-flash-exp"
    end

    test "creates a provider with custom model" do
      provider = Gemini.new(%{model: "gemini-1.5-pro"})

      assert provider.model == "gemini-1.5-pro"
    end

    test "accepts configuration options" do
      config = %{temperature: 0.5, max_tokens: 1000}
      provider = Gemini.new(%{config: config})

      assert provider.config == config
    end
  end

  describe "generate_text/3" do
    @tag :integration
    test "generates text for a simple prompt" do
      provider = Gemini.new(%{})

      {:ok, response} = Gemini.generate_text(provider, "Say hello", [])

      assert is_binary(response)
      assert String.length(response) > 0
    end

    @tag :integration
    test "respects temperature option" do
      provider = Gemini.new(%{})

      {:ok, response} =
        Gemini.generate_text(provider, "Write a number between 1 and 10", temperature: 0.0)

      assert is_binary(response)
    end

    @tag :integration
    test "respects max_tokens option" do
      provider = Gemini.new(%{})

      {:ok, response} = Gemini.generate_text(provider, "Write a long story", max_tokens: 50)

      assert is_binary(response)
      # Response should be relatively short due to token limit
      assert String.length(response) < 500
    end

    @tag :integration
    test "streams response when stream: true" do
      provider = Gemini.new(%{})

      {:ok, stream} = Gemini.generate_text(provider, "Count to 3", stream: true)

      assert is_function(stream) or match?(%Stream{}, stream)

      chunks = Enum.to_list(stream)
      assert length(chunks) > 0
      assert Enum.all?(chunks, &is_binary/1)
    end
  end

  describe "generate_embeddings/3" do
    @tag :integration
    test "generates embeddings for a single text" do
      provider = Gemini.new(%{})

      {:ok, [embedding]} = Gemini.generate_embeddings(provider, ["hello world"], [])

      assert is_list(embedding)
      # Default dimension
      assert length(embedding) == 768
      assert Enum.all?(embedding, &is_float/1)
    end

    @tag :integration
    test "generates embeddings for multiple texts" do
      provider = Gemini.new(%{})

      {:ok, embeddings} = Gemini.generate_embeddings(provider, ["hello", "world", "test"], [])

      assert length(embeddings) == 3

      assert Enum.all?(embeddings, fn emb ->
               is_list(emb) and length(emb) == 768
             end)
    end

    @tag :integration
    test "respects task_type option" do
      provider = Gemini.new(%{})

      {:ok, [embedding]} =
        Gemini.generate_embeddings(
          provider,
          ["query text"],
          task_type: :retrieval_query
        )

      assert is_list(embedding)
      assert length(embedding) == 768
    end
  end

  describe "supports_tools?/0" do
    test "returns true" do
      assert Gemini.supports_tools?() == true
    end
  end

  describe "supports_embeddings?/0" do
    test "returns true" do
      assert Gemini.supports_embeddings?() == true
    end
  end

  describe "max_context_tokens/0" do
    test "returns Gemini's context window" do
      assert Gemini.max_context_tokens() == 1_000_000
    end
  end

  describe "cost_per_1k_tokens/0" do
    test "returns pricing information" do
      assert {input, output} = Gemini.cost_per_1k_tokens()
      assert is_float(input)
      assert is_float(output)
      assert input > 0
      assert output > 0
    end
  end
end
