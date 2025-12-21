# Smart Router

The Router provides intelligent multi-provider orchestration with automatic failover, load balancing, and task-based routing.

## Overview

The Router selects the best LLM provider for each request based on configurable strategies, handles failures gracefully, and tracks provider health.

## Creating a Router

```elixir
alias Rag.Router

# With specific providers
{:ok, router} = Router.new(providers: [:gemini, :claude, :codex])

# Auto-detect available providers
{:ok, router} = Router.new(auto_detect: true)

# With specific strategy
{:ok, router} = Router.new(
  providers: [:gemini, :claude],
  strategy: :fallback
)
```

### Auto-Strategy Selection

When `strategy: :auto` or not specified:

| Provider Count | Strategy | Reason |
|----------------|----------|--------|
| 3+ providers | `:specialist` | Task-based routing |
| 2 providers | `:fallback` | Reliability via retry |
| 1 provider | `:fallback` | Passthrough |

## Core API

### Execute Request

```elixir
# Text generation
{:ok, response, router} = Router.execute(router, :text, "Hello", [])

# With options
{:ok, response, router} = Router.execute(router, :text, "Hello",
  system_prompt: "You are helpful.",
  temperature: 0.7
)

# Embeddings
{:ok, embeddings, router} = Router.execute(router, :embeddings, ["text1", "text2"], [])

# Streaming
{:ok, stream, router} = Router.execute(router, :text, "Count to 10", stream: true)
Enum.each(stream, &IO.write/1)
```

### Route Only (No Execution)

```elixir
# Get selected provider without executing
{:ok, provider, router} = Router.route(router, :text, "Hello", [])
# provider is :gemini, :claude, or :codex
```

### Query Providers

```elixir
# Available providers
Router.available_providers(router)  # [:gemini, :claude]

# Get provider capabilities
{:ok, caps} = Router.get_provider(router, :gemini)
# %{embeddings: true, streaming: true, max_context: 1_000_000, ...}
```

## Routing Strategies

### Fallback Strategy

Tries providers in order until one succeeds.

```elixir
{:ok, router} = Router.new(
  providers: [:gemini, :claude, :codex],
  strategy: :fallback,
  fallback_order: [:claude, :gemini, :codex],  # Custom order
  max_failures: 3,                              # Skip after 3 failures
  failure_decay_ms: 60_000                      # Reset after 60s
)
```

**Behavior:**
1. Try first provider in order
2. On failure, mark and try next
3. Skip providers with >= `max_failures` recent failures
4. Automatically recover after `failure_decay_ms`
5. Success resets failure count

**Configuration:**
- `fallback_order` - Custom provider order (default: providers list order)
- `max_failures` - Failures before skipping (default: 3)
- `failure_decay_ms` - Time to reset failures (default: 60,000ms)

### Round-Robin Strategy

Distributes load evenly across providers.

```elixir
{:ok, router} = Router.new(
  providers: [:gemini, :claude, :codex],
  strategy: :round_robin,
  weights: %{gemini: 3, codex: 2, claude: 1},  # Optional weighted
  max_consecutive_failures: 3,
  recovery_cooldown_ms: 30_000
)
```

**Behavior:**
1. Rotate through providers
2. With weights: `{gemini: 2, codex: 1}` produces gemini, gemini, codex, gemini, gemini, codex...
3. Skip unavailable providers
4. Mark unavailable after consecutive failures
5. Recover after cooldown period

**Configuration:**
- `weights` - Provider weights (default: equal)
- `max_consecutive_failures` - Before marking unavailable (default: 3)
- `recovery_cooldown_ms` - Recovery time (default: 30,000ms)

### Specialist Strategy

Routes based on task type to best-suited provider.

```elixir
{:ok, router} = Router.new(
  providers: [:gemini, :claude, :codex],
  strategy: :specialist,
  task_mappings: %{
    embeddings: :gemini,
    code_generation: :codex,
    analysis: :claude
  },
  fallback_provider: :gemini,
  max_failures: 3
)
```

**Default Task Mappings:**

| Task | Provider | Reason |
|------|----------|--------|
| `:embeddings` | Gemini | Embedding support |
| `:long_context` | Gemini | 1M token window |
| `:multimodal` | Gemini | Image/audio |
| `:cost` | Gemini | Cheapest |
| `:speed` | Gemini | Fastest |
| `:code_generation` | Codex | Code optimized |
| `:code_review` | Codex | Code understanding |
| `:structured_output` | Codex | JSON generation |
| `:analysis` | Claude | Deep reasoning |
| `:writing` | Claude | Best prose |
| `:agentic` | Claude | Multi-step |
| `:reasoning` | Claude | Complex logic |
| `:safety` | Claude | Safety focus |

**Task Inference:**
- Explicit: `Router.execute(router, :text, prompt, task: :code_generation)`
- Automatic: Infers from prompt keywords
  - Code keywords: "write", "implement", "function", "code", "class"
  - Analysis keywords: "analyze", "explain", "review", "compare"

**Configuration:**
- `task_mappings` - Task to provider mapping
- `fallback_provider` - Default if preferred unavailable
- `max_failures` - Before marking unavailable

## Error Handling

```elixir
case Router.execute(router, :text, "Hello", []) do
  {:ok, response, updated_router} ->
    # Success - use updated_router for subsequent calls
    IO.puts(response)

  {:error, :all_providers_failed} ->
    # All providers failed
    IO.puts("No providers available")

  {:error, reason} ->
    # Other error
    IO.puts("Error: #{inspect(reason)}")
end
```

### Manual Result Reporting

```elixir
# Report success/failure for custom execution
router = Router.report_result(router, :gemini, {:ok, "response"})
router = Router.report_result(router, :gemini, {:error, :timeout})

# Get next provider after failure
{:ok, next_provider, router} = Router.next_provider(router, :gemini)
```

## Execution Flow

```
User Request
    |
    v
Router.execute()
    |
    v
Strategy.select_provider()
    |
    v
Get/Create Provider Instance
    |
    v
Provider.generate_text() or .generate_embeddings()
    |
    +---> Success: return {:ok, result, router}
    |
    +---> Failure: report_result() -> next_provider() -> retry
              |
              +--> All exhausted: {:error, :all_providers_failed}
```

## Health Tracking

Each strategy tracks provider health differently:

### Fallback
- Counts consecutive failures per provider
- Skips provider when count >= `max_failures`
- Resets count after `failure_decay_ms` or on success

### Round-Robin
- Counts consecutive failures per provider
- Marks unavailable when count >= `max_consecutive_failures`
- Recovers after `recovery_cooldown_ms`
- Resets count on success

### Specialist
- Counts total failures per provider
- Marks unavailable when count >= `max_failures`
- Falls back to fallback_provider
- Resets count on success

## Provider Instance Caching

The router caches provider instances:

```elixir
# First use creates instance
{:ok, response, router} = Router.execute(router, :text, "Hello", [])

# Subsequent calls reuse cached instance
{:ok, response, router} = Router.execute(router, :text, "World", [])
```

## Best Practices

1. **Use fallback for reliability** - When uptime is critical
2. **Use round-robin for load balancing** - When distributing load matters
3. **Use specialist for optimization** - When matching task to provider matters
4. **Always use updated router** - Router state changes after each call
5. **Handle all_providers_failed** - Have a fallback plan
6. **Configure timeouts** - Prevent hanging on slow providers

## Example: Complete Setup

```elixir
alias Rag.Router

# Configure with all strategies
{:ok, router} = Router.new(
  providers: [:gemini, :claude, :codex],
  strategy: :specialist,
  task_mappings: %{
    embeddings: :gemini,
    code_generation: :codex,
    analysis: :claude,
    general: :gemini
  },
  fallback_provider: :gemini,
  max_failures: 3
)

# Embeddings go to Gemini
{:ok, embeddings, router} = Router.execute(router, :embeddings, ["text"], [])

# Code tasks go to Codex
{:ok, code, router} = Router.execute(router, :text,
  "Write a fibonacci function",
  task: :code_generation
)

# Analysis goes to Claude
{:ok, analysis, router} = Router.execute(router, :text,
  "Analyze this architecture decision",
  task: :analysis
)
```

## Next Steps

- [LLM Providers](providers.md) - Learn about each provider
- [Embeddings](embeddings.md) - Embedding generation service
