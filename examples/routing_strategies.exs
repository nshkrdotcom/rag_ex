# Routing Strategies Example
#
# This example demonstrates different routing strategies for multi-LLM setups.
#
# Run from project root:
#   mix run examples/routing_strategies.exs
#
# Prerequisites:
#   - Set GEMINI_API_KEY environment variable

alias Rag.Router
alias Rag.Ai.Capabilities

IO.puts("=== Routing Strategies Example ===\n")

# Check provider capabilities
IO.puts("1. Provider capabilities:")
IO.puts(String.duplicate("-", 40))

for {name, caps} <- Capabilities.all() do
  IO.puts("\n  #{name}:")
  IO.puts("    Module: #{caps.module}")
  IO.puts("    Embeddings: #{caps.embeddings}")
  IO.puts("    Tools: #{caps.tools}")
  IO.puts("    Streaming: #{caps.streaming}")
  IO.puts("    Max context: #{caps.max_context} tokens")
  IO.puts("    Strengths: #{inspect(caps.strengths)}")
end

IO.puts("")

# Fallback strategy
IO.puts("2. Fallback strategy:")
IO.puts(String.duplicate("-", 40))

{:ok, fallback_router} = Router.new(providers: [:gemini], strategy: :fallback)
IO.puts("Created fallback router")
IO.puts("Strategy: tries providers in order until one succeeds")

case Router.execute(fallback_router, :text, "Say 'hello' in one word", []) do
  {:ok, response, _router} ->
    IO.puts("Response: #{response}")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end

IO.puts("")

# Round Robin strategy
IO.puts("3. Round robin strategy:")
IO.puts(String.duplicate("-", 40))

{:ok, rr_router} = Router.new(providers: [:gemini], strategy: :round_robin)
IO.puts("Created round-robin router")
IO.puts("Strategy: distributes load across providers")

# Simulate multiple requests to show round robin behavior
IO.puts("\nSimulating 3 requests:")

Enum.reduce(1..3, rr_router, fn i, router ->
  {:ok, provider, new_router} = Router.route(router, :text, "Request #{i}", [])
  IO.puts("  Request #{i} -> routed to #{provider}")
  new_router
end)

IO.puts("")

# Specialist strategy
IO.puts("4. Specialist strategy:")
IO.puts(String.duplicate("-", 40))

{:ok, specialist_router} = Router.new(providers: [:gemini], strategy: :specialist)
IO.puts("Created specialist router")
IO.puts("Strategy: routes by task type to best provider")

# Show best provider for different tasks
IO.puts("\nBest providers by task:")
IO.puts("  Embeddings: #{Capabilities.best_for(:embeddings)}")
IO.puts("  Code generation: #{Capabilities.best_for(:code_generation)}")
IO.puts("  Analysis: #{Capabilities.best_for(:analysis)}")
IO.puts("  Long context: #{Capabilities.best_for(:long_context)}")

IO.puts("")

# Provider filtering by capability
IO.puts("5. Filter providers by capability:")
IO.puts(String.duplicate("-", 40))

embedding_providers = Capabilities.with_capability(:embeddings)
IO.puts("Providers with embeddings: #{inspect(Enum.map(embedding_providers, &elem(&1, 0)))}")

tool_providers = Capabilities.with_capability(:tools)
IO.puts("Providers with tools: #{inspect(Enum.map(tool_providers, &elem(&1, 0)))}")

IO.puts("")

# Available providers (based on loaded modules)
IO.puts("6. Available providers:")
IO.puts(String.duplicate("-", 40))

available = Capabilities.available()
IO.puts("Currently available providers:")

for {name, caps} <- available do
  IO.puts("  - #{name} (#{caps.module})")
end

IO.puts("")

# Using router with execution
IO.puts("7. Execute with routing:")
IO.puts(String.duplicate("-", 40))

case Router.execute(specialist_router, :text, "What is 2 + 2? Answer with just the number.", []) do
  {:ok, response, updated_router} ->
    IO.puts("Request routed and executed successfully")
    IO.puts("Response: #{response}")
    IO.puts("Available providers: #{inspect(Router.available_providers(updated_router))}")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end

IO.puts("\n=== Done ===")
