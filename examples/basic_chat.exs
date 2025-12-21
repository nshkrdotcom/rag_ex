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

# Multiple exchanges (simulating a conversation about Elixir/OTP)
IO.puts("3. Multiple exchanges:")
IO.puts(String.duplicate("-", 40))

# System prompt establishes context for the entire conversation
elixir_system_prompt = """
You are an Elixir/OTP expert. Answer questions about Elixir programming,
OTP patterns like GenServer, Supervisor, and the BEAM VM.
Keep answers concise (2-3 sentences max).
"""

questions = [
  "What is a GenServer in Elixir?",
  "What is an OTP Supervisor?",
  "How do GenServers and Supervisors work together in OTP?"
]

Enum.reduce(questions, router, fn question, router ->
  IO.puts("\nQ: #{question}")

  case Router.execute(router, :text, question, system_prompt: elixir_system_prompt) do
    {:ok, response, new_router} ->
      IO.puts("A: #{response}")
      new_router

    {:error, reason} ->
      IO.puts("Error: #{inspect(reason)}")
      router
  end
end)

IO.puts("\n=== Done ===")
