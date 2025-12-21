defmodule Rag.Ai.ClaudeTest do
  use ExUnit.Case, async: true

  alias Rag.Ai.Claude

  @moduletag :skip_without_anthropic_api_key

  setup do
    if System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_AGENT_OAUTH_TOKEN") do
      :ok
    else
      {:ok, skip: true}
    end
  end

  describe "new/1" do
    test "creates a provider with default model" do
      provider = Claude.new(%{})

      assert %Claude{} = provider
      assert provider.model =~ ~r/claude/i
    end

    test "creates a provider with custom model" do
      provider = Claude.new(%{model: "claude-opus-4-20250514"})

      assert provider.model == "claude-opus-4-20250514"
    end

    test "accepts max_turns option" do
      provider = Claude.new(%{max_turns: 20})

      assert provider.options.max_turns == 20
    end

    test "accepts permission_mode option" do
      provider = Claude.new(%{permission_mode: :strict})

      assert provider.options.permission_mode == :strict
    end
  end

  describe "generate_text/3" do
    @tag :integration
    test "generates text for a simple prompt" do
      provider = Claude.new(%{})

      {:ok, response} = Claude.generate_text(provider, "Say hello", [])

      assert is_binary(response)
      assert String.length(response) > 0
    end

    @tag :integration
    test "respects system_prompt option" do
      provider = Claude.new(%{})

      {:ok, response} =
        Claude.generate_text(
          provider,
          "What is your role?",
          system_prompt: "You are a helpful math tutor."
        )

      assert is_binary(response)
      assert response =~ ~r/math|tutor/i
    end

    @tag :integration
    test "streams response when stream: true" do
      provider = Claude.new(%{})

      {:ok, stream} = Claude.generate_text(provider, "Count to 3", stream: true)

      assert is_function(stream) or match?(%Stream{}, stream)

      chunks = Enum.to_list(stream)
      assert length(chunks) > 0
    end
  end

  describe "generate_embeddings/3" do
    test "returns error as Claude doesn't support embeddings" do
      provider = Claude.new(%{})

      {:error, :not_supported} = Claude.generate_embeddings(provider, ["text"], [])
    end
  end

  describe "supports_tools?/0" do
    test "returns true" do
      assert Claude.supports_tools?() == true
    end
  end

  describe "supports_embeddings?/0" do
    test "returns false" do
      assert Claude.supports_embeddings?() == false
    end
  end

  describe "max_context_tokens/0" do
    test "returns Claude's context window" do
      assert Claude.max_context_tokens() == 200_000
    end
  end

  describe "cost_per_1k_tokens/0" do
    test "returns pricing information" do
      assert {input, output} = Claude.cost_per_1k_tokens()
      assert is_float(input)
      assert is_float(output)
      assert input > 0
      assert output > 0
    end
  end
end
