defmodule Rag.Router.RoundRobin do
  @moduledoc """
  Round-Robin routing strategy.

  Distributes requests evenly across providers. Supports optional
  weights for uneven distribution and automatic provider recovery.

  ## Configuration

      RoundRobin.init(
        providers: [:gemini, :codex, :claude],
        weights: %{gemini: 3, codex: 2, claude: 1},  # Optional weighted distribution
        max_consecutive_failures: 3,                  # Mark unavailable after N failures
        recovery_cooldown_ms: 30_000                  # Retry unavailable after 30s
      )

  ## Behavior

  1. Selects providers in rotating order
  2. Optionally applies weights (higher weight = more selections)
  3. Skips temporarily unavailable providers
  4. Automatically recovers providers after cooldown

  ## Weighted Distribution

  With weights `{gemini: 2, codex: 1}`, the selection pattern is:
  gemini → gemini → codex → gemini → gemini → codex → ...

  """

  @behaviour Rag.Router.Strategy

  defstruct [
    :providers,
    :weights,
    :max_consecutive_failures,
    :recovery_cooldown_ms,
    current_index: 0,
    weight_counters: %{},
    consecutive_failures: %{},
    unavailable: MapSet.new(),
    unavailable_since: %{}
  ]

  @type t :: %__MODULE__{
          providers: [atom()],
          weights: %{atom() => pos_integer()} | nil,
          max_consecutive_failures: pos_integer(),
          recovery_cooldown_ms: pos_integer(),
          current_index: non_neg_integer(),
          weight_counters: %{atom() => non_neg_integer()},
          consecutive_failures: %{atom() => non_neg_integer()},
          unavailable: MapSet.t(atom()),
          unavailable_since: %{atom() => integer()}
        }

  @default_max_consecutive_failures 3
  @default_recovery_cooldown_ms 30_000

  @impl true
  def init(opts) do
    providers = Keyword.get(opts, :providers, [])

    if providers == [] do
      {:error, :no_providers}
    else
      weights = Keyword.get(opts, :weights)

      max_failures =
        Keyword.get(opts, :max_consecutive_failures, @default_max_consecutive_failures)

      recovery_ms = Keyword.get(opts, :recovery_cooldown_ms, @default_recovery_cooldown_ms)

      # Initialize weight counters
      weight_counters =
        if weights do
          Map.new(providers, fn p -> {p, Map.get(weights, p, 1)} end)
        else
          %{}
        end

      {:ok,
       %__MODULE__{
         providers: providers,
         weights: weights,
         max_consecutive_failures: max_failures,
         recovery_cooldown_ms: recovery_ms,
         weight_counters: weight_counters,
         consecutive_failures: %{},
         unavailable: MapSet.new(),
         unavailable_since: %{}
       }}
    end
  end

  @impl true
  def select_provider(state, _request) do
    state = maybe_recover_providers(state)
    available = get_available_providers(state)

    if Enum.empty?(available) do
      {:error, :all_providers_unavailable}
    else
      if state.weights do
        select_weighted(state, available)
      else
        select_simple(state, available)
      end
    end
  end

  @impl true
  def handle_result(state, provider, result) do
    case result do
      {:ok, _} ->
        # Reset failure count on success
        %{state | consecutive_failures: Map.put(state.consecutive_failures, provider, 0)}

      {:error, _} ->
        current_failures = Map.get(state.consecutive_failures, provider, 0) + 1

        state = %{
          state
          | consecutive_failures: Map.put(state.consecutive_failures, provider, current_failures)
        }

        # Mark unavailable if too many failures
        if current_failures >= state.max_consecutive_failures do
          now = System.monotonic_time(:millisecond)

          %{
            state
            | unavailable: MapSet.put(state.unavailable, provider),
              unavailable_since: Map.put(state.unavailable_since, provider, now)
          }
        else
          state
        end
    end
  end

  @impl true
  def next_provider(state, failed_provider, _request) do
    state = maybe_recover_providers(state)
    available = get_available_providers(state)

    if Enum.empty?(available) do
      {:error, :no_more_providers}
    else
      # Find the index of the failed provider and get the next one
      failed_index = Enum.find_index(state.providers, &(&1 == failed_provider)) || 0
      provider_count = length(state.providers)

      result =
        Enum.find_value(1..(provider_count - 1), fn offset ->
          index = rem(failed_index + offset, provider_count)
          provider = Enum.at(state.providers, index)

          if provider in available do
            {provider, index}
          else
            nil
          end
        end)

      case result do
        {provider, index} ->
          new_index = rem(index + 1, provider_count)
          {:ok, provider, %{state | current_index: new_index}}

        nil ->
          {:error, :no_more_providers}
      end
    end
  end

  # Private functions

  defp select_simple(state, available) do
    # Find next available provider starting from current index
    provider_count = length(state.providers)

    result =
      Enum.find_value(0..(provider_count - 1), fn offset ->
        index = rem(state.current_index + offset, provider_count)
        provider = Enum.at(state.providers, index)

        if provider in available do
          {provider, index}
        else
          nil
        end
      end)

    case result do
      {provider, index} ->
        new_index = rem(index + 1, provider_count)
        {:ok, provider, %{state | current_index: new_index}}

      nil ->
        {:error, :all_providers_unavailable}
    end
  end

  defp select_weighted(state, available) do
    # Find provider with remaining weight counter > 0
    {provider, new_counters} =
      next_weighted_provider(state.weight_counters, available, state.weights)

    case provider do
      nil ->
        {:error, :all_providers_unavailable}

      p ->
        {:ok, p, %{state | weight_counters: new_counters}}
    end
  end

  defp next_weighted_provider(counters, available, weights) do
    # Find first available provider with counter > 0
    available_with_counter =
      Enum.find(available, fn p ->
        Map.get(counters, p, 0) > 0
      end)

    case available_with_counter do
      nil ->
        # All counters exhausted, reset them
        reset_counters = Map.new(available, fn p -> {p, Map.get(weights, p, 1)} end)
        next_weighted_provider(reset_counters, available, weights)

      provider ->
        new_counters = Map.update!(counters, provider, &(&1 - 1))
        {provider, new_counters}
    end
  rescue
    # Guard against infinite recursion if no providers available
    _ -> {nil, counters}
  end

  defp get_available_providers(state) do
    Enum.reject(state.providers, fn p ->
      MapSet.member?(state.unavailable, p)
    end)
  end

  defp maybe_recover_providers(state) do
    now = System.monotonic_time(:millisecond)

    recovered =
      state.unavailable
      |> Enum.filter(fn provider ->
        since = Map.get(state.unavailable_since, provider, now)
        now - since >= state.recovery_cooldown_ms
      end)
      |> MapSet.new()

    if MapSet.size(recovered) > 0 do
      %{
        state
        | unavailable: MapSet.difference(state.unavailable, recovered),
          unavailable_since: Map.drop(state.unavailable_since, MapSet.to_list(recovered)),
          consecutive_failures: Map.drop(state.consecutive_failures, MapSet.to_list(recovered))
      }
    else
      state
    end
  end
end
