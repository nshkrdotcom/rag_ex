# Multi-LLM Router Example
#
# This example demonstrates the full capabilities of the Rag.Router system
# for multi-LLM provider management with routing, fallback, and failure handling.
#
# Run from project root:
#   mix run examples/multi_llm_router.exs
#
# Prerequisites:
#   - At least one of: GEMINI_API_KEY, ANTHROPIC_API_KEY, OPENAI_API_KEY/CODEX_API_KEY
#   - The example gracefully handles missing API keys and shows available providers

alias Rag.Router
alias Rag.Ai.Capabilities

# ==============================================================================
# Helper Functions
# ==============================================================================

defmodule RouterExample do
  @doc """
  Print a section header
  """
  def header(title) do
    IO.puts("\n#{String.duplicate("=", 70)}")
    IO.puts("  #{title}")
    IO.puts(String.duplicate("=", 70))
  end

  @doc """
  Print a subsection header
  """
  def subheader(title) do
    IO.puts("\n#{title}")
    IO.puts(String.duplicate("-", 70))
  end

  @doc """
  Print provider capabilities in a formatted way
  """
  def print_capabilities(name, caps) do
    IO.puts("\n  #{name |> to_string() |> String.upcase()}")
    IO.puts("    Module:           #{caps.module}")
    IO.puts("    Embeddings:       #{caps.embeddings}")
    IO.puts("    Tools:            #{caps.tools}")
    IO.puts("    Streaming:        #{caps.streaming}")
    IO.puts("    Max Context:      #{format_number(caps.max_context)} tokens")

    {input, output} = caps.cost

    IO.puts(
      "    Cost (per 1K):    $#{Float.round(input, 6)} input / $#{Float.round(output, 6)} output"
    )

    IO.puts(
      "    Strengths:        #{caps.strengths |> Enum.map(&to_string/1) |> Enum.join(", ")}"
    )
  end

  @doc """
  Format a number with commas
  """
  def format_number(num) do
    num
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  @doc """
  Check which providers are available based on environment variables
  """
  def check_provider_availability do
    checks = %{
      gemini: System.get_env("GEMINI_API_KEY"),
      claude: System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_AGENT_OAUTH_TOKEN"),
      codex: System.get_env("CODEX_API_KEY") || System.get_env("OPENAI_API_KEY")
    }

    available =
      checks
      |> Enum.filter(fn {_k, v} -> v != nil end)
      |> Enum.map(fn {k, _v} -> k end)

    {available, checks}
  end

  @doc """
  Execute a request and display the result
  """
  def execute_and_display(router, type, prompt, opts \\ []) do
    task = Keyword.get(opts, :task, "request")
    IO.puts("\n  Executing #{task}...")

    IO.puts(
      "  Prompt: \"#{String.slice(prompt, 0..60)}#{if String.length(prompt) > 60, do: "...", else: ""}\""
    )

    case Router.execute(router, type, prompt, opts) do
      {:ok, response, updated_router} ->
        response_preview =
          if is_binary(response) do
            String.slice(response, 0..100) <>
              if String.length(response) > 100, do: "...", else: ""
          else
            inspect(response) |> String.slice(0..100)
          end

        IO.puts("  ✓ Success!")
        IO.puts("  Response: #{response_preview}")
        {:ok, updated_router}

      {:error, reason} ->
        IO.puts("  ✗ Error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Demonstrate streaming response
  """
  def demonstrate_streaming(router, prompt) do
    IO.puts("\n  Testing streaming response...")
    IO.puts("  Prompt: \"#{prompt}\"")
    IO.write("  Streamed: ")

    case Router.execute(router, :text, prompt, stream: true) do
      {:ok, stream, updated_router} ->
        # Collect and display stream chunks
        # Take first 10 chunks
        chunks = Enum.take(stream, 10)

        Enum.each(chunks, fn chunk ->
          IO.write(chunk)
        end)

        IO.puts("\n  ✓ Streaming completed")
        {:ok, updated_router}

      {:error, reason} ->
        IO.puts("\n  ✗ Streaming error: #{inspect(reason)}")
        {:error, reason}
    end
  end
end

# ==============================================================================
# Main Example
# ==============================================================================

RouterExample.header("MULTI-LLM ROUTER DEMONSTRATION")

IO.puts("""

This example demonstrates the Rag.Router system for intelligent multi-provider
LLM management with automatic routing, fallback handling, and failure recovery.
""")

# ==============================================================================
# 1. Environment Check & Provider Detection
# ==============================================================================

RouterExample.header("1. ENVIRONMENT CHECK & PROVIDER DETECTION")

{available_providers, api_checks} = RouterExample.check_provider_availability()

RouterExample.subheader("API Key Status")

for {provider, key} <- api_checks do
  status = if key, do: "✓ Available", else: "✗ Missing"

  env_var =
    case provider do
      :gemini -> "GEMINI_API_KEY"
      :claude -> "ANTHROPIC_API_KEY or CLAUDE_AGENT_OAUTH_TOKEN"
      :codex -> "OPENAI_API_KEY or CODEX_API_KEY"
    end

  IO.puts("  #{provider |> to_string() |> String.pad_trailing(8)} #{status} (#{env_var})")
end

if Enum.empty?(available_providers) do
  IO.puts("\n❌ ERROR: No API keys found!")
  IO.puts("\nPlease set at least one of the following environment variables:")
  IO.puts("  - GEMINI_API_KEY (recommended)")
  IO.puts("  - ANTHROPIC_API_KEY")
  IO.puts("  - OPENAI_API_KEY or CODEX_API_KEY")
  System.halt(1)
end

IO.puts(
  "\n✓ Found #{length(available_providers)} available provider(s): #{Enum.join(available_providers, ", ")}"
)

# ==============================================================================
# 2. Provider Capabilities
# ==============================================================================

RouterExample.header("2. PROVIDER CAPABILITIES")

RouterExample.subheader("All Known Providers")

for {name, caps} <- Capabilities.all() do
  RouterExample.print_capabilities(name, caps)
end

RouterExample.subheader("Currently Available Providers")
available = Capabilities.available()

if Enum.empty?(available) do
  IO.puts("  None (missing API keys or modules not loaded)")
else
  for {name, caps} <- available do
    IO.puts("  ✓ #{name} - #{caps.module}")
  end
end

# ==============================================================================
# 3. Capability-Based Provider Selection
# ==============================================================================

RouterExample.header("3. CAPABILITY-BASED PROVIDER SELECTION")

RouterExample.subheader("Providers by Capability")

capabilities = [:embeddings, :tools, :streaming]

for capability <- capabilities do
  providers =
    Capabilities.with_capability(capability)
    |> Enum.map(fn {name, _caps} -> name end)

  IO.puts(
    "  #{capability |> to_string() |> String.pad_trailing(12)}: #{Enum.join(providers, ", ")}"
  )
end

RouterExample.subheader("Best Provider by Task Type")

tasks = [
  :embeddings,
  :code_generation,
  :code_review,
  :analysis,
  :writing,
  :long_context,
  :structured_output,
  :reasoning
]

for task <- tasks do
  best = Capabilities.best_for(task)
  available_mark = if best in available_providers, do: "✓", else: "✗"
  IO.puts("  #{available_mark} #{task |> to_string() |> String.pad_trailing(18)}: #{best}")
end

# ==============================================================================
# 4. Creating Routers with Different Strategies
# ==============================================================================

RouterExample.header("4. ROUTER STRATEGIES")

RouterExample.subheader("Strategy 1: FALLBACK (Try providers in order)")

case Router.new(providers: available_providers, strategy: :fallback) do
  {:ok, fallback_router} ->
    IO.puts("""
      ✓ Created fallback router

      Behavior:
      - Tries providers in the specified order
      - Falls back to next provider on failure
      - Tracks failures and temporarily skips problematic providers
      - Automatically recovers failed providers after cooldown period

      Providers: #{inspect(available_providers)}
    """)

    # Test the fallback router
    execute_result =
      RouterExample.execute_and_display(
        fallback_router,
        :text,
        "Say 'Hello from fallback strategy!' in a friendly way.",
        task: "fallback test"
      )

    case execute_result do
      {:ok, _router} -> IO.puts("  ✓ Fallback strategy working!")
      {:error, _} -> IO.puts("  ✗ Fallback strategy failed")
    end

  {:error, reason} ->
    IO.puts("  ✗ Failed to create fallback router: #{inspect(reason)}")
end

RouterExample.subheader("Strategy 2: ROUND-ROBIN (Load balancing)")

if length(available_providers) >= 2 do
  case Router.new(providers: available_providers, strategy: :round_robin) do
    {:ok, rr_router} ->
      IO.puts("""
        ✓ Created round-robin router

        Behavior:
        - Distributes requests evenly across all providers
        - Supports weighted distribution (more requests to preferred providers)
        - Automatically skips unavailable providers
        - Recovers providers after cooldown period

        Providers: #{inspect(available_providers)}
      """)

      # Demonstrate round-robin routing
      IO.puts("\n  Demonstrating provider rotation (5 requests):")

      Enum.reduce(1..5, rr_router, fn i, router ->
        case Router.route(router, :text, "Request #{i}", []) do
          {:ok, provider, new_router} ->
            IO.puts("    Request #{i} → #{provider}")
            new_router

          {:error, _reason} ->
            IO.puts("    Request #{i} → routing failed")
            router
        end
      end)

    {:error, reason} ->
      IO.puts("  ✗ Failed to create round-robin router: #{inspect(reason)}")
  end
else
  IO.puts("  ⊘ Skipped (requires at least 2 providers)")
end

RouterExample.subheader("Strategy 3: SPECIALIST (Task-based routing)")

if length(available_providers) >= 3 do
  case Router.new(providers: available_providers, strategy: :specialist) do
    {:ok, specialist_router} ->
      IO.puts("""
        ✓ Created specialist router

        Behavior:
        - Routes requests to the best provider for each task type
        - Infers task from prompt content (code keywords, analysis keywords)
        - Falls back to default provider if preferred provider unavailable
        - Supports explicit task specification via :task option

        Task Mappings:
        - Code generation/review → Codex
        - Analysis/reasoning → Claude
        - Embeddings/long context → Gemini

        Providers: #{inspect(available_providers)}
      """)

      # Test different task types
      test_cases = [
        {"Write a function to calculate fibonacci numbers", :code_generation},
        {"Analyze the pros and cons of microservices", :analysis},
        {"Summarize this 10,000 word document", :long_context}
      ]

      IO.puts("\n  Testing task-based routing:")

      for {prompt, expected_task} <- test_cases do
        {:ok, provider, _} = Router.route(specialist_router, :text, prompt, task: expected_task)
        IO.puts("    #{expected_task |> to_string() |> String.pad_trailing(18)} → #{provider}")
      end

    {:error, reason} ->
      IO.puts("  ✗ Failed to create specialist router: #{inspect(reason)}")
  end
else
  IO.puts("""
    ⊘ Skipped (requires 3 providers for full demonstration)

    Note: Specialist strategy works with fewer providers but is most
    effective when you have Gemini, Claude, and Codex available.
  """)
end

RouterExample.subheader("Strategy 4: AUTO (Automatic selection)")

case Router.new(providers: available_providers, strategy: :auto) do
  {:ok, auto_router} ->
    selected_strategy =
      cond do
        length(available_providers) >= 3 -> "specialist"
        length(available_providers) >= 2 -> "fallback"
        true -> "fallback"
      end

    available_in_router = Router.available_providers(auto_router)

    IO.puts("""
      ✓ Created auto router (selected: #{selected_strategy})

      Behavior:
      - Automatically selects best strategy based on provider count:
        * 3+ providers → Specialist (task-based routing)
        * 2 providers  → Fallback (reliability)
        * 1 provider   → Fallback (passthrough)

      Providers: #{inspect(available_providers)}
      Auto-selected: #{selected_strategy}
      Active in router: #{inspect(available_in_router)}
    """)

  {:error, reason} ->
    IO.puts("  ✗ Failed to create auto router: #{inspect(reason)}")
end

# ==============================================================================
# 5. Provider Auto-Detection
# ==============================================================================

RouterExample.header("5. AUTOMATIC PROVIDER DETECTION")

case Router.new(auto_detect: true) do
  {:ok, auto_router} ->
    detected = Router.available_providers(auto_router)

    IO.puts("""
      ✓ Router created with auto-detection

      The router automatically detected available providers by:
      1. Checking if provider modules are loaded
      2. Verifying API keys are present in environment

      Detected providers: #{inspect(detected)}
    """)

  {:error, reason} ->
    IO.puts("  ✗ Auto-detection failed: #{inspect(reason)}")
end

# ==============================================================================
# 6. Text Generation Examples
# ==============================================================================

RouterExample.header("6. TEXT GENERATION")

{:ok, router} = Router.new(providers: available_providers)

RouterExample.subheader("Basic Text Generation")

RouterExample.execute_and_display(
  router,
  :text,
  "Explain what a multi-LLM router is in one sentence.",
  task: "basic generation"
)

RouterExample.subheader("With System Prompt")

RouterExample.execute_and_display(
  router,
  :text,
  "What is Elixir?",
  system_prompt: "You are a concise technical writer. Answer in exactly one sentence.",
  task: "with system prompt"
)

RouterExample.subheader("With Temperature Control")

RouterExample.execute_and_display(
  router,
  :text,
  "Write a creative haiku about artificial intelligence.",
  temperature: 1.5,
  task: "creative with high temperature"
)

# ==============================================================================
# 7. Streaming Responses
# ==============================================================================

RouterExample.header("7. STREAMING RESPONSES")

RouterExample.subheader("Streaming Text Generation")

if :gemini in available_providers do
  {:ok, stream_router} = Router.new(providers: [:gemini])

  IO.puts("""
    Streaming is supported by all major providers (Gemini, Claude, Codex).
    This allows you to display responses as they're generated.
  """)

  RouterExample.demonstrate_streaming(
    stream_router,
    "Count from 1 to 5, with one number per line."
  )
else
  IO.puts("  ⊘ Skipped (requires Gemini provider)")
end

# ==============================================================================
# 8. Failure Handling & Automatic Fallback
# ==============================================================================

RouterExample.header("8. FAILURE HANDLING & AUTOMATIC FALLBACK")

if length(available_providers) >= 2 do
  {:ok, fallback_test_router} =
    Router.new(
      providers: available_providers,
      strategy: :fallback,
      max_failures: 2
    )

  IO.puts("""
    The router automatically handles provider failures:

    1. If a provider fails, it's marked and the next one is tried
    2. After max_failures consecutive failures, provider is temporarily disabled
    3. Failed providers are automatically recovered after a cooldown period
    4. Router.execute handles all retries transparently
  """)

  RouterExample.subheader("Simulating Provider Failure Recovery")

  # Execute a request - router will handle any failures automatically
  case Router.execute(fallback_test_router, :text, "Say 'success' if this works.", []) do
    {:ok, _response, updated_router} ->
      available = Router.available_providers(updated_router)
      IO.puts("\n  ✓ Request succeeded")
      IO.puts("  Available providers after request: #{inspect(available)}")

    {:error, :all_providers_failed} ->
      IO.puts("\n  ✗ All providers failed")

    {:error, reason} ->
      IO.puts("\n  ✗ Request failed: #{inspect(reason)}")
  end
else
  IO.puts("  ⊘ Skipped (requires multiple providers for demonstration)")
end

# ==============================================================================
# 9. Embeddings Generation
# ==============================================================================

RouterExample.header("9. EMBEDDINGS GENERATION")

if :gemini in available_providers do
  {:ok, embedding_router} = Router.new(providers: [:gemini])

  IO.puts("""
    Gemini is currently the only provider supporting embeddings.
    The router will automatically route embedding requests to Gemini.
  """)

  RouterExample.subheader("Generate Embeddings")

  texts = [
    "The quick brown fox jumps over the lazy dog",
    "Machine learning is a subset of artificial intelligence",
    "Elixir is a functional programming language"
  ]

  IO.puts("\n  Generating embeddings for #{length(texts)} texts...")

  case Router.execute(embedding_router, :embeddings, texts, []) do
    {:ok, embeddings, _router} ->
      IO.puts("  ✓ Generated #{length(embeddings)} embeddings")

      if length(embeddings) > 0 do
        first_embedding = List.first(embeddings)
        dimension = if is_list(first_embedding), do: length(first_embedding), else: 0
        IO.puts("  Embedding dimension: #{dimension}")

        IO.puts(
          "  First embedding preview: [#{Enum.take(first_embedding, 5) |> Enum.join(", ")}...]"
        )
      end

    {:error, reason} ->
      IO.puts("  ✗ Embedding generation failed: #{inspect(reason)}")
  end
else
  IO.puts("""
    ⊘ Skipped (requires Gemini provider)

    Note: Embeddings are currently only supported by the Gemini provider.
    If you try to generate embeddings with Claude or Codex, the router
    will return {:error, :not_supported}.
  """)
end

# ==============================================================================
# 10. Checking Provider Capabilities
# ==============================================================================

RouterExample.header("10. RUNTIME CAPABILITY CHECKING")

{:ok, check_router} = Router.new(providers: available_providers)

IO.puts("""
  You can check provider capabilities at runtime to make intelligent
  decisions about which features to use.
""")

RouterExample.subheader("Checking Individual Providers")

for provider <- available_providers do
  case Router.get_provider(check_router, provider) do
    {:ok, caps} ->
      IO.puts("\n  #{provider}:")
      IO.puts("    Embeddings: #{Capabilities.can_handle?(provider, :embeddings)}")
      IO.puts("    Tools:      #{Capabilities.can_handle?(provider, :tools)}")
      IO.puts("    Streaming:  #{Capabilities.can_handle?(provider, :streaming)}")
      IO.puts("    Max tokens: #{caps.max_context}")

    {:error, _} ->
      IO.puts("\n  #{provider}: Not found")
  end
end

# ==============================================================================
# Summary
# ==============================================================================

RouterExample.header("SUMMARY")

IO.puts("""

The Rag.Router provides a robust multi-LLM provider system with:

✓ Automatic provider detection based on environment variables
✓ Multiple routing strategies (fallback, round-robin, specialist)
✓ Intelligent task-based provider selection
✓ Automatic failure handling and recovery
✓ Support for text generation and embeddings
✓ Streaming response support
✓ Runtime capability checking
✓ Cost and performance optimization

Available Providers in This Session:
#{Enum.map(available_providers, fn p -> "  • #{p}" end) |> Enum.join("\n")}

For more information:
  • lib/rag/router/router.ex - Main router implementation
  • lib/rag/router/strategy.ex - Strategy behavior
  • lib/rag/ai/capabilities.ex - Provider capabilities
  • examples/routing_strategies.exs - Additional routing examples

""")

RouterExample.header("DEMONSTRATION COMPLETE")
