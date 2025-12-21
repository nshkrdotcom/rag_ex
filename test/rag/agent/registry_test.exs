defmodule Rag.Agent.RegistryTest do
  use ExUnit.Case, async: true

  alias Rag.Agent.Registry

  # Test tools
  defmodule TestTool1 do
    @behaviour Rag.Agent.Tool

    @impl true
    def name, do: "test_tool_1"

    @impl true
    def description, do: "First test tool"

    @impl true
    def parameters, do: %{type: "object", properties: %{}}

    @impl true
    def execute(_args, _context), do: {:ok, "result1"}
  end

  defmodule TestTool2 do
    @behaviour Rag.Agent.Tool

    @impl true
    def name, do: "test_tool_2"

    @impl true
    def description, do: "Second test tool"

    @impl true
    def parameters do
      %{
        type: "object",
        properties: %{
          query: %{type: "string"}
        },
        required: ["query"]
      }
    end

    @impl true
    def execute(%{"query" => q}, _context), do: {:ok, "Found: #{q}"}
  end

  describe "new/1" do
    test "creates an empty registry" do
      registry = Registry.new()

      assert Registry.count(registry) == 0
    end

    test "creates a registry with initial tools" do
      registry = Registry.new(tools: [TestTool1, TestTool2])

      assert Registry.count(registry) == 2
    end
  end

  describe "register/2" do
    test "adds a tool to the registry" do
      registry =
        Registry.new()
        |> Registry.register(TestTool1)

      assert Registry.count(registry) == 1
    end

    test "returns updated registry" do
      registry = Registry.new()
      updated = Registry.register(registry, TestTool1)

      refute registry == updated
      assert Registry.count(updated) == 1
    end

    test "allows registering multiple tools" do
      registry =
        Registry.new()
        |> Registry.register(TestTool1)
        |> Registry.register(TestTool2)

      assert Registry.count(registry) == 2
    end

    test "replaces tool with same name" do
      registry =
        Registry.new()
        |> Registry.register(TestTool1)
        |> Registry.register(TestTool1)

      assert Registry.count(registry) == 1
    end
  end

  describe "register_all/2" do
    test "registers multiple tools at once" do
      registry = Registry.register_all(Registry.new(), [TestTool1, TestTool2])

      assert Registry.count(registry) == 2
    end
  end

  describe "get/2" do
    test "retrieves tool by name" do
      registry = Registry.new(tools: [TestTool1, TestTool2])

      assert {:ok, TestTool1} = Registry.get(registry, "test_tool_1")
    end

    test "returns error for unknown tool" do
      registry = Registry.new(tools: [TestTool1])

      assert {:error, :not_found} = Registry.get(registry, "unknown")
    end
  end

  describe "list/1" do
    test "returns all registered tools" do
      registry = Registry.new(tools: [TestTool1, TestTool2])

      tools = Registry.list(registry)

      assert length(tools) == 2
      assert TestTool1 in tools
      assert TestTool2 in tools
    end

    test "returns empty list for empty registry" do
      registry = Registry.new()

      assert Registry.list(registry) == []
    end
  end

  describe "names/1" do
    test "returns all tool names" do
      registry = Registry.new(tools: [TestTool1, TestTool2])

      names = Registry.names(registry)

      assert length(names) == 2
      assert "test_tool_1" in names
      assert "test_tool_2" in names
    end
  end

  describe "has_tool?/2" do
    test "returns true for registered tool" do
      registry = Registry.new(tools: [TestTool1])

      assert Registry.has_tool?(registry, "test_tool_1")
    end

    test "returns false for unknown tool" do
      registry = Registry.new(tools: [TestTool1])

      refute Registry.has_tool?(registry, "unknown")
    end
  end

  describe "unregister/2" do
    test "removes tool from registry" do
      registry =
        Registry.new(tools: [TestTool1, TestTool2])
        |> Registry.unregister("test_tool_1")

      assert Registry.count(registry) == 1
      refute Registry.has_tool?(registry, "test_tool_1")
    end

    test "does nothing for unknown tool" do
      registry = Registry.new(tools: [TestTool1])
      updated = Registry.unregister(registry, "unknown")

      assert Registry.count(updated) == 1
    end
  end

  describe "format_for_llm/1" do
    test "formats all tools for LLM" do
      registry = Registry.new(tools: [TestTool1, TestTool2])

      formatted = Registry.format_for_llm(registry)

      assert length(formatted) == 2
      names = Enum.map(formatted, & &1.name)
      assert "test_tool_1" in names
      assert "test_tool_2" in names
    end
  end

  describe "execute/4" do
    test "executes tool by name" do
      registry = Registry.new(tools: [TestTool1, TestTool2])

      result = Registry.execute(registry, "test_tool_1", %{}, %{})

      assert {:ok, "result1"} = result
    end

    test "passes args and context to tool" do
      registry = Registry.new(tools: [TestTool2])

      result = Registry.execute(registry, "test_tool_2", %{"query" => "hello"}, %{})

      assert {:ok, "Found: hello"} = result
    end

    test "returns error for unknown tool" do
      registry = Registry.new(tools: [TestTool1])

      result = Registry.execute(registry, "unknown", %{}, %{})

      assert {:error, {:tool_not_found, "unknown"}} = result
    end
  end

  describe "filter/2" do
    test "filters tools by predicate" do
      registry = Registry.new(tools: [TestTool1, TestTool2])

      filtered =
        Registry.filter(registry, fn tool ->
          tool.name() == "test_tool_1"
        end)

      assert Registry.count(filtered) == 1
      assert Registry.has_tool?(filtered, "test_tool_1")
    end
  end
end
