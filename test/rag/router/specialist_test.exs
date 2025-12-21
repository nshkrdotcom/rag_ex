defmodule Rag.Router.SpecialistTest do
  use ExUnit.Case, async: true

  alias Rag.Router.Specialist

  describe "init/1" do
    test "initializes with provider list" do
      {:ok, state} = Specialist.init(providers: [:gemini, :codex, :claude])

      assert state.providers == [:gemini, :codex, :claude]
    end

    test "uses default task mappings" do
      {:ok, state} = Specialist.init(providers: [:gemini, :codex, :claude])

      # Gemini for embeddings
      assert state.task_mappings[:embeddings] == :gemini
      # Codex for code
      assert state.task_mappings[:code_generation] == :codex
      # Claude for analysis
      assert state.task_mappings[:analysis] == :claude
    end

    test "accepts custom task mappings" do
      {:ok, state} =
        Specialist.init(
          providers: [:gemini, :codex, :claude],
          task_mappings: %{
            embeddings: :gemini,
            # Override default
            code_generation: :claude,
            analysis: :gemini
          }
        )

      assert state.task_mappings[:code_generation] == :claude
      assert state.task_mappings[:analysis] == :gemini
    end

    test "returns error with empty providers" do
      {:error, :no_providers} = Specialist.init(providers: [])
    end

    test "sets fallback provider" do
      {:ok, state} =
        Specialist.init(
          providers: [:gemini, :codex, :claude],
          fallback_provider: :codex
        )

      assert state.fallback_provider == :codex
    end
  end

  describe "select_provider/2" do
    test "selects gemini for embeddings task" do
      {:ok, state} = Specialist.init(providers: [:gemini, :codex, :claude])
      request = %{type: :embeddings, prompt: ["text"], opts: []}

      {:ok, provider, _state} = Specialist.select_provider(state, request)

      assert provider == :gemini
    end

    test "selects codex for code_generation task" do
      {:ok, state} = Specialist.init(providers: [:gemini, :codex, :claude])
      request = %{type: :text, prompt: "Write code", opts: [task: :code_generation]}

      {:ok, provider, _state} = Specialist.select_provider(state, request)

      assert provider == :codex
    end

    test "selects claude for analysis task" do
      {:ok, state} = Specialist.init(providers: [:gemini, :codex, :claude])
      request = %{type: :text, prompt: "Analyze this", opts: [task: :analysis]}

      {:ok, provider, _state} = Specialist.select_provider(state, request)

      assert provider == :claude
    end

    test "uses fallback for unknown task type" do
      {:ok, state} =
        Specialist.init(
          providers: [:gemini, :codex, :claude],
          fallback_provider: :gemini
        )

      request = %{type: :text, prompt: "Something", opts: [task: :unknown_task]}

      {:ok, provider, _state} = Specialist.select_provider(state, request)

      assert provider == :gemini
    end

    test "infers task from prompt content" do
      {:ok, state} = Specialist.init(providers: [:gemini, :codex, :claude])

      # Code-related prompt
      code_request = %{type: :text, prompt: "Write a function to sort an array", opts: []}
      {:ok, code_provider, _} = Specialist.select_provider(state, code_request)
      assert code_provider == :codex

      # Analysis-related prompt
      analysis_request = %{
        type: :text,
        prompt: "Analyze this code and explain what it does",
        opts: []
      }

      {:ok, analysis_provider, _} = Specialist.select_provider(state, analysis_request)
      assert analysis_provider == :claude
    end

    test "skips unavailable specialist and falls back" do
      {:ok, state} = Specialist.init(providers: [:gemini, :codex, :claude])
      state = %{state | unavailable: MapSet.new([:codex])}
      request = %{type: :text, prompt: "Write code", opts: [task: :code_generation]}

      {:ok, provider, _state} = Specialist.select_provider(state, request)

      # Should fall back since codex is unavailable
      assert provider in [:gemini, :claude]
    end

    test "returns error when all providers unavailable" do
      {:ok, state} = Specialist.init(providers: [:gemini, :codex])
      state = %{state | unavailable: MapSet.new([:gemini, :codex])}
      request = %{type: :text, prompt: "Hello", opts: []}

      {:error, :all_providers_unavailable} = Specialist.select_provider(state, request)
    end
  end

  describe "handle_result/3" do
    test "marks provider unavailable on repeated failures" do
      {:ok, state} = Specialist.init(providers: [:gemini, :codex], max_failures: 2)

      state = Specialist.handle_result(state, :gemini, {:error, :timeout})
      state = Specialist.handle_result(state, :gemini, {:error, :timeout})

      assert MapSet.member?(state.unavailable, :gemini)
    end

    test "resets failure count on success" do
      {:ok, state} = Specialist.init(providers: [:gemini, :codex])

      state = Specialist.handle_result(state, :gemini, {:error, :timeout})
      state = Specialist.handle_result(state, :gemini, {:ok, "response"})

      assert Map.get(state.failures, :gemini, 0) == 0
    end
  end

  describe "task inference" do
    test "detects code-related keywords" do
      {:ok, state} = Specialist.init(providers: [:gemini, :codex, :claude])

      prompts = [
        "implement a sorting algorithm",
        "write a REST API endpoint",
        "create a function that calculates factorial",
        "code a binary search tree"
      ]

      for prompt <- prompts do
        request = %{type: :text, prompt: prompt, opts: []}
        {:ok, provider, _} = Specialist.select_provider(state, request)
        assert provider == :codex, "Expected :codex for prompt: #{prompt}"
      end
    end

    test "detects analysis-related keywords" do
      {:ok, state} = Specialist.init(providers: [:gemini, :codex, :claude])

      prompts = [
        "analyze this function",
        "explain what this code does",
        "review this implementation",
        "compare these approaches"
      ]

      for prompt <- prompts do
        request = %{type: :text, prompt: prompt, opts: []}
        {:ok, provider, _} = Specialist.select_provider(state, request)
        assert provider == :claude, "Expected :claude for prompt: #{prompt}"
      end
    end
  end

  describe "next_provider/3" do
    test "returns fallback provider" do
      {:ok, state} =
        Specialist.init(
          providers: [:gemini, :codex, :claude],
          fallback_provider: :gemini
        )

      request = %{type: :text, prompt: "Write code", opts: [task: :code_generation]}

      # codex failed, should get fallback
      {:ok, next, _state} = Specialist.next_provider(state, :codex, request)

      assert next == :gemini
    end

    test "returns different available provider" do
      {:ok, state} = Specialist.init(providers: [:gemini, :codex, :claude])
      state = %{state | unavailable: MapSet.new([:gemini])}
      request = %{type: :text, prompt: "Hello", opts: []}

      {:ok, next, _state} = Specialist.next_provider(state, :codex, request)

      assert next == :claude
    end
  end
end
