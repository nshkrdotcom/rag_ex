# Agent Example
#
# This example demonstrates using the agent framework with tools.
#
# Run from project root:
#   mix run examples/agent.exs
#
# Prerequisites:
#   - Set GEMINI_API_KEY environment variable

alias Rag.Agent.Agent
alias Rag.Agent.Registry
alias Rag.Agent.Session

IO.puts("=== Agent Framework Example ===\n")

# Create a tool registry with built-in tools
IO.puts("1. Creating tool registry:")
IO.puts(String.duplicate("-", 40))

registry =
  Registry.new(
    tools: [
      Rag.Agent.Tools.ReadFile,
      Rag.Agent.Tools.AnalyzeCode,
      Rag.Agent.Tools.SearchRepos
    ]
  )

tools = Registry.list(registry)
IO.puts("Registered #{length(tools)} tools:")

for tool <- tools do
  IO.puts("  - #{tool.name()}: #{String.slice(tool.description(), 0, 50)}...")
end

IO.puts("")

# Show tool schemas
IO.puts("2. Tool parameter schemas:")
IO.puts(String.duplicate("-", 40))

for tool <- tools do
  IO.puts("\n#{tool.name()}:")
  IO.inspect(tool.parameters(), pretty: true, limit: :infinity)
end

IO.puts("")

# Direct tool execution
IO.puts("3. Direct tool execution:")
IO.puts(String.duplicate("-", 40))

# Analyze some Elixir code
code = """
defmodule Calculator do
  def add(a, b), do: a + b
  def subtract(a, b), do: a - b
  defp validate(n) when n > 0, do: :ok
end
"""

IO.puts("Analyzing code:")
IO.puts(code)

{:ok, result} = Registry.execute(registry, "analyze_code", %{"code" => code}, %{})

IO.puts("Analysis result:")
IO.puts("  Modules: #{inspect(result.modules)}")
IO.puts("  Functions: #{length(result.functions)}")

for func <- result.functions do
  visibility = if func.type == :def, do: "public", else: "private"
  IO.puts("    - #{func.name}/#{func.arity} (#{visibility})")
end

IO.puts("")

# Session memory
IO.puts("4. Session memory:")
IO.puts(String.duplicate("-", 40))

session =
  Session.new(system_prompt: "You are a helpful assistant.")
  |> Session.add_message(:user, "What is Elixir?")
  |> Session.add_message(:assistant, "Elixir is a functional programming language.")
  |> Session.add_message(:user, "What about Phoenix?")
  |> Session.add_message(:assistant, "Phoenix is a web framework for Elixir.")

IO.puts("Session has #{Session.message_count(session)} messages:")

for msg <- Session.messages(session) do
  role = String.pad_trailing(to_string(msg.role), 10)
  content = String.slice(msg.content, 0, 50)
  IO.puts("  #{role}: #{content}...")
end

IO.puts("\nToken estimate: ~#{Session.token_estimate(session)} tokens")

IO.puts("")

# Create an agent
IO.puts("5. Creating an agent:")
IO.puts(String.duplicate("-", 40))

agent =
  Agent.new(
    tools: [
      Rag.Agent.Tools.ReadFile,
      Rag.Agent.Tools.AnalyzeCode
    ],
    max_iterations: 5
  )

IO.puts("Agent created:")
IO.puts("  Provider: Gemini (default)")
IO.puts("  Tools: #{Registry.count(agent.registry)}")
IO.puts("  Max iterations: #{agent.max_iterations}")

IO.puts("")

# Format tools for LLM
IO.puts("6. Tool format for LLM:")
IO.puts(String.duplicate("-", 40))

tool_definitions = Registry.format_for_llm(agent.registry)
IO.puts("Tools formatted for LLM (#{length(tool_definitions)} tools):")
IO.inspect(hd(tool_definitions), pretty: true)

IO.puts("\n=== Done ===")
