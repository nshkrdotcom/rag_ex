defmodule Rag.Agent.ToolTest do
  use ExUnit.Case, async: true

  alias Rag.Agent.Tool

  # Define a test tool for testing the behaviour
  defmodule EchoTool do
    @behaviour Rag.Agent.Tool

    @impl true
    def name, do: "echo"

    @impl true
    def description, do: "Echoes the input message back"

    @impl true
    def parameters do
      %{
        type: "object",
        properties: %{
          message: %{type: "string", description: "The message to echo"}
        },
        required: ["message"]
      }
    end

    @impl true
    def execute(%{"message" => message}, _context) do
      {:ok, "Echo: #{message}"}
    end

    def execute(%{message: message}, context) do
      execute(%{"message" => message}, context)
    end

    def execute(_args, _context) do
      {:error, :missing_message}
    end
  end

  defmodule FailingTool do
    @behaviour Rag.Agent.Tool

    @impl true
    def name, do: "failing"

    @impl true
    def description, do: "A tool that always fails"

    @impl true
    def parameters, do: %{type: "object", properties: %{}}

    @impl true
    def execute(_args, _context) do
      {:error, "Something went wrong"}
    end
  end

  defmodule ContextAwareTool do
    @behaviour Rag.Agent.Tool

    @impl true
    def name, do: "context_aware"

    @impl true
    def description, do: "A tool that uses context"

    @impl true
    def parameters do
      %{
        type: "object",
        properties: %{
          key: %{type: "string", description: "Context key to retrieve"}
        },
        required: ["key"]
      }
    end

    @impl true
    def execute(%{"key" => key}, context) do
      case Map.get(context, key) || Map.get(context, String.to_atom(key)) do
        nil -> {:error, :not_found}
        value -> {:ok, value}
      end
    end
  end

  describe "behaviour implementation" do
    test "tool implements name/0" do
      assert EchoTool.name() == "echo"
    end

    test "tool implements description/0" do
      assert EchoTool.description() == "Echoes the input message back"
    end

    test "tool implements parameters/0" do
      params = EchoTool.parameters()

      assert params.type == "object"
      assert Map.has_key?(params.properties, :message)
      assert "message" in params.required
    end

    test "tool implements execute/2 with success" do
      result = EchoTool.execute(%{"message" => "Hello"}, %{})

      assert {:ok, "Echo: Hello"} = result
    end

    test "tool implements execute/2 with error" do
      result = FailingTool.execute(%{}, %{})

      assert {:error, "Something went wrong"} = result
    end
  end

  describe "Tool.to_spec/1" do
    test "converts tool module to specification map" do
      spec = Tool.to_spec(EchoTool)

      assert spec.name == "echo"
      assert spec.description == "Echoes the input message back"
      assert spec.parameters.type == "object"
    end

    test "includes all required fields" do
      spec = Tool.to_spec(EchoTool)

      assert Map.has_key?(spec, :name)
      assert Map.has_key?(spec, :description)
      assert Map.has_key?(spec, :parameters)
    end
  end

  describe "Tool.execute/3" do
    test "executes tool and returns result" do
      result = Tool.execute(EchoTool, %{"message" => "test"}, %{})

      assert {:ok, "Echo: test"} = result
    end

    test "passes context to tool" do
      context = %{user_id: "123", session: "abc"}
      result = Tool.execute(ContextAwareTool, %{"key" => "user_id"}, context)

      assert {:ok, "123"} = result
    end

    test "returns error when tool fails" do
      result = Tool.execute(FailingTool, %{}, %{})

      assert {:error, "Something went wrong"} = result
    end
  end

  describe "Tool.validate_args/2" do
    test "returns ok for valid arguments" do
      result = Tool.validate_args(EchoTool, %{"message" => "hello"})

      assert :ok = result
    end

    test "returns error for missing required field" do
      result = Tool.validate_args(EchoTool, %{})

      assert {:error, {:missing_required, ["message"]}} = result
    end

    test "returns ok when no required fields" do
      result = Tool.validate_args(FailingTool, %{})

      assert :ok = result
    end
  end

  describe "Tool.format_for_llm/1" do
    test "formats tool for LLM function calling" do
      formatted = Tool.format_for_llm(EchoTool)

      assert formatted.name == "echo"
      assert formatted.description == "Echoes the input message back"
      assert is_map(formatted.parameters)
    end

    test "formats multiple tools" do
      tools = [EchoTool, FailingTool, ContextAwareTool]
      formatted = Enum.map(tools, &Tool.format_for_llm/1)

      assert length(formatted) == 3
      names = Enum.map(formatted, & &1.name)
      assert "echo" in names
      assert "failing" in names
      assert "context_aware" in names
    end
  end
end
