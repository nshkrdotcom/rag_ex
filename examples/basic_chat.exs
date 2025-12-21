# Basic Chat Example
#
# This example shows how to use the Router for simple LLM interactions.
#
# Run from project root:
#   mix run examples/basic_chat.exs
#
# Prerequisites:
#   - Set GEMINI_API_KEY environment variable

alias Rag.Router

IO.puts("=== Basic Chat Example ===\n")

# Create a router with Gemini provider
{:ok, router} = Router.new(providers: [:gemini])

# Simple generation
IO.puts("1. Simple generation:")
IO.puts(String.duplicate("-", 40))

case Router.execute(router, :text, "What is Elixir? Answer in one sentence.", []) do
  {:ok, response, _router} ->
    IO.puts(response)

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end

IO.puts("")

# With system prompt
IO.puts("2. With system prompt:")
IO.puts(String.duplicate("-", 40))

opts = [system_prompt: "You are a concise Elixir tutor. Keep answers under 50 words."]

case Router.execute(router, :text, "Explain pattern matching", opts) do
  {:ok, response, _router} ->
    IO.puts(response)

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end

IO.puts("")

# Multiple exchanges (simulating a conversation)
IO.puts("3. Multiple exchanges:")
IO.puts(String.duplicate("-", 40))

questions = [
  "What is a GenServer?",
  "What is a Supervisor?",
  "How do they work together?"
]

Enum.reduce(questions, router, fn question, router ->
  IO.puts("\nQ: #{question}")

  case Router.execute(router, :text, question, system_prompt: "Answer in 2 sentences max.") do
    {:ok, response, new_router} ->
      IO.puts("A: #{response}")
      new_router

    {:error, reason} ->
      IO.puts("Error: #{inspect(reason)}")
      router
  end
end)

IO.puts("\n=== Done ===")
