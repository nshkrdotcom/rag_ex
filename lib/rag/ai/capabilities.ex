defmodule Rag.Ai.Capabilities do
  @moduledoc """
  Provider capability registry and selection helpers.

  This module maintains metadata about all available LLM providers,
  their capabilities, costs, and strengths. It helps in:
  - Auto-detecting available providers
  - Selecting the best provider for a task
  - Understanding provider limitations

  ## Examples

      # Get capabilities for a specific provider
      caps = Capabilities.get(:gemini)
      caps.embeddings  # => true
      caps.max_context # => 1_000_000

      # Find providers with specific capability
      providers = Capabilities.with_capability(:embeddings)
      # => [{:gemini, %{...}}]

      # Find best provider for a task
      Capabilities.best_for(:code_generation)
      # => :codex

  """

  @providers %{
    gemini: %{
      module: Rag.Ai.Gemini,
      embeddings: true,
      tools: true,
      streaming: true,
      max_context: 1_000_000,
      # per 1K tokens (USD)
      cost: {0.000075, 0.000300},
      strengths: [:long_context, :multimodal, :embeddings, :cost, :speed]
    },
    codex: %{
      module: Rag.Ai.Codex,
      embeddings: false,
      tools: true,
      streaming: true,
      max_context: 128_000,
      # per 1K tokens (USD)
      cost: {0.00250, 0.01000},
      strengths: [:code_generation, :reasoning, :structured_output, :code_review]
    },
    claude: %{
      module: Rag.Ai.Claude,
      embeddings: false,
      tools: true,
      streaming: true,
      max_context: 200_000,
      # per 1K tokens (USD)
      cost: {0.00300, 0.01500},
      strengths: [:analysis, :writing, :safety, :agentic, :reasoning]
    }
  }

  @doc """
  Get capabilities for a specific provider.

  Returns `nil` if the provider is not known.

  ## Examples

      iex> Capabilities.get(:gemini)
      %{module: Rag.Ai.Gemini, embeddings: true, ...}

      iex> Capabilities.get(:unknown)
      nil

  """
  @spec get(atom()) :: map() | nil
  def get(provider) when is_atom(provider) do
    Map.get(@providers, provider)
  end

  @doc """
  Get all provider capabilities.

  ## Examples

      iex> all = Capabilities.all()
      iex> Map.keys(all)
      [:gemini, :codex, :claude]

  """
  @spec all() :: map()
  def all, do: @providers

  @doc """
  Get list of available providers (those with loaded modules and credentials).

  Only returns providers that are actually usable in the current environment.

  ## Examples

      iex> Capabilities.available()
      [{:gemini, %{...}}, {:codex, %{...}}]

  """
  @spec available() :: [{atom(), map()}]
  def available do
    @providers
    |> Enum.filter(fn {key, caps} ->
      check_available(caps.module) and check_credentials(key)
    end)
  end

  @doc """
  Filter providers by a specific capability.

  ## Examples

      iex> Capabilities.with_capability(:embeddings)
      [{:gemini, %{...}}]

      iex> Capabilities.with_capability(:tools)
      [{:gemini, %{...}}, {:codex, %{...}}, {:claude, %{...}}]

  """
  @spec with_capability(atom()) :: [{atom(), map()}]
  def with_capability(capability) do
    @providers
    |> Enum.filter(fn {_key, caps} ->
      Map.get(caps, capability) == true
    end)
  end

  @doc """
  Find the best provider for a specific task type.

  Returns the provider key (`:gemini`, `:codex`, or `:claude`) that
  is best suited for the given task.

  ## Task Types

  - `:embeddings` - Embedding generation
  - `:code_generation` - Writing new code
  - `:code_review` - Reviewing existing code
  - `:analysis` - Deep analysis and reasoning
  - `:writing` - Content creation
  - `:long_context` - Tasks requiring large context windows
  - `:structured_output` - JSON/structured data generation
  - `:agentic` - Multi-step agentic workflows
  - `:reasoning` - Complex reasoning tasks

  ## Examples

      iex> Capabilities.best_for(:embeddings)
      :gemini

      iex> Capabilities.best_for(:code_generation)
      :codex

      iex> Capabilities.best_for(:analysis)
      :claude

  """
  @spec best_for(atom()) :: atom()
  def best_for(task) do
    case task do
      :embeddings -> :gemini
      :code_generation -> :codex
      :code_review -> :codex
      :analysis -> :claude
      :writing -> :claude
      :long_context -> :gemini
      :structured_output -> :codex
      :agentic -> :claude
      :reasoning -> :claude
      :multimodal -> :gemini
      :cost -> :gemini
      :speed -> :gemini
      :safety -> :claude
      _ -> default_provider()
    end
  end

  @doc """
  Check if a provider module is available (loaded and functional).

  ## Examples

      iex> Capabilities.check_available(Rag.Ai.Gemini)
      true

      iex> Capabilities.check_available(NonExistent.Module)
      false

  """
  @spec check_available(module()) :: boolean()
  def check_available(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :new, 1)
  end

  @doc """
  Get the default provider (first available).

  Prefers Gemini > Codex > Claude based on cost and versatility.

  ## Examples

      iex> Capabilities.default_provider()
      :gemini

  """
  @spec default_provider() :: atom()
  def default_provider do
    case available() do
      [{key, _} | _] -> key
      # Fallback even if not available
      [] -> :gemini
    end
  end

  @doc """
  Check if a provider is available and has the required capability.

  ## Examples

      iex> Capabilities.can_handle?(:gemini, :embeddings)
      true

      iex> Capabilities.can_handle?(:codex, :embeddings)
      false

  """
  @spec can_handle?(atom(), atom()) :: boolean()
  def can_handle?(provider, capability) do
    case get(provider) do
      nil -> false
      caps -> Map.get(caps, capability) == true
    end
  end

  # Private functions

  defp check_credentials(:gemini) do
    System.get_env("GEMINI_API_KEY") != nil
  end

  defp check_credentials(:codex) do
    System.get_env("CODEX_API_KEY") != nil or System.get_env("OPENAI_API_KEY") != nil
  end

  defp check_credentials(:claude) do
    System.get_env("ANTHROPIC_API_KEY") != nil or
      System.get_env("CLAUDE_AGENT_OAUTH_TOKEN") != nil
  end

  defp check_credentials(_), do: false
end
