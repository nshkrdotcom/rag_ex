defmodule Rag.Router.Specialist do
  @moduledoc """
  Specialist routing strategy.

  Routes requests to the best provider for each task type. Uses
  task mappings to determine which provider handles what, with
  optional inference from prompt content.

  ## Configuration

      Specialist.init(
        providers: [:gemini, :codex, :claude],
        task_mappings: %{
          embeddings: :gemini,
          code_generation: :codex,
          analysis: :claude
        },
        fallback_provider: :gemini,
        max_failures: 3
      )

  ## Default Task Mappings

  - `:embeddings` → `:gemini` (only provider with embedding support)
  - `:code_generation` → `:codex` (optimized for code)
  - `:code_review` → `:codex`
  - `:structured_output` → `:codex`
  - `:analysis` → `:claude` (best for deep analysis)
  - `:writing` → `:claude`
  - `:agentic` → `:claude`
  - `:reasoning` → `:claude`
  - `:long_context` → `:gemini` (1M token context)
  - `:multimodal` → `:gemini`

  ## Task Inference

  If no explicit task is provided, the strategy can infer the task
  from the prompt content using keyword detection:

  - Code keywords: "write", "implement", "create function", "code"
  - Analysis keywords: "analyze", "explain", "review", "compare"

  """

  @behaviour Rag.Router.Strategy

  defstruct [
    :providers,
    :task_mappings,
    :fallback_provider,
    :max_failures,
    failures: %{},
    unavailable: MapSet.new()
  ]

  @type t :: %__MODULE__{
          providers: [atom()],
          task_mappings: %{atom() => atom()},
          fallback_provider: atom(),
          max_failures: pos_integer(),
          failures: %{atom() => non_neg_integer()},
          unavailable: MapSet.t(atom())
        }

  @default_task_mappings %{
    # Gemini specialties
    embeddings: :gemini,
    long_context: :gemini,
    multimodal: :gemini,
    cost: :gemini,
    speed: :gemini,

    # Codex specialties
    code_generation: :codex,
    code_review: :codex,
    structured_output: :codex,

    # Claude specialties
    analysis: :claude,
    writing: :claude,
    agentic: :claude,
    reasoning: :claude,
    safety: :claude
  }

  @default_max_failures 3

  # Keywords for task inference
  @code_keywords ~w(write implement create function code develop build make generate class method api endpoint)
  @analysis_keywords ~w(analyze explain review compare understand describe examine evaluate assess)

  @impl true
  def init(opts) do
    providers = Keyword.get(opts, :providers, [])

    if providers == [] do
      {:error, :no_providers}
    else
      custom_mappings = Keyword.get(opts, :task_mappings, %{})
      task_mappings = Map.merge(@default_task_mappings, custom_mappings)
      fallback = Keyword.get(opts, :fallback_provider, List.first(providers))
      max_failures = Keyword.get(opts, :max_failures, @default_max_failures)

      {:ok,
       %__MODULE__{
         providers: providers,
         task_mappings: task_mappings,
         fallback_provider: fallback,
         max_failures: max_failures,
         failures: %{},
         unavailable: MapSet.new()
       }}
    end
  end

  @impl true
  def select_provider(state, request) do
    available = get_available_providers(state)

    if Enum.empty?(available) do
      {:error, :all_providers_unavailable}
    else
      task = determine_task(request)
      preferred = Map.get(state.task_mappings, task)

      provider =
        cond do
          preferred && preferred in available ->
            preferred

          state.fallback_provider in available ->
            state.fallback_provider

          true ->
            List.first(available)
        end

      {:ok, provider, state}
    end
  end

  @impl true
  def handle_result(state, provider, result) do
    case result do
      {:ok, _} ->
        %{state | failures: Map.put(state.failures, provider, 0)}

      {:error, _} ->
        current_failures = Map.get(state.failures, provider, 0) + 1
        state = %{state | failures: Map.put(state.failures, provider, current_failures)}

        if current_failures >= state.max_failures do
          %{state | unavailable: MapSet.put(state.unavailable, provider)}
        else
          state
        end
    end
  end

  @impl true
  def next_provider(state, failed_provider, _request) do
    available =
      get_available_providers(state)
      |> Enum.reject(&(&1 == failed_provider))

    cond do
      Enum.empty?(available) ->
        {:error, :no_more_providers}

      state.fallback_provider in available ->
        {:ok, state.fallback_provider, state}

      true ->
        {:ok, List.first(available), state}
    end
  end

  # Private functions

  defp get_available_providers(state) do
    Enum.reject(state.providers, fn p ->
      MapSet.member?(state.unavailable, p)
    end)
  end

  defp determine_task(request) do
    # First check explicit task in opts
    explicit_task = Keyword.get(request.opts || [], :task)

    cond do
      explicit_task != nil ->
        explicit_task

      request.type == :embeddings ->
        :embeddings

      is_binary(request.prompt) ->
        infer_task_from_prompt(request.prompt)

      true ->
        :general
    end
  end

  defp infer_task_from_prompt(prompt) do
    prompt_lower = String.downcase(prompt)

    # Check analysis first - these keywords indicate understanding/reviewing
    # rather than creating new code
    cond do
      contains_keywords?(prompt_lower, @analysis_keywords) ->
        :analysis

      contains_keywords?(prompt_lower, @code_keywords) ->
        :code_generation

      true ->
        :general
    end
  end

  defp contains_keywords?(text, keywords) do
    Enum.any?(keywords, fn keyword ->
      String.contains?(text, keyword)
    end)
  end
end
