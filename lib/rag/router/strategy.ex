defmodule Rag.Router.Strategy do
  @moduledoc """
  Behaviour for routing strategies.

  A routing strategy determines how requests are dispatched to
  LLM providers. Strategies can implement different algorithms
  for provider selection, load balancing, and failover.

  ## Available Strategies

  - `Rag.Router.Fallback` - Try providers in order until success
  - `Rag.Router.RoundRobin` - Distribute load across providers
  - `Rag.Router.Specialist` - Route by task type to best provider
  - `Rag.Router.Consensus` - Query multiple providers, synthesize response
  - `Rag.Router.Racing` - Query all, return first response

  ## Implementing a Custom Strategy

      defmodule MyStrategy do
        @behaviour Rag.Router.Strategy

        @impl true
        def init(opts) do
          {:ok, %{providers: opts[:providers] || []}}
        end

        @impl true
        def select_provider(state, request) do
          # Return {:ok, provider, new_state} or {:error, reason}
        end

        @impl true
        def handle_result(state, provider, result) do
          # Update state after provider returns result
        end
      end

  """

  @type state :: term()
  @type provider :: atom()
  @type request :: %{
          type: :text | :embeddings,
          prompt: String.t() | [String.t()],
          opts: keyword()
        }
  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  Initialize the strategy with configuration options.

  Called once when the router starts. Returns initial state
  that will be passed to subsequent callbacks.

  ## Options

  - `:providers` - List of provider atoms (required)
  - `:fallback_order` - Order for fallback attempts
  - Strategy-specific options

  ## Returns

  - `{:ok, state}` on success
  - `{:error, reason}` on failure
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Select a provider for the given request.

  This is called for each incoming request. The strategy should
  select the most appropriate provider based on its algorithm.

  ## Parameters

  - `state` - Current strategy state
  - `request` - Request details including type and prompt

  ## Returns

  - `{:ok, provider, new_state}` - Selected provider and updated state
  - `{:error, reason}` - No provider available
  """
  @callback select_provider(state(), request()) ::
              {:ok, provider(), state()} | {:error, term()}

  @doc """
  Handle the result from a provider.

  Called after a provider returns (success or failure). Use this
  to update strategy state based on provider performance.

  ## Parameters

  - `state` - Current strategy state
  - `provider` - The provider that was used
  - `result` - The result from the provider

  ## Returns

  Updated state
  """
  @callback handle_result(state(), provider(), result()) :: state()

  @doc """
  Select the next provider after a failure (for retry strategies).

  Optional callback for strategies that support retrying with
  different providers on failure.

  ## Parameters

  - `state` - Current strategy state
  - `failed_provider` - The provider that failed
  - `request` - Original request

  ## Returns

  - `{:ok, provider, new_state}` - Next provider to try
  - `{:error, :no_more_providers}` - No more providers available
  """
  @callback next_provider(state(), provider(), request()) ::
              {:ok, provider(), state()} | {:error, :no_more_providers}

  @optional_callbacks next_provider: 3
end
