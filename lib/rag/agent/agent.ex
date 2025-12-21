defmodule Rag.Agent.Agent do
  @moduledoc """
  Core agent module for agentic RAG workflows.

  The agent orchestrates LLM interactions with tool usage, maintaining
  conversation history and context across multiple turns.

  ## Features

  - Multi-turn conversation with session management
  - Tool calling with automatic execution
  - Configurable iteration limits
  - Context management for stateful interactions

  ## Usage

      # Create an agent with tools
      agent = Agent.new(tools: [SearchTool, ReadFileTool])

      # Process a query
      {:ok, response, agent} = Agent.process(agent, "What is this project about?")

      # Process with tool support
      {:ok, response, agent} = Agent.process_with_tools(agent, "Find the main module")

  ## Tool Calling

  When using `process_with_tools/2`, the agent will:
  1. Send the query to the LLM with available tools
  2. If the LLM requests a tool, execute it
  3. Send the tool result back to the LLM
  4. Repeat until the LLM provides a final answer or max iterations reached

  """

  alias Rag.Agent.{Session, Registry}
  alias Rag.Ai.Gemini

  defstruct [:session, :registry, :provider, :max_iterations]

  @type t :: %__MODULE__{
          session: Session.t(),
          registry: Registry.t(),
          provider: struct(),
          max_iterations: pos_integer()
        }

  @default_max_iterations 10

  @doc """
  Creates a new agent.

  ## Options

  - `:tools` - List of tool modules to register
  - `:session` - Existing session to use (creates new if not provided)
  - `:provider` - LLM provider to use (default: Gemini)
  - `:max_iterations` - Maximum tool execution iterations (default: 10)

  ## Examples

      iex> Agent.new()
      %Agent{...}

      iex> Agent.new(tools: [SearchTool], max_iterations: 5)
      %Agent{...}

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    session = Keyword.get(opts, :session) || Session.new()
    provider = Keyword.get(opts, :provider) || Gemini.new(%{})
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)

    registry = Registry.new(tools: tools)

    %__MODULE__{
      session: session,
      registry: registry,
      provider: provider,
      max_iterations: max_iterations
    }
  end

  @doc """
  Processes a query with simple LLM interaction (no tools).

  ## Examples

      iex> {:ok, response, agent} = Agent.process(agent, "Hello!")
      {:ok, "Hi there!", %Agent{...}}

  """
  @spec process(t(), String.t()) :: {:ok, String.t(), t()} | {:error, term()}
  def process(%__MODULE__{} = agent, query) do
    agent = update_session(agent, &Session.add_message(&1, :user, query))

    prompt = build_prompt(agent)

    case call_llm(agent, prompt) do
      {:ok, response} ->
        agent = update_session(agent, &Session.add_message(&1, :assistant, response))
        {:ok, response, agent}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Processes a query with tool support.

  The agent will iteratively call tools until the LLM provides
  a final answer or max_iterations is reached.

  ## Examples

      iex> {:ok, response, agent} = Agent.process_with_tools(agent, "Find files")
      {:ok, "Found 3 files: ...", %Agent{...}}

  """
  @spec process_with_tools(t(), String.t()) :: {:ok, String.t(), t()} | {:error, term()}
  def process_with_tools(%__MODULE__{} = agent, query) do
    agent = update_session(agent, &Session.add_message(&1, :user, query))
    process_loop(agent, 0)
  end

  @doc """
  Parses an LLM response to check for tool calls.

  Returns `{:ok, tool_name, args}` if a tool call is detected,
  or `{:none, response}` for regular responses.

  """
  @spec parse_tool_call(String.t()) :: {:ok, String.t(), map()} | {:none, String.t()}
  def parse_tool_call(response) do
    case Jason.decode(response) do
      {:ok, %{"tool" => tool, "args" => args}} when is_binary(tool) and is_map(args) ->
        {:ok, tool, args}

      {:ok, %{"tool" => tool}} when is_binary(tool) ->
        {:ok, tool, %{}}

      _ ->
        {:none, response}
    end
  end

  @doc """
  Executes a tool by name.

  ## Examples

      iex> Agent.execute_tool(registry, "search", %{"query" => "test"}, %{})
      {:ok, [...results...]}

  """
  @spec execute_tool(Registry.t(), String.t(), map(), map()) ::
          {:ok, term()} | {:error, term()}
  def execute_tool(registry, tool_name, args, context) do
    Registry.execute(registry, tool_name, args, context)
  end

  @doc """
  Adds context to the agent's session.

  ## Examples

      iex> agent |> Agent.with_context(:repo, "my_app")
      %Agent{...}

  """
  @spec with_context(t(), atom(), term()) :: t()
  def with_context(%__MODULE__{} = agent, key, value) do
    update_session(agent, &Session.set_context(&1, key, value))
  end

  @doc """
  Returns the message history from the session.
  """
  @spec get_history(t()) :: [Session.message()]
  def get_history(%__MODULE__{session: session}) do
    Session.messages(session)
  end

  @doc """
  Clears the message history.
  """
  @spec clear_history(t()) :: t()
  def clear_history(%__MODULE__{} = agent) do
    update_session(agent, &Session.clear_messages/1)
  end

  # Private functions

  defp process_loop(agent, iteration) when iteration >= agent.max_iterations do
    {:error, :max_iterations_exceeded}
  end

  defp process_loop(agent, iteration) do
    prompt = build_prompt_with_tools(agent)

    case call_llm(agent, prompt) do
      {:ok, response} ->
        case parse_tool_call(response) do
          {:ok, tool_name, args} ->
            # Execute tool and continue loop
            context = Session.context(agent.session)
            result = execute_tool(agent.registry, tool_name, args, context)

            agent = update_session(agent, &Session.add_tool_result(&1, tool_name, result))
            process_loop(agent, iteration + 1)

          {:none, final_response} ->
            # No tool call - this is the final response
            agent = update_session(agent, &Session.add_message(&1, :assistant, final_response))
            {:ok, final_response, agent}
        end

      {:error, _} = error ->
        error
    end
  end

  defp build_prompt(agent) do
    messages = Session.to_llm_messages(agent.session)

    messages
    |> Enum.map(fn msg ->
      "#{msg.role}: #{msg.content}"
    end)
    |> Enum.join("\n\n")
  end

  defp build_prompt_with_tools(agent) do
    base_prompt = build_prompt(agent)
    tools = Registry.format_for_llm(agent.registry)

    if tools == [] do
      base_prompt
    else
      tool_descriptions =
        tools
        |> Enum.map(fn t ->
          "- #{t.name}: #{t.description}"
        end)
        |> Enum.join("\n")

      """
      #{base_prompt}

      Available tools:
      #{tool_descriptions}

      To use a tool, respond with JSON: {"tool": "tool_name", "args": {...}}
      Otherwise, respond normally with your answer.
      """
    end
  end

  defp call_llm(agent, prompt) do
    provider = agent.provider
    provider.__struct__.generate_text(provider, prompt, [])
  end

  defp update_session(agent, fun) do
    %{agent | session: fun.(agent.session)}
  end
end
