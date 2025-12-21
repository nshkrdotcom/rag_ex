defmodule Rag.Router do
  @moduledoc """
  Multi-LLM provider router.

  The Router manages multiple LLM providers and routes requests
  to the most appropriate provider based on the configured strategy.

  ## Configuration

      {:ok, router} = Router.new(
        providers: [:gemini, :codex, :claude],
        strategy: :specialist,  # or :fallback, :round_robin, :auto
        fallback_order: [:gemini, :codex, :claude]
      )

  ## Strategies

  - `:fallback` - Try providers in order until success (default with 1-2 providers)
  - `:round_robin` - Distribute load across providers
  - `:specialist` - Route by task type to best provider (default with 3 providers)
  - `:auto` - Auto-select strategy based on available providers

  ## Usage

      # Route a request
      {:ok, provider, router} = Router.route(router, :text, "Hello", [])

      # Execute with the provider
      {:ok, result, router} = Router.execute(router, :text, "Hello", [])

      # Report result manually
      router = Router.report_result(router, :gemini, {:ok, "response"})

  ## Auto-Detection

      # Auto-detect available providers based on loaded modules and credentials
      {:ok, router} = Router.new(auto_detect: true)

  """

  alias Rag.Ai.Capabilities

  defstruct [
    :providers,
    :strategy_module,
    :strategy_state,
    :provider_instances
  ]

  @type t :: %__MODULE__{
          providers: [atom()],
          strategy_module: module(),
          strategy_state: term(),
          provider_instances: %{atom() => struct()}
        }

  @strategies %{
    fallback: Rag.Router.Fallback,
    round_robin: Rag.Router.RoundRobin,
    specialist: Rag.Router.Specialist
  }

  @doc """
  Create a new router with the given configuration.

  ## Options

  - `:providers` - List of provider atoms (required unless auto_detect)
  - `:strategy` - Strategy atom or :auto (default: auto-selected)
  - `:auto_detect` - Auto-detect available providers (default: false)
  - `:fallback_order` - Order for fallback attempts
  - Strategy-specific options passed through

  ## Returns

  - `{:ok, router}` on success
  - `{:error, reason}` on failure

  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    providers =
      if Keyword.get(opts, :auto_detect, false) do
        detect_available_providers()
      else
        Keyword.get(opts, :providers, [])
      end

    if providers == [] do
      {:error, :no_providers}
    else
      strategy = determine_strategy(opts, providers)
      strategy_module = Map.get(@strategies, strategy, Rag.Router.Fallback)

      strategy_opts =
        opts
        |> Keyword.put(:providers, providers)
        |> Keyword.put_new(:fallback_order, providers)

      case strategy_module.init(strategy_opts) do
        {:ok, strategy_state} ->
          {:ok,
           %__MODULE__{
             providers: providers,
             strategy_module: strategy_module,
             strategy_state: strategy_state,
             provider_instances: %{}
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Route a request to select the best provider.

  ## Parameters

  - `router` - The router struct
  - `type` - Request type (:text or :embeddings)
  - `prompt` - The prompt or list of texts for embeddings
  - `opts` - Additional options

  ## Returns

  - `{:ok, provider, updated_router}` - Selected provider
  - `{:error, reason}` - No provider available

  """
  @spec route(t(), atom(), term(), keyword()) :: {:ok, atom(), t()} | {:error, term()}
  def route(router, type, prompt, opts) do
    request = %{type: type, prompt: prompt, opts: opts}

    case router.strategy_module.select_provider(router.strategy_state, request) do
      {:ok, provider, new_state} ->
        {:ok, provider, %{router | strategy_state: new_state}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Report the result of a provider call.

  Updates the router's strategy state based on success or failure.

  """
  @spec report_result(t(), atom(), {:ok, term()} | {:error, term()}) :: t()
  def report_result(router, provider, result) do
    new_state =
      router.strategy_module.handle_result(
        router.strategy_state,
        provider,
        result
      )

    %{router | strategy_state: new_state}
  end

  @doc """
  Get the next provider after a failure.

  """
  @spec next_provider(t(), atom()) :: {:ok, atom(), t()} | {:error, term()}
  def next_provider(router, failed_provider) do
    request = %{type: :text, prompt: "", opts: []}

    case router.strategy_module.next_provider(
           router.strategy_state,
           failed_provider,
           request
         ) do
      {:ok, provider, new_state} ->
        {:ok, provider, %{router | strategy_state: new_state}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Get list of currently available providers.

  """
  @spec available_providers(t()) :: [atom()]
  def available_providers(router) do
    case router.strategy_state do
      %{unavailable: unavailable} ->
        Enum.reject(router.providers, &MapSet.member?(unavailable, &1))

      %{failures: failures, max_failures: max} ->
        Enum.reject(router.providers, fn p ->
          Map.get(failures, p, 0) >= max
        end)

      _ ->
        router.providers
    end
  end

  @doc """
  Get capabilities for a specific provider.

  """
  @spec get_provider(t(), atom()) :: {:ok, map()} | {:error, :not_found}
  def get_provider(router, provider) do
    if provider in router.providers do
      case Capabilities.get(provider) do
        nil -> {:error, :not_found}
        caps -> {:ok, caps}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Execute a request with automatic provider selection and retry.

  Routes the request, executes with the selected provider, and
  handles retries on failure.

  """
  @spec execute(t(), atom(), term(), keyword()) :: {:ok, term(), t()} | {:error, term()}
  def execute(router, type, prompt, opts) do
    case route(router, type, prompt, opts) do
      {:ok, provider, router} ->
        execute_with_provider(router, provider, type, prompt, opts, [])

      {:error, _} = err ->
        err
    end
  end

  # Private functions

  defp execute_with_provider(router, provider, type, prompt, opts, tried) do
    provider_instance = get_or_create_provider_instance(router, provider)

    result =
      case type do
        :embeddings ->
          provider_instance.__struct__.generate_embeddings(provider_instance, prompt, opts)

        :text ->
          provider_instance.__struct__.generate_text(provider_instance, prompt, opts)
      end

    router = report_result(router, provider, result)

    case result do
      {:ok, response} ->
        {:ok, response, router}

      {:error, _reason} ->
        # Try next provider
        tried = [provider | tried]

        case next_provider(router, provider) do
          {:ok, next, router} ->
            if next in tried do
              {:error, :all_providers_failed}
            else
              execute_with_provider(router, next, type, prompt, opts, tried)
            end

          _ ->
            {:error, :all_providers_failed}
        end
    end
  end

  defp get_or_create_provider_instance(router, provider) do
    case Map.get(router.provider_instances, provider) do
      nil ->
        caps = Capabilities.get(provider)
        caps.module.new(%{})

      instance ->
        instance
    end
  end

  defp detect_available_providers do
    Capabilities.available()
    |> Enum.map(fn {key, _caps} -> key end)
  end

  defp determine_strategy(opts, providers) do
    explicit = Keyword.get(opts, :strategy)

    cond do
      explicit == :auto or explicit == nil ->
        auto_select_strategy(providers)

      explicit ->
        explicit
    end
  end

  defp auto_select_strategy(providers) do
    provider_count = length(providers)

    cond do
      provider_count >= 3 ->
        :specialist

      provider_count >= 2 ->
        :fallback

      true ->
        :fallback
    end
  end
end
