defmodule Rag.Router.RouterTest do
  use ExUnit.Case, async: true

  alias Rag.Router

  describe "new/1" do
    test "creates router with default strategy" do
      {:ok, router} = Router.new(providers: [:gemini, :codex, :claude])

      assert router.providers == [:gemini, :codex, :claude]
      # With 3 providers, auto-selects specialist
      assert router.strategy_module == Rag.Router.Specialist
    end

    test "creates router with specific strategy" do
      {:ok, router} =
        Router.new(
          providers: [:gemini, :codex, :claude],
          strategy: :round_robin
        )

      assert router.strategy_module == Rag.Router.RoundRobin
    end

    test "creates router with specialist strategy" do
      {:ok, router} =
        Router.new(
          providers: [:gemini, :codex, :claude],
          strategy: :specialist
        )

      assert router.strategy_module == Rag.Router.Specialist
    end

    test "returns error with no providers" do
      {:error, :no_providers} = Router.new(providers: [])
    end

    @tag :requires_llm_provider
    test "auto-detects available providers" do
      {:ok, router} = Router.new(auto_detect: true)

      # Should have at least detected gemini if module is loaded
      assert is_list(router.providers)
    end
  end

  describe "route/3" do
    test "routes text generation request" do
      {:ok, router} = Router.new(providers: [:gemini, :codex, :claude])

      {:ok, provider, _router} = Router.route(router, :text, "Hello world", [])

      assert provider in [:gemini, :codex, :claude]
    end

    test "routes embeddings request to gemini" do
      {:ok, router} =
        Router.new(
          providers: [:gemini, :codex, :claude],
          strategy: :specialist
        )

      {:ok, provider, _router} = Router.route(router, :embeddings, ["text"], [])

      # Specialist should route embeddings to gemini
      assert provider == :gemini
    end

    test "updates router state after routing" do
      {:ok, router} =
        Router.new(
          providers: [:gemini, :codex, :claude],
          strategy: :round_robin
        )

      {:ok, _p1, router} = Router.route(router, :text, "Hello", [])
      {:ok, _p2, router} = Router.route(router, :text, "World", [])
      {:ok, p3, _router} = Router.route(router, :text, "Test", [])

      # Round robin should cycle through providers
      assert p3 == :claude
    end
  end

  describe "report_result/3" do
    test "updates router after success" do
      {:ok, router} = Router.new(providers: [:gemini, :codex])

      router = Router.report_result(router, :gemini, {:ok, "response"})

      # Should not mark gemini as failed
      assert router.strategy_state.failures[:gemini] == 0
    end

    test "updates router after failure" do
      {:ok, router} = Router.new(providers: [:gemini, :codex])

      router = Router.report_result(router, :gemini, {:error, :timeout})

      # Should increment gemini failures
      assert router.strategy_state.failures[:gemini] == 1
    end
  end

  describe "next_provider/2" do
    test "gets next provider after failure" do
      {:ok, router} = Router.new(providers: [:gemini, :codex, :claude])

      {:ok, next, _router} = Router.next_provider(router, :gemini)

      assert next == :codex
    end

    test "returns error when no more providers" do
      {:ok, router} = Router.new(providers: [:gemini])

      {:error, :no_more_providers} = Router.next_provider(router, :gemini)
    end
  end

  describe "available_providers/1" do
    test "returns list of available providers" do
      {:ok, router} = Router.new(providers: [:gemini, :codex, :claude])

      available = Router.available_providers(router)

      assert :gemini in available
      assert :codex in available
      assert :claude in available
    end

    test "excludes failed providers" do
      {:ok, router} = Router.new(providers: [:gemini, :codex], strategy: :fallback)

      # Simulate failures
      router = Router.report_result(router, :gemini, {:error, :timeout})
      router = Router.report_result(router, :gemini, {:error, :timeout})
      router = Router.report_result(router, :gemini, {:error, :timeout})

      available = Router.available_providers(router)

      # gemini should be excluded after 3 failures
      refute :gemini in available
      assert :codex in available
    end
  end

  describe "get_provider/2" do
    test "returns provider capabilities" do
      {:ok, router} = Router.new(providers: [:gemini, :codex, :claude])

      {:ok, caps} = Router.get_provider(router, :gemini)

      assert caps.embeddings == true
      assert caps.tools == true
    end

    test "returns error for unknown provider" do
      {:ok, router} = Router.new(providers: [:gemini, :codex])

      {:error, :not_found} = Router.get_provider(router, :unknown)
    end
  end

  describe "strategy selection helpers" do
    test "fallback strategy with single provider" do
      {:ok, router} = Router.new(providers: [:gemini])

      # With single provider, should use fallback
      assert router.strategy_module == Rag.Router.Fallback
    end

    test "auto-selects specialist with 3 providers" do
      {:ok, router} =
        Router.new(
          providers: [:gemini, :codex, :claude],
          strategy: :auto
        )

      # With 3 different providers, specialist makes sense
      assert router.strategy_module == Rag.Router.Specialist
    end
  end

  describe "execute/4" do
    @tag :skip
    test "executes request with provider and handles result" do
      {:ok, router} = Router.new(providers: [:gemini, :codex, :claude])

      # This would actually call the provider
      # Skipped as it requires real API keys
      {:ok, result, _router} = Router.execute(router, :text, "Hello", [])

      assert is_binary(result)
    end
  end
end
