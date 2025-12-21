defmodule Rag.Agent.Tool do
  @moduledoc """
  Behaviour for agent tools.

  Tools are functions that agents can call to interact with external
  systems, retrieve information, or perform actions. Each tool must
  implement this behaviour.

  ## Implementing a Tool

      defmodule MyTool do
        @behaviour Rag.Agent.Tool

        @impl true
        def name, do: "my_tool"

        @impl true
        def description, do: "Does something useful"

        @impl true
        def parameters do
          %{
            type: "object",
            properties: %{
              input: %{type: "string", description: "The input"}
            },
            required: ["input"]
          }
        end

        @impl true
        def execute(%{"input" => input}, context) do
          # Perform the action
          {:ok, "Result: \#{input}"}
        end
      end

  ## Context

  The context map passed to `execute/2` contains:
  - `:session_id` - Current session identifier
  - `:user_id` - User identifier (if available)
  - `:repo` - Ecto repo for database operations
  - `:router` - Router for LLM calls
  - Any additional context provided by the agent

  """

  @type args :: map()
  @type context :: map()
  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  Returns the unique name of the tool.
  """
  @callback name() :: String.t()

  @doc """
  Returns a description of what the tool does.
  This is shown to the LLM to help it decide when to use the tool.
  """
  @callback description() :: String.t()

  @doc """
  Returns the JSON Schema for the tool's parameters.
  """
  @callback parameters() :: map()

  @doc """
  Executes the tool with the given arguments and context.
  """
  @callback execute(args(), context()) :: result()

  @doc """
  Converts a tool module to a specification map.

  ## Examples

      iex> Tool.to_spec(MyTool)
      %{name: "my_tool", description: "...", parameters: %{...}}

  """
  @spec to_spec(module()) :: map()
  def to_spec(tool_module) do
    %{
      name: tool_module.name(),
      description: tool_module.description(),
      parameters: tool_module.parameters()
    }
  end

  @doc """
  Executes a tool with the given arguments and context.

  This is a convenience function that delegates to the tool's
  `execute/2` callback.

  ## Examples

      iex> Tool.execute(MyTool, %{"input" => "test"}, %{})
      {:ok, "Result: test"}

  """
  @spec execute(module(), args(), context()) :: result()
  def execute(tool_module, args, context) do
    tool_module.execute(args, context)
  end

  @doc """
  Validates arguments against the tool's parameter schema.

  Checks that all required fields are present.

  ## Examples

      iex> Tool.validate_args(MyTool, %{"input" => "test"})
      :ok

      iex> Tool.validate_args(MyTool, %{})
      {:error, {:missing_required, ["input"]}}

  """
  @spec validate_args(module(), args()) :: :ok | {:error, term()}
  def validate_args(tool_module, args) do
    params = tool_module.parameters()
    required = Map.get(params, :required, [])

    missing =
      required
      |> Enum.reject(fn field ->
        field_str = to_string(field)
        Map.has_key?(args, field) or Map.has_key?(args, field_str)
      end)

    if missing == [] do
      :ok
    else
      {:error, {:missing_required, missing}}
    end
  end

  @doc """
  Formats a tool for LLM function calling.

  Returns a map in the format expected by LLM providers
  for function/tool definitions.

  ## Examples

      iex> Tool.format_for_llm(MyTool)
      %{name: "my_tool", description: "...", parameters: %{...}}

  """
  @spec format_for_llm(module()) :: map()
  def format_for_llm(tool_module) do
    %{
      name: tool_module.name(),
      description: tool_module.description(),
      parameters: tool_module.parameters()
    }
  end

  @doc """
  Formats multiple tools for LLM function calling.

  ## Examples

      iex> Tool.format_all_for_llm([Tool1, Tool2])
      [%{name: "tool1", ...}, %{name: "tool2", ...}]

  """
  @spec format_all_for_llm([module()]) :: [map()]
  def format_all_for_llm(tool_modules) do
    Enum.map(tool_modules, &format_for_llm/1)
  end
end
