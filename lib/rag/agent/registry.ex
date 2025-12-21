defmodule Rag.Agent.Registry do
  @moduledoc """
  Tool registry for managing available agent tools.

  The registry maintains a collection of tools that can be used by agents.
  It provides functions for registering, looking up, and executing tools.

  ## Usage

      # Create a registry with initial tools
      registry = Registry.new(tools: [SearchTool, ReadFileTool])

      # Register additional tools
      registry = Registry.register(registry, AnalyzeTool)

      # Execute a tool
      {:ok, result} = Registry.execute(registry, "search", %{"query" => "test"}, context)

  """

  alias Rag.Agent.Tool

  defstruct tools: %{}

  @type t :: %__MODULE__{
          tools: %{String.t() => module()}
        }

  @doc """
  Creates a new tool registry.

  ## Options

  - `:tools` - List of tool modules to register initially

  ## Examples

      iex> Registry.new()
      %Registry{tools: %{}}

      iex> Registry.new(tools: [MyTool])
      %Registry{tools: %{"my_tool" => MyTool}}

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    register_all(%__MODULE__{}, tools)
  end

  @doc """
  Registers a tool in the registry.

  If a tool with the same name already exists, it will be replaced.

  ## Examples

      iex> registry |> Registry.register(MyTool)
      %Registry{tools: %{"my_tool" => MyTool}}

  """
  @spec register(t(), module()) :: t()
  def register(%__MODULE__{} = registry, tool_module) do
    name = tool_module.name()
    %{registry | tools: Map.put(registry.tools, name, tool_module)}
  end

  @doc """
  Registers multiple tools at once.

  ## Examples

      iex> Registry.register_all(registry, [Tool1, Tool2])
      %Registry{tools: %{"tool1" => Tool1, "tool2" => Tool2}}

  """
  @spec register_all(t(), [module()]) :: t()
  def register_all(%__MODULE__{} = registry, tool_modules) do
    Enum.reduce(tool_modules, registry, &register(&2, &1))
  end

  @doc """
  Gets a tool by name.

  ## Examples

      iex> Registry.get(registry, "my_tool")
      {:ok, MyTool}

      iex> Registry.get(registry, "unknown")
      {:error, :not_found}

  """
  @spec get(t(), String.t()) :: {:ok, module()} | {:error, :not_found}
  def get(%__MODULE__{} = registry, name) do
    case Map.get(registry.tools, name) do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end

  @doc """
  Lists all registered tool modules.

  ## Examples

      iex> Registry.list(registry)
      [Tool1, Tool2]

  """
  @spec list(t()) :: [module()]
  def list(%__MODULE__{} = registry) do
    Map.values(registry.tools)
  end

  @doc """
  Lists all registered tool names.

  ## Examples

      iex> Registry.names(registry)
      ["tool1", "tool2"]

  """
  @spec names(t()) :: [String.t()]
  def names(%__MODULE__{} = registry) do
    Map.keys(registry.tools)
  end

  @doc """
  Returns the number of registered tools.

  ## Examples

      iex> Registry.count(registry)
      2

  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{} = registry) do
    map_size(registry.tools)
  end

  @doc """
  Checks if a tool is registered.

  ## Examples

      iex> Registry.has_tool?(registry, "my_tool")
      true

  """
  @spec has_tool?(t(), String.t()) :: boolean()
  def has_tool?(%__MODULE__{} = registry, name) do
    Map.has_key?(registry.tools, name)
  end

  @doc """
  Unregisters a tool by name.

  ## Examples

      iex> Registry.unregister(registry, "my_tool")
      %Registry{...}

  """
  @spec unregister(t(), String.t()) :: t()
  def unregister(%__MODULE__{} = registry, name) do
    %{registry | tools: Map.delete(registry.tools, name)}
  end

  @doc """
  Formats all tools for LLM function calling.

  ## Examples

      iex> Registry.format_for_llm(registry)
      [%{name: "tool1", description: "...", parameters: %{...}}, ...]

  """
  @spec format_for_llm(t()) :: [map()]
  def format_for_llm(%__MODULE__{} = registry) do
    registry
    |> list()
    |> Tool.format_all_for_llm()
  end

  @doc """
  Executes a tool by name.

  ## Examples

      iex> Registry.execute(registry, "my_tool", %{"input" => "test"}, %{})
      {:ok, "result"}

      iex> Registry.execute(registry, "unknown", %{}, %{})
      {:error, {:tool_not_found, "unknown"}}

  """
  @spec execute(t(), String.t(), map(), map()) :: {:ok, term()} | {:error, term()}
  def execute(%__MODULE__{} = registry, name, args, context) do
    case get(registry, name) do
      {:ok, tool} ->
        Tool.execute(tool, args, context)

      {:error, :not_found} ->
        {:error, {:tool_not_found, name}}
    end
  end

  @doc """
  Filters tools by a predicate function.

  ## Examples

      iex> Registry.filter(registry, fn tool -> tool.name() == "my_tool" end)
      %Registry{...}

  """
  @spec filter(t(), (module() -> boolean())) :: t()
  def filter(%__MODULE__{} = registry, predicate) do
    filtered =
      registry.tools
      |> Enum.filter(fn {_name, tool} -> predicate.(tool) end)
      |> Map.new()

    %{registry | tools: filtered}
  end
end
