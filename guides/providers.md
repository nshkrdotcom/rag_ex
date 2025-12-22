# LLM Providers

The Rag library supports multiple LLM providers through a unified interface, enabling flexible provider selection and failover.

## Available Providers

| Provider | Module | Embeddings | Tools | Streaming | Max Context |
|----------|--------|-----------|-------|-----------|-------------|
| **Gemini** | `Rag.Ai.Gemini` | Yes | Yes | Yes | 1M tokens |
| **Claude** | `Rag.Ai.Claude` | No | Yes | Yes | 200K tokens |
| **Codex** | `Rag.Ai.Codex` | No | Yes | Yes | 128K tokens |
| **OpenAI** | `Rag.Ai.OpenAI` | Yes | Yes | Yes | Model-dependent |
| **Ollama** | `Rag.Ai.Ollama` | Yes | Yes | Yes | Model-dependent |
| **Cohere** | `Rag.Ai.Cohere` | Yes | Yes | Yes | Model-dependent |
| **Nx** | `Rag.Ai.Nx` | Yes | No | Config | Local |

## Provider Behaviour

All providers implement the `Rag.Ai.Provider` behaviour:

```elixir
@callback new(attrs :: map()) :: struct()
@callback generate_embeddings(provider, texts, opts) :: {:ok, list(embedding())} | {:error, any()}
@callback generate_text(provider, prompt, opts) :: {:ok, response()} | {:error, any()}
```

## Configuration

### Environment Variables

```bash
# Gemini (recommended for embeddings)
export GEMINI_API_KEY="your-api-key"

# Claude (best for analysis)
export ANTHROPIC_API_KEY="your-api-key"

# OpenAI/Codex (best for code)
export OPENAI_API_KEY="your-api-key"
# or
export CODEX_API_KEY="your-api-key"
```

## Gemini Provider

The default provider with full embedding support.

Models are resolved through `Gemini.Config`, so you can pass alias keys
(e.g., `:flash_lite_latest`) or omit `:model` to use auth-aware defaults.

Optional app-wide defaults:

```elixir
config :rag, Rag.Ai.Gemini,
  model: Gemini.Config.default_model(),
  embedding_model: Gemini.Config.default_embedding_model()
```

### Usage

```elixir
alias Rag.Ai.Gemini
alias Gemini.Config, as: GeminiConfig

# Create provider instance
provider = Gemini.new(%{model: :flash_lite_latest})

# Text generation
{:ok, response} = Gemini.generate_text(provider, "Hello!", [])

# Streaming
{:ok, stream} = Gemini.generate_text(provider, "Hello!", stream: true)
Enum.each(stream, &IO.write/1)

# Embeddings
{:ok, embeddings} = Gemini.generate_embeddings(provider, ["text1", "text2"], [])
```

### Options

```elixir
# Text generation options
[
  stream: false,           # Enable streaming
  temperature: 0.7,        # Randomness (0.0-2.0)
  max_tokens: 1024,        # Max output tokens
  top_p: 0.9,             # Nucleus sampling
  top_k: 40               # Top-K sampling
]

# Embedding options
[
  task_type: :retrieval_document,  # or :retrieval_query
  model: GeminiConfig.default_embedding_model() # Auth-aware default
]
```

### Capabilities

```elixir
Gemini.supports_tools?()         # true
Gemini.supports_embeddings?()    # true
Gemini.max_context_tokens()      # 1_000_000
Gemini.cost_per_1k_tokens()      # {0.000075, 0.000300}
```

## Claude Provider

Best for analysis, reasoning, and agentic workflows.

### Usage

```elixir
alias Rag.Ai.Claude

provider = Claude.new(%{
  model: "claude-sonnet-4-20250514",
  max_turns: 10
})

# Text generation
{:ok, response} = Claude.generate_text(provider, "Analyze this code", [])

# With system prompt
{:ok, response} = Claude.generate_text(provider, "Hello",
  system_prompt: "You are a helpful assistant."
)

# Embeddings NOT supported
{:error, :not_supported} = Claude.generate_embeddings(provider, ["text"], [])
```

### Options

```elixir
[
  stream: false,                   # Enable streaming
  system_prompt: "You are...",     # System instruction
  output_format: :text             # Output format
]
```

## Codex Provider (OpenAI-compatible)

Best for code generation and structured output.

### Usage

```elixir
alias Rag.Ai.Codex

provider = Codex.new(%{
  model: "gpt-4o",
  reasoning_effort: :medium  # :low, :medium, or :high
})

# Text generation
{:ok, response} = Codex.generate_text(provider, "Write a function", [])

# With structured output
{:ok, response} = Codex.generate_text(provider, "Generate JSON",
  output_schema: %{type: "object", properties: %{...}}
)
```

## OpenAI Provider (Direct HTTP)

Alternative OpenAI implementation without SDK.

### Usage

```elixir
alias Rag.Ai.OpenAI

provider = OpenAI.new(%{
  embeddings_url: "https://api.openai.com/v1/embeddings",
  embeddings_model: "text-embedding-3-small",
  text_url: "https://api.openai.com/v1/chat/completions",
  text_model: "gpt-4o",
  api_key: System.get_env("OPENAI_API_KEY")
})

{:ok, embeddings} = OpenAI.generate_embeddings(provider, ["text"], [])
{:ok, response} = OpenAI.generate_text(provider, "Hello", [])
```

## Ollama Provider (Local)

For self-hosted local models.

### Usage

```elixir
alias Rag.Ai.Ollama

provider = Ollama.new(%{
  embeddings_url: "http://localhost:11434/api/embed",
  embeddings_model: "nomic-embed-text",
  text_url: "http://localhost:11434/api/chat",
  text_model: "llama2"
})

{:ok, embeddings} = Ollama.generate_embeddings(provider, ["text"], [])
{:ok, response} = Ollama.generate_text(provider, "Hello", [])
```

## Nx Provider (On-Device)

For local inference using Bumblebee models.

### Usage

```elixir
alias Rag.Ai.Nx

# Must pre-configure Nx.Serving instances
provider = Nx.new(%{
  embeddings_serving: embedding_serving,  # from Bumblebee
  text_serving: text_serving
})

{:ok, embeddings} = Nx.generate_embeddings(provider, ["text"], [])
```

## Capabilities Module

Query provider capabilities at runtime:

```elixir
alias Rag.Ai.Capabilities

# Get all providers
Capabilities.all()
# %{gemini: %{embeddings: true, ...}, claude: %{...}, codex: %{...}}

# Get available providers (with valid credentials)
Capabilities.available()

# Check specific capability
Capabilities.can_handle?(:gemini, :embeddings)  # true
Capabilities.can_handle?(:claude, :embeddings)  # false

# Get providers with capability
Capabilities.with_capability(:embeddings)
# [{:gemini, %{...}}]

# Best provider for task
Capabilities.best_for(:embeddings)      # :gemini
Capabilities.best_for(:code_generation) # :codex
Capabilities.best_for(:analysis)        # :claude
Capabilities.best_for(:long_context)    # :gemini
```

### Task Mappings

| Task | Best Provider | Reason |
|------|---------------|--------|
| `:embeddings` | Gemini | Only provider with embedding support |
| `:long_context` | Gemini | 1M token context window |
| `:multimodal` | Gemini | Image/audio support |
| `:cost` | Gemini | Most cost-effective |
| `:speed` | Gemini | Fastest inference |
| `:code_generation` | Codex | Optimized for code |
| `:structured_output` | Codex | Best JSON generation |
| `:analysis` | Claude | Deep reasoning |
| `:writing` | Claude | Best prose quality |
| `:agentic` | Claude | Multi-step workflows |
| `:reasoning` | Claude | Complex logic |
| `:safety` | Claude | Strongest safety |

## Streaming Responses

All major providers support streaming:

```elixir
{:ok, stream} = Router.execute(router, :text, "Count to 10", stream: true)

# Consume stream
Enum.each(stream, fn chunk ->
  IO.write(chunk)
end)
```

## Cost Comparison

| Provider | Input (per 1M tokens) | Output (per 1M tokens) |
|----------|----------------------|------------------------|
| Gemini | $0.075 | $0.30 |
| Claude | $3.00 | $15.00 |
| Codex/GPT-4o | $2.50 | $10.00 |

## Best Practices

1. **Use Gemini for embeddings** - It's the only provider with native embedding support
2. **Use Claude for analysis** - Best reasoning capabilities
3. **Use Codex for code** - Optimized for code generation
4. **Configure fallback** - Use Router with multiple providers for reliability
5. **Check capabilities first** - Use `Capabilities.can_handle?/2` before calling

## Next Steps

- [Smart Router](router.md) - Learn about routing strategies
- [Embeddings](embeddings.md) - Deep dive into embedding generation
