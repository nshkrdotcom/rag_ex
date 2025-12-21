defmodule Rag.Agent.AgentTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Rag.Agent.Agent
  alias Rag.Agent.Session
  alias Rag.Agent.Registry
  alias Rag.Agent.Tool

  setup :set_mimic_global
  setup :verify_on_exit!

  # Test tool for agent tests
  defmodule EchoTool do
    @behaviour Tool

    @impl true
    def name, do: "echo"

    @impl true
    def description, do: "Echoes the input"

    @impl true
    def parameters do
      %{
        type: "object",
        properties: %{message: %{type: "string"}},
        required: ["message"]
      }
    end

    @impl true
    def execute(%{"message" => msg}, _ctx), do: {:ok, "Echo: #{msg}"}
  end

  defmodule AddTool do
    @behaviour Tool

    @impl true
    def name, do: "add"

    @impl true
    def description, do: "Adds two numbers"

    @impl true
    def parameters do
      %{
        type: "object",
        properties: %{
          a: %{type: "number"},
          b: %{type: "number"}
        },
        required: ["a", "b"]
      }
    end

    @impl true
    def execute(%{"a" => a, "b" => b}, _ctx), do: {:ok, a + b}
  end

  describe "new/1" do
    test "creates an agent with default options" do
      agent = Agent.new()

      assert %Agent{} = agent
      assert agent.session != nil
      assert agent.registry != nil
    end

    test "creates an agent with custom tools" do
      agent = Agent.new(tools: [EchoTool, AddTool])

      assert Registry.has_tool?(agent.registry, "echo")
      assert Registry.has_tool?(agent.registry, "add")
    end

    test "creates an agent with existing session" do
      session = Session.new(id: "custom-session")
      agent = Agent.new(session: session)

      assert agent.session.id == "custom-session"
    end

    test "sets max_iterations" do
      agent = Agent.new(max_iterations: 5)

      assert agent.max_iterations == 5
    end
  end

  describe "process/2" do
    test "processes simple query without tool calls" do
      expect(Rag.Ai.Gemini, :generate_text, fn _provider, _prompt, _opts ->
        {:ok, "Hello! How can I help you?"}
      end)

      agent = Agent.new()
      {:ok, response, _agent} = Agent.process(agent, "Hello!")

      assert response == "Hello! How can I help you?"
    end

    test "adds messages to session" do
      expect(Rag.Ai.Gemini, :generate_text, fn _provider, _prompt, _opts ->
        {:ok, "Response"}
      end)

      agent = Agent.new()
      {:ok, _response, updated_agent} = Agent.process(agent, "Query")

      messages = Session.messages(updated_agent.session)
      # User + assistant
      assert length(messages) >= 2

      roles = Enum.map(messages, & &1.role)
      assert :user in roles
      assert :assistant in roles
    end

    test "handles LLM errors" do
      expect(Rag.Ai.Gemini, :generate_text, fn _provider, _prompt, _opts ->
        {:error, :rate_limited}
      end)

      agent = Agent.new()
      result = Agent.process(agent, "Query")

      assert {:error, :rate_limited} = result
    end
  end

  describe "process_with_tools/2" do
    test "executes tool when LLM requests it" do
      # First call: LLM requests tool
      expect(Rag.Ai.Gemini, :generate_text, fn _provider, _prompt, _opts ->
        {:ok, ~s({"tool": "echo", "args": {"message": "test"}})}
      end)

      # Second call: LLM provides final answer
      expect(Rag.Ai.Gemini, :generate_text, fn _provider, _prompt, _opts ->
        {:ok, "The echo returned: Echo: test"}
      end)

      agent = Agent.new(tools: [EchoTool])
      {:ok, response, _agent} = Agent.process_with_tools(agent, "Echo 'test'")

      assert String.contains?(response, "Echo: test") or String.contains?(response, "echo")
    end

    test "respects max_iterations" do
      # Keep returning tool calls
      stub(Rag.Ai.Gemini, :generate_text, fn _provider, _prompt, _opts ->
        {:ok, ~s({"tool": "echo", "args": {"message": "loop"}})}
      end)

      agent = Agent.new(tools: [EchoTool], max_iterations: 2)
      result = Agent.process_with_tools(agent, "Keep echoing")

      # Should stop after max iterations
      assert {:error, :max_iterations_exceeded} = result
    end
  end

  describe "tool execution" do
    test "parse_tool_call/1 extracts tool and args" do
      response = ~s({"tool": "search", "args": {"query": "test"}})

      result = Agent.parse_tool_call(response)

      assert {:ok, "search", %{"query" => "test"}} = result
    end

    test "parse_tool_call/1 handles non-tool responses" do
      response = "This is just a regular response"

      result = Agent.parse_tool_call(response)

      assert {:none, _response} = result
    end

    test "execute_tool/3 runs tool and returns result" do
      registry = Registry.new(tools: [EchoTool])

      result = Agent.execute_tool(registry, "echo", %{"message" => "hello"}, %{})

      assert {:ok, "Echo: hello"} = result
    end

    test "execute_tool/3 returns error for unknown tool" do
      registry = Registry.new()

      result = Agent.execute_tool(registry, "unknown", %{}, %{})

      assert {:error, {:tool_not_found, "unknown"}} = result
    end
  end

  describe "with_context/2" do
    test "adds context to agent session" do
      agent =
        Agent.new()
        |> Agent.with_context(:key, "value")

      assert Session.get_context(agent.session, :key) == "value"
    end

    test "allows chaining context additions" do
      agent =
        Agent.new()
        |> Agent.with_context(:a, 1)
        |> Agent.with_context(:b, 2)

      assert Session.get_context(agent.session, :a) == 1
      assert Session.get_context(agent.session, :b) == 2
    end
  end

  describe "get_history/1" do
    test "returns message history" do
      expect(Rag.Ai.Gemini, :generate_text, fn _provider, _prompt, _opts ->
        {:ok, "Response"}
      end)

      agent = Agent.new()
      {:ok, _response, agent} = Agent.process(agent, "Hello")

      history = Agent.get_history(agent)

      assert is_list(history)
      assert length(history) >= 2
    end
  end

  describe "clear_history/1" do
    test "clears session messages" do
      expect(Rag.Ai.Gemini, :generate_text, fn _provider, _prompt, _opts ->
        {:ok, "Response"}
      end)

      agent = Agent.new()
      {:ok, _response, agent} = Agent.process(agent, "Hello")
      agent = Agent.clear_history(agent)

      assert Agent.get_history(agent) == []
    end
  end
end
