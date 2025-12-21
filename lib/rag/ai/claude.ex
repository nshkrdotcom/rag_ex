# Only compile this module if claude_agent_sdk is available
if Code.ensure_loaded?(ClaudeAgentSDK) do
  defmodule Rag.Ai.Claude do
    @moduledoc """
    Claude provider implementation using claude_agent_sdk.

    This provider excels at analysis, writing, and agentic workflows with
    strong safety guarantees. It does NOT support embeddings - use Gemini for that.

    Note: This module is only available when claude_agent_sdk is installed.

    ## Examples

        # Basic text generation
        provider = Claude.new(%{})
        {:ok, response} = Claude.generate_text(provider, "Hello!", [])

        # With system prompt
        {:ok, response} = Claude.generate_text(
          provider,
          "Analyze this code",
          system_prompt: "You are an expert code reviewer"
        )

    """

    @behaviour Rag.Ai.Provider

    defstruct [:model, :options, :session]

    @type t :: %__MODULE__{
            model: String.t(),
            options: map(),
            session: term() | nil
          }

    @default_model "claude-sonnet-4-20250514"
    @max_context_tokens 200_000

    # Pricing per 1M tokens for Claude Sonnet 4
    @input_cost 3.00
    @output_cost 15.00

    @impl true
    def new(attrs) do
      model = attrs[:model] || @default_model

      opts =
        ClaudeAgentSDK.Options.new(
          model: model,
          max_turns: attrs[:max_turns] || 10,
          permission_mode: attrs[:permission_mode] || :default
        )

      %__MODULE__{
        model: model,
        options: opts,
        session: nil
      }
    end

    @impl true
    def generate_embeddings(_provider, _texts, _opts) do
      # Claude doesn't support embeddings - delegate to Gemini
      {:error, :not_supported}
    end

    @impl true
    def generate_text(provider, prompt, opts) do
      query_opts = build_query_opts(provider.options, opts)

      if Keyword.get(opts, :stream, false) do
        {:ok, stream_query(prompt, query_opts)}
      else
        # Collect stream into single response
        result =
          prompt
          |> ClaudeAgentSDK.query(query_opts)
          |> Enum.filter(&(&1.role == :assistant))
          |> Enum.map(& &1.content)
          |> Enum.join("")

        {:ok, result}
      end
    rescue
      e ->
        {:error, Exception.message(e)}
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

    defp build_query_opts(base_opts, opts) do
      base_opts
      |> Map.put(:system_prompt, Keyword.get(opts, :system_prompt))
      |> Map.put(:output_format, Keyword.get(opts, :output_format, :text))
    end

    defp stream_query(prompt, opts) do
      Stream.resource(
        fn -> ClaudeAgentSDK.query(prompt, opts) end,
        &next_message/1,
        fn _ -> :ok end
      )
    end

    defp next_message(stream) do
      case Enum.take(stream, 1) do
        [msg] when msg.role == :assistant ->
          {[msg.content], Stream.drop(stream, 1)}

        [_msg] ->
          # Skip non-assistant messages
          next_message(Stream.drop(stream, 1))

        [] ->
          {:halt, stream}
      end
    rescue
      _ -> {:halt, stream}
    end
  end
end
