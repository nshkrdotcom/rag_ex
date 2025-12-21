defmodule Rag.Router.RoundRobinTest do
  use ExUnit.Case, async: true

  alias Rag.Router.RoundRobin

  describe "init/1" do
    test "initializes with provider list" do
      {:ok, state} = RoundRobin.init(providers: [:gemini, :codex, :claude])

      assert state.providers == [:gemini, :codex, :claude]
      assert state.current_index == 0
    end

    test "returns error with empty providers" do
      {:error, :no_providers} = RoundRobin.init(providers: [])
    end

    test "initializes with weights" do
      {:ok, state} =
        RoundRobin.init(
          providers: [:gemini, :codex, :claude],
          weights: %{gemini: 3, codex: 2, claude: 1}
        )

      assert state.weights == %{gemini: 3, codex: 2, claude: 1}
    end
  end

  describe "select_provider/2" do
    test "rotates through providers in order" do
      {:ok, state} = RoundRobin.init(providers: [:gemini, :codex, :claude])
      request = %{type: :text, prompt: "Hello", opts: []}

      {:ok, p1, state} = RoundRobin.select_provider(state, request)
      {:ok, p2, state} = RoundRobin.select_provider(state, request)
      {:ok, p3, state} = RoundRobin.select_provider(state, request)
      {:ok, p4, _state} = RoundRobin.select_provider(state, request)

      assert p1 == :gemini
      assert p2 == :codex
      assert p3 == :claude
      # Wraps around
      assert p4 == :gemini
    end

    test "skips unavailable providers" do
      {:ok, state} = RoundRobin.init(providers: [:gemini, :codex, :claude])
      state = %{state | unavailable: MapSet.new([:codex])}
      request = %{type: :text, prompt: "Hello", opts: []}

      {:ok, p1, state} = RoundRobin.select_provider(state, request)
      {:ok, p2, _state} = RoundRobin.select_provider(state, request)

      assert p1 == :gemini
      # Skips codex
      assert p2 == :claude
    end

    test "returns error when all providers unavailable" do
      {:ok, state} = RoundRobin.init(providers: [:gemini, :codex])
      state = %{state | unavailable: MapSet.new([:gemini, :codex])}
      request = %{type: :text, prompt: "Hello", opts: []}

      {:error, :all_providers_unavailable} = RoundRobin.select_provider(state, request)
    end
  end

  describe "weighted round-robin" do
    test "respects weights in selection" do
      {:ok, state} =
        RoundRobin.init(
          providers: [:gemini, :codex],
          weights: %{gemini: 2, codex: 1}
        )

      request = %{type: :text, prompt: "Hello", opts: []}

      # With weights 2:1, gemini should be selected twice as often
      selections =
        Enum.reduce(1..6, {[], state}, fn _, {acc, s} ->
          {:ok, provider, new_s} = RoundRobin.select_provider(s, request)
          {[provider | acc], new_s}
        end)
        |> elem(0)
        |> Enum.reverse()

      gemini_count = Enum.count(selections, &(&1 == :gemini))
      codex_count = Enum.count(selections, &(&1 == :codex))

      # Should be approximately 2:1 ratio
      assert gemini_count == 4
      assert codex_count == 2
    end
  end

  describe "handle_result/3" do
    test "marks provider unavailable on repeated failures" do
      {:ok, state} = RoundRobin.init(providers: [:gemini, :codex], max_consecutive_failures: 2)

      state = RoundRobin.handle_result(state, :gemini, {:error, :timeout})
      state = RoundRobin.handle_result(state, :gemini, {:error, :timeout})

      assert MapSet.member?(state.unavailable, :gemini)
    end

    test "resets failure count on success" do
      {:ok, state} = RoundRobin.init(providers: [:gemini, :codex])

      state = RoundRobin.handle_result(state, :gemini, {:error, :timeout})
      assert state.consecutive_failures[:gemini] == 1

      state = RoundRobin.handle_result(state, :gemini, {:ok, "response"})
      assert state.consecutive_failures[:gemini] == 0
    end

    test "recovers unavailable provider after cooldown" do
      {:ok, state} =
        RoundRobin.init(
          providers: [:gemini, :codex],
          recovery_cooldown_ms: 100
        )

      state = %{
        state
        | unavailable: MapSet.new([:gemini]),
          unavailable_since: %{gemini: System.monotonic_time(:millisecond) - 150}
      }

      # After cooldown, should be available again
      request = %{type: :text, prompt: "Hello", opts: []}
      {:ok, provider, _state} = RoundRobin.select_provider(state, request)

      assert provider == :gemini
    end
  end

  describe "next_provider/3" do
    test "returns next provider in rotation" do
      {:ok, state} = RoundRobin.init(providers: [:gemini, :codex, :claude])
      request = %{type: :text, prompt: "Hello", opts: []}

      {:ok, next, _state} = RoundRobin.next_provider(state, :gemini, request)

      assert next == :codex
    end

    test "wraps around to first provider" do
      {:ok, state} = RoundRobin.init(providers: [:gemini, :codex, :claude])
      # At claude
      state = %{state | current_index: 2}
      request = %{type: :text, prompt: "Hello", opts: []}

      {:ok, next, _state} = RoundRobin.next_provider(state, :claude, request)

      assert next == :gemini
    end
  end
end
