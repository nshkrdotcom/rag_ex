# Only compile this module if codex_sdk is available
if Code.ensure_loaded?(Codex) do
  defmodule Rag.Ai.Codex do
    @moduledoc """
    Codex/OpenAI provider implementation using codex_sdk.

    This provider supports text generation with advanced reasoning capabilities
    and structured output. It does NOT support embeddings - use Gemini for that.

    Note: This module is only available when codex_sdk is installed.

    ## Examples

        # Basic text generation
        provider = Codex.new(%{})
        {:ok, response} = Codex.generate_text(provider, "Hello!", [])

        # Structured output
        {:ok, response} = Codex.generate_text(provider, "...", output_schema: schema)

    """

    @behaviour Rag.Ai.Provider

    defstruct [:model, :thread, :reasoning_effort]

    @type t :: %__MODULE__{
            model: String.t(),
            thread: pid() | reference(),
            reasoning_effort: :low | :medium | :high
          }

    @default_model "gpt-4o"
    @max_context_tokens 128_000

    # Pricing per 1M tokens for GPT-4o
    @input_cost 2.50
    @output_cost 10.00

    @impl true
    def new(attrs) do
      model = attrs[:model] || @default_model
      reasoning_effort = attrs[:reasoning_effort] || :medium

      opts_map = %{
        model: model,
        reasoning_effort: reasoning_effort
      }

      {:ok, opts} = Codex.Options.new(opts_map)
      {:ok, thread} = Codex.start_thread(opts)

      %__MODULE__{
        model: model,
        thread: thread,
        reasoning_effort: reasoning_effort
      }
    end

    @impl true
    def generate_embeddings(_provider, _texts, _opts) do
      # Codex doesn't support embeddings - delegate to Gemini
      {:error, :not_supported}
    end

    @impl true
    def generate_text(provider, prompt, opts) do
      run_opts = build_run_opts(opts)

      if Keyword.get(opts, :stream, false) do
        case Codex.Thread.run_streamed(provider.thread, prompt, run_opts) do
          {:ok, result} ->
            {:ok, stream_to_enumerable(result)}

          {:error, _} = err ->
            err
        end
      else
        case Codex.Thread.run(provider.thread, prompt, run_opts) do
          {:ok, result} ->
            {:ok, result.final_response}

          {:error, _} = err ->
            err
        end
      end
    end

    @doc """
    Returns whether this provider supports tool calling.
    """
    @spec supports_tools?() :: boolean()
    def supports_tools?, do: true

    @doc """
    Returns whether this provider supports embeddings.
    """
    @spec supports_embeddings?() :: boolean()
    def supports_embeddings?, do: false

    @doc """
    Returns the maximum context window in tokens.
    """
    @spec max_context_tokens() :: pos_integer()
    def max_context_tokens, do: @max_context_tokens

    @doc """
    Returns the cost per 1K tokens as {input_cost, output_cost} in USD.
    """
    @spec cost_per_1k_tokens() :: {float(), float()}
    def cost_per_1k_tokens, do: {@input_cost / 1000, @output_cost / 1000}

    # Private functions

    defp build_run_opts(opts) do
      Enum.reduce(opts, [], fn
        {:output_schema, schema}, acc -> [{:output_schema, schema} | acc]
        {:max_turns, n}, acc -> [{:max_turns, n} | acc]
        {:temperature, t}, acc -> [{:temperature, t} | acc]
        _, acc -> acc
      end)
    end

    defp stream_to_enumerable(result) do
      Stream.resource(
        fn -> {result, :init} end,
        &next_stream_item/1,
        fn _ -> :ok end
      )
    end

    defp next_stream_item({result, :init}) do
      # Get raw events from streaming result
      events =
        result
        |> Codex.RunResultStreaming.raw_events()
        |> Enum.to_list()

      {extract_text_chunks(events), {result, :done}}
    end

    defp next_stream_item({_result, :done}), do: {:halt, nil}

    defp extract_text_chunks(events) do
      events
      |> Enum.filter(&match?(%Codex.Events.ItemCompleted{item: %{text: _}}, &1))
      |> Enum.map(fn event -> event.item.text end)
    end
  end
end
