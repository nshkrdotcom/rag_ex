defmodule Rag.Router.FallbackTest do
  use ExUnit.Case, async: true

  alias Rag.Router.Fallback

  describe "init/1" do
    test "initializes with provider list" do
      {:ok, state} = Fallback.init(providers: [:gemini, :codex, :claude])

      assert state.providers == [:gemini, :codex, :claude]
      assert state.fallback_order == [:gemini, :codex, :claude]
    end

    test "uses custom fallback order" do
      {:ok, state} =
        Fallback.init(
          providers: [:gemini, :codex, :claude],
          fallback_order: [:claude, :gemini, :codex]
        )

      assert state.fallback_order == [:claude, :gemini, :codex]
    end

    test "returns error with empty providers" do
      {:error, :no_providers} = Fallback.init(providers: [])
    end

    test "returns error with missing providers option" do
      {:error, :no_providers} = Fallback.init([])
    end

    test "initializes failure tracking" do
      {:ok, state} = Fallback.init(providers: [:gemini, :codex])

      assert state.failures == %{}
      assert state.current_index == 0
    end
  end

  describe "select_provider/2" do
    test "selects first provider in fallback order" do
      {:ok, state} = Fallback.init(providers: [:gemini, :codex, :claude])
      request = %{type: :text, prompt: "Hello", opts: []}

      {:ok, provider, _new_state} = Fallback.select_provider(state, request)

      assert provider == :gemini
    end

    test "skips failed providers" do
      {:ok, state} = Fallback.init(providers: [:gemini, :codex, :claude])
      state = %{state | failures: %{gemini: 3}}
      request = %{type: :text, prompt: "Hello", opts: []}

      {:ok, provider, _new_state} = Fallback.select_provider(state, request)

      assert provider == :codex
    end

    test "returns error when all providers failed" do
      {:ok, state} = Fallback.init(providers: [:gemini, :codex])
      state = %{state | failures: %{gemini: 3, codex: 3}}
      request = %{type: :text, prompt: "Hello", opts: []}

      {:error, :all_providers_failed} = Fallback.select_provider(state, request)
    end

    test "respects max_failures threshold" do
      {:ok, state} = Fallback.init(providers: [:gemini, :codex], max_failures: 2)
      # gemini has 2 failures (at threshold), codex has 1
      state = %{state | failures: %{gemini: 2, codex: 1}}
      request = %{type: :text, prompt: "Hello", opts: []}

      {:ok, provider, _new_state} = Fallback.select_provider(state, request)

      # gemini is at max so skip to codex
      assert provider == :codex
    end
  end

  describe "handle_result/3" do
    test "resets failure count on success" do
      {:ok, state} = Fallback.init(providers: [:gemini, :codex])
      state = %{state | failures: %{gemini: 2}}

      new_state = Fallback.handle_result(state, :gemini, {:ok, "response"})

      assert new_state.failures[:gemini] == 0
    end

    test "increments failure count on error" do
      {:ok, state} = Fallback.init(providers: [:gemini, :codex])

      new_state = Fallback.handle_result(state, :gemini, {:error, :timeout})

      assert new_state.failures[:gemini] == 1

      new_state2 = Fallback.handle_result(new_state, :gemini, {:error, :api_error})

      assert new_state2.failures[:gemini] == 2
    end

    test "tracks failures per provider independently" do
      {:ok, state} = Fallback.init(providers: [:gemini, :codex, :claude])

      state = Fallback.handle_result(state, :gemini, {:error, :timeout})
      state = Fallback.handle_result(state, :codex, {:error, :timeout})
      state = Fallback.handle_result(state, :gemini, {:error, :api_error})

      assert state.failures[:gemini] == 2
      assert state.failures[:codex] == 1
      assert Map.get(state.failures, :claude, 0) == 0
    end
  end

  describe "next_provider/3" do
    test "returns next provider in fallback order" do
      {:ok, state} = Fallback.init(providers: [:gemini, :codex, :claude])
      request = %{type: :text, prompt: "Hello", opts: []}

      {:ok, next, _new_state} = Fallback.next_provider(state, :gemini, request)

      assert next == :codex
    end

    test "skips to third provider when second also failed" do
      {:ok, state} = Fallback.init(providers: [:gemini, :codex, :claude])
      state = %{state | failures: %{codex: 3}}
      request = %{type: :text, prompt: "Hello", opts: []}

      {:ok, next, _new_state} = Fallback.next_provider(state, :gemini, request)

      assert next == :claude
    end

    test "returns error when no more providers available" do
      {:ok, state} = Fallback.init(providers: [:gemini, :codex])
      request = %{type: :text, prompt: "Hello", opts: []}

      {:error, :no_more_providers} = Fallback.next_provider(state, :codex, request)
    end
  end

  describe "failure decay" do
    test "decays failures over time when configured" do
      {:ok, state} =
        Fallback.init(
          providers: [:gemini, :codex],
          failure_decay_ms: 100
        )

      state = %{
        state
        | failures: %{gemini: 3},
          failure_times: %{gemini: System.monotonic_time(:millisecond) - 150}
      }

      # After decay time, failures should be reduced
      {:ok, provider, _state} =
        Fallback.select_provider(state, %{type: :text, prompt: "", opts: []})

      assert provider == :gemini
    end
  end
end
