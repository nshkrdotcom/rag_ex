defmodule Rag.Ai.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Rag.Ai.Capabilities

  describe "get/1" do
    test "returns capabilities for gemini" do
      caps = Capabilities.get(:gemini)

      assert caps.module == Rag.Ai.Gemini
      assert caps.embeddings == true
      assert caps.tools == true
      assert caps.streaming == true
      assert caps.max_context == 1_000_000
      assert is_tuple(caps.cost)
      assert is_list(caps.strengths)
    end

    test "returns capabilities for codex" do
      caps = Capabilities.get(:codex)

      assert caps.module == Rag.Ai.Codex
      assert caps.embeddings == false
      assert caps.tools == true
      assert caps.streaming == true
      assert caps.max_context == 128_000
      assert is_tuple(caps.cost)
      assert :code_generation in caps.strengths
    end

    test "returns capabilities for claude" do
      caps = Capabilities.get(:claude)

      assert caps.module == Rag.Ai.Claude
      assert caps.embeddings == false
      assert caps.tools == true
      assert caps.streaming == true
      assert caps.max_context == 200_000
      assert is_tuple(caps.cost)
      assert :analysis in caps.strengths
    end

    test "returns nil for unknown provider" do
      assert Capabilities.get(:unknown) == nil
    end
  end

  describe "all/0" do
    test "returns map of all provider capabilities" do
      all = Capabilities.all()

      assert is_map(all)
      assert Map.has_key?(all, :gemini)
      assert Map.has_key?(all, :codex)
      assert Map.has_key?(all, :claude)
    end

    test "all providers have required fields" do
      all = Capabilities.all()

      for {_key, caps} <- all do
        assert is_atom(caps.module)
        assert is_boolean(caps.embeddings)
        assert is_boolean(caps.tools)
        assert is_boolean(caps.streaming)
        assert is_integer(caps.max_context)
        assert is_tuple(caps.cost)
        assert is_list(caps.strengths)
      end
    end
  end

  describe "available/0" do
    test "returns only providers with loaded modules" do
      available = Capabilities.available()

      assert is_list(available)

      for {_key, caps} <- available do
        assert Code.ensure_loaded?(caps.module)
        assert function_exported?(caps.module, :new, 1)
      end
    end

    test "filters out unavailable providers" do
      available = Capabilities.available()
      all_keys = Map.keys(Capabilities.all())

      available_keys = Enum.map(available, &elem(&1, 0))

      # Available should be subset of all
      assert Enum.all?(available_keys, &(&1 in all_keys))
    end
  end

  describe "with_capability/1" do
    test "filters providers with embeddings capability" do
      providers = Capabilities.with_capability(:embeddings)

      assert is_list(providers)
      assert Enum.all?(providers, fn {_key, caps} -> caps.embeddings == true end)

      # Only Gemini supports embeddings
      assert length(providers) == 1
      assert {:gemini, _} = List.first(providers)
    end

    test "filters providers with tools capability" do
      providers = Capabilities.with_capability(:tools)

      assert is_list(providers)
      assert Enum.all?(providers, fn {_key, caps} -> caps.tools == true end)

      # All providers support tools
      assert length(providers) == 3
    end

    test "filters providers with streaming capability" do
      providers = Capabilities.with_capability(:streaming)

      assert is_list(providers)
      assert Enum.all?(providers, fn {_key, caps} -> caps.streaming == true end)

      # All providers support streaming
      assert length(providers) == 3
    end

    test "returns empty list for non-existent capability" do
      providers = Capabilities.with_capability(:non_existent)

      assert providers == []
    end
  end

  describe "best_for/1" do
    test "returns gemini for embeddings task" do
      assert Capabilities.best_for(:embeddings) == :gemini
    end

    test "returns codex for code_generation task" do
      assert Capabilities.best_for(:code_generation) == :codex
    end

    test "returns claude for analysis task" do
      assert Capabilities.best_for(:analysis) == :claude
    end

    test "returns gemini for long_context task" do
      assert Capabilities.best_for(:long_context) == :gemini
    end

    test "returns default provider for unknown task" do
      best = Capabilities.best_for(:unknown_task)

      assert best in [:gemini, :codex, :claude]
    end
  end

  describe "check_available/1" do
    test "returns true for loaded provider" do
      # Assuming at least one provider is loaded
      result = Capabilities.check_available(Rag.Ai.Gemini)

      assert is_boolean(result)
    end

    test "returns false for non-existent module" do
      result = Capabilities.check_available(NonExistent.Module)

      assert result == false
    end
  end
end
