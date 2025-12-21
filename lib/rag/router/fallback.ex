defmodule Rag.Router.Fallback do
  @moduledoc """
  Fallback routing strategy.

  Tries providers in order until one succeeds. If a provider fails
  multiple times, it is temporarily skipped. Failed providers are
  automatically retried after a decay period.

  ## Configuration

      Fallback.init(
        providers: [:gemini, :codex, :claude],
        fallback_order: [:claude, :gemini, :codex],  # Optional custom order
        max_failures: 3,                              # Skip after N failures
        failure_decay_ms: 60_000                      # Reset failures after 60s
      )

  ## Behavior

  1. Selects first available provider in fallback order
  2. On failure, marks provider and tries next
  3. Skips providers with >= max_failures recent failures
  4. Resets failure count on success
  5. Decays failure count over time

  ## Example

      {:ok, state} = Fallback.init(providers: [:gemini, :codex, :claude])
      {:ok, :gemini, state} = Fallback.select_provider(state, request)

      # If gemini fails
      state = Fallback.handle_result(state, :gemini, {:error, :timeout})
      {:ok, :codex, state} = Fallback.next_provider(state, :gemini, request)

  """

  @behaviour Rag.Router.Strategy

  defstruct [
    :providers,
    :fallback_order,
    :max_failures,
    :failure_decay_ms,
    failures: %{},
    failure_times: %{},
    current_index: 0
  ]

  @type t :: %__MODULE__{
          providers: [atom()],
          fallback_order: [atom()],
          max_failures: pos_integer(),
          failure_decay_ms: pos_integer() | nil,
          failures: %{atom() => non_neg_integer()},
          failure_times: %{atom() => integer()},
          current_index: non_neg_integer()
        }

  @default_max_failures 3
  @default_failure_decay_ms 60_000

  @impl true
  def init(opts) do
    providers = Keyword.get(opts, :providers, [])

    if providers == [] do
      {:error, :no_providers}
    else
      fallback_order = Keyword.get(opts, :fallback_order, providers)
      max_failures = Keyword.get(opts, :max_failures, @default_max_failures)
      failure_decay_ms = Keyword.get(opts, :failure_decay_ms, @default_failure_decay_ms)

      {:ok,
       %__MODULE__{
         providers: providers,
         fallback_order: fallback_order,
         max_failures: max_failures,
         failure_decay_ms: failure_decay_ms,
         failures: %{},
         failure_times: %{},
         current_index: 0
       }}
    end
  end

  @impl true
  def select_provider(state, _request) do
    state = maybe_decay_failures(state)

    case find_available_provider(state, 0) do
      {:ok, provider, index} ->
        {:ok, provider, %{state | current_index: index}}

      :none ->
        {:error, :all_providers_failed}
    end
  end

  @impl true
  def handle_result(state, provider, result) do
    case result do
      {:ok, _} ->
        # Reset failure count on success
        %{
          state
          | failures: Map.put(state.failures, provider, 0),
            failure_times: Map.delete(state.failure_times, provider)
        }

      {:error, _} ->
        # Increment failure count
        current_failures = Map.get(state.failures, provider, 0)
        now = System.monotonic_time(:millisecond)

        %{
          state
          | failures: Map.put(state.failures, provider, current_failures + 1),
            failure_times: Map.put(state.failure_times, provider, now)
        }
    end
  end

  @impl true
  def next_provider(state, failed_provider, _request) do
    state = maybe_decay_failures(state)

    # Find index of failed provider
    failed_index =
      Enum.find_index(state.fallback_order, fn p -> p == failed_provider end) || 0

    # Look for next available provider after the failed one
    case find_available_provider(state, failed_index + 1) do
      {:ok, provider, index} ->
        {:ok, provider, %{state | current_index: index}}

      :none ->
        {:error, :no_more_providers}
    end
  end

  # Private functions

  defp find_available_provider(state, start_index) do
    state.fallback_order
    |> Enum.with_index()
    |> Enum.drop(start_index)
    |> Enum.find_value(:none, fn {provider, index} ->
      if provider_available?(state, provider) do
        {:ok, provider, index}
      else
        nil
      end
    end)
  end

  defp provider_available?(state, provider) do
    failures = Map.get(state.failures, provider, 0)
    failures < state.max_failures
  end

  defp maybe_decay_failures(state) do
    if state.failure_decay_ms do
      now = System.monotonic_time(:millisecond)

      decayed_failures =
        Enum.reduce(state.failures, %{}, fn {provider, count}, acc ->
          last_failure = Map.get(state.failure_times, provider, now)
          elapsed = now - last_failure

          if elapsed >= state.failure_decay_ms do
            # Fully decay - reset to 0
            Map.put(acc, provider, 0)
          else
            Map.put(acc, provider, count)
          end
        end)

      %{state | failures: decayed_failures}
    else
      state
    end
  end
end
