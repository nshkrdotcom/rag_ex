defmodule Rag.Ai.CodexTest do
  use ExUnit.Case, async: true

  alias Rag.Ai.Codex

  # All tests in this module require Codex credentials and environment
  @moduletag :integration

  describe "new/1" do
    test "creates a provider with default model" do
      provider = Codex.new(%{})

      assert %Codex{} = provider
      assert provider.model =~ ~r/gpt|codex/i
    end

    test "creates a provider with custom model" do
      provider = Codex.new(%{model: "gpt-4o"})

      assert provider.model == "gpt-4o"
    end

    test "creates thread on initialization" do
      provider = Codex.new(%{})

      assert provider.thread != nil
    end

    test "accepts reasoning_effort option" do
      provider = Codex.new(%{reasoning_effort: :high})

      assert provider.reasoning_effort == :high
    end
  end

  describe "generate_text/3" do
    @tag :integration
    test "generates text for a simple prompt" do
      provider = Codex.new(%{})

      {:ok, response} = Codex.generate_text(provider, "Say hello", [])

      assert is_binary(response)
      assert String.length(response) > 0
    end

    @tag :integration
    test "streams response when stream: true" do
      provider = Codex.new(%{})

      {:ok, stream} = Codex.generate_text(provider, "Count to 3", stream: true)

      assert is_function(stream) or match?(%Stream{}, stream)

      chunks = Enum.to_list(stream)
      assert length(chunks) > 0
      assert Enum.all?(chunks, &is_binary/1)
    end

    @tag :integration
    test "respects output_schema option for structured output" do
      provider = Codex.new(%{})

      schema = %{
        type: "object",
        properties: %{
          name: %{type: "string"},
          age: %{type: "number"}
        },
        required: ["name", "age"]
      }

      {:ok, response} =
        Codex.generate_text(
          provider,
          "Generate a person with name John and age 30",
          output_schema: schema
        )

      assert is_binary(response)
      # Should be valid JSON matching schema
      assert {:ok, _} = Jason.decode(response)
    end
  end

  describe "generate_embeddings/3" do
    test "returns error as Codex doesn't support embeddings" do
      provider = Codex.new(%{})

      {:error, :not_supported} = Codex.generate_embeddings(provider, ["text"], [])
    end
  end

  describe "supports_tools?/0" do
    test "returns true" do
      assert Codex.supports_tools?() == true
    end
  end

  describe "supports_embeddings?/0" do
    test "returns false" do
      assert Codex.supports_embeddings?() == false
    end
  end

  describe "max_context_tokens/0" do
    test "returns Codex's context window" do
      assert Codex.max_context_tokens() == 128_000
    end
  end

  describe "cost_per_1k_tokens/0" do
    test "returns pricing information" do
      assert {input, output} = Codex.cost_per_1k_tokens()
      assert is_float(input)
      assert is_float(output)
      assert input > 0
      assert output > 0
    end
  end
end
