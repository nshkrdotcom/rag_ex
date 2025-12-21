# Pipelines

The Pipeline system provides composable RAG workflows with parallel execution, caching, and error handling.

## Overview

Pipelines consist of:
- **Steps** - Individual processing units
- **Context** - Shared state between steps
- **Executor** - Runs steps with caching/retry/telemetry

## Creating a Pipeline

```elixir
alias Rag.Pipeline
alias Rag.Pipeline.Step

pipeline = Pipeline.new(:rag_pipeline, description: "Complete RAG workflow")
```

### Adding Steps

```elixir
pipeline = Pipeline.add_step(pipeline,
  name: :embed_query,
  module: Steps,
  function: :embed_query,
  args: [model: "gemini"],
  timeout: 10_000,
  on_error: {:retry, 2},
  cache: true
)
```

### Step Options

| Option | Default | Description |
|--------|---------|-------------|
| `name` | required | Step identifier (atom) |
| `module` | required | Module containing function |
| `function` | required | Function to call |
| `args` | `[]` | Arguments passed to function |
| `inputs` | `nil` | Dependencies on previous steps |
| `parallel` | `false` | Run concurrently |
| `on_error` | `:halt` | Error handling strategy |
| `cache` | `false` | Cache results with ETS |
| `timeout` | `nil` | Timeout in milliseconds |

## Step Functions

Every step function must have this signature:

```elixir
def step_name(input, context, opts) do
  # input: Result from previous step(s)
  # context: Pipeline.Context struct
  # opts: Keyword list from step's :args

  # Return one of:
  {:ok, result}
  {:ok, result, updated_context}
  {:error, reason}
end
```

### Example Step

```elixir
defmodule MySteps do
  alias Rag.Pipeline.Context

  def embed_query(query, context, opts) do
    router = opts[:router]
    case Router.execute(router, :embeddings, [query], []) do
      {:ok, [embedding], _} ->
        updated_context = %{context | query_embedding: embedding}
        {:ok, embedding, updated_context}
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

## Context

The context holds state throughout pipeline execution:

```elixir
alias Rag.Pipeline.Context

# Create context
context = Context.new("What is Elixir?")

# Context structure
%Context{
  input: any(),                    # Original input
  query: String.t() | nil,
  query_embedding: [float()] | nil,
  retrieval_results: list(),
  reranked_results: list(),
  context_text: String.t() | nil,
  response: String.t() | nil,
  metadata: %{step_results: %{}},
  errors: []
}
```

### Context API

```elixir
# Store step result
context = Context.put_step_result(context, :embed, embedding)

# Get step result
embedding = Context.get_step_result(context, :embed)

# Store metadata
context = Context.put_metadata(context, :user_id, 123)

# Add error (for :continue strategy)
context = Context.add_error(context, {:step_failed, :rerank})
```

## Input Dependencies

### No Dependencies (Default)

Step receives output from previous step:

```elixir
Pipeline.add_step(pipeline, name: :step2, ...)
# step2 receives output from step1
```

### Single Dependency

```elixir
Pipeline.add_step(pipeline,
  name: :generate,
  inputs: [:retrieve],
  ...
)
# generate receives the :retrieve step's result
```

### Multiple Dependencies

```elixir
Pipeline.add_step(pipeline,
  name: :combine,
  inputs: [:semantic_search, :fulltext_search],
  ...
)
# combine receives: %{semantic_search: [...], fulltext_search: [...]}
```

## Error Handling

### `:halt` (Default)

Stop pipeline immediately on error:

```elixir
Pipeline.add_step(pipeline,
  name: :critical,
  on_error: :halt  # Pipeline stops if this fails
)
```

### `:continue`

Log error but continue execution:

```elixir
Pipeline.add_step(pipeline,
  name: :optional_rerank,
  on_error: :continue  # Skip if fails, continue pipeline
)
```

### `{:retry, n}`

Retry up to n times:

```elixir
Pipeline.add_step(pipeline,
  name: :api_call,
  on_error: {:retry, 3}  # Retry up to 3 times
)
```

## Parallel Execution

Independent steps can run concurrently:

```elixir
Pipeline.new(:hybrid_search)
|> Pipeline.add_step(name: :embed, ...)
|> Pipeline.add_step(
  name: :semantic_search,
  inputs: [:embed],
  parallel: true  # Runs in parallel
)
|> Pipeline.add_step(
  name: :fulltext_search,
  inputs: [:embed],
  parallel: true  # Runs in parallel
)
|> Pipeline.add_step(
  name: :combine,
  inputs: [:semantic_search, :fulltext_search]  # Waits for both
)
```

## Caching

Cache expensive operations with ETS:

```elixir
Pipeline.add_step(pipeline,
  name: :embed,
  cache: true  # Results cached in ETS
)
```

**Benefits:**
- Same input skips execution, uses cache
- Persists across pipeline runs
- Useful for embeddings, expensive computations

**Performance:**
```
First run:  3500ms (embedding computed)
Second run: 2100ms (embedding cached)
Speedup:    ~40%
```

## Timeouts

Prevent hanging on slow steps:

```elixir
Pipeline.add_step(pipeline,
  name: :llm_generate,
  timeout: 30_000  # 30 second timeout
)
```

## Telemetry

Pipeline emits telemetry events:

```elixir
# Start event
[:rag, :pipeline, :step, :start]
# Metadata: %{pipeline: :name, step: :step_name, attempt: 0}

# Stop event
[:rag, :pipeline, :step, :stop]
# Measurements: %{duration: microseconds}

# Exception event
[:rag, :pipeline, :step, :exception]
# Metadata: %{pipeline: :name, step: :step_name, error: reason}
```

### Attaching Handlers

```elixir
:telemetry.attach(
  "pipeline-logger",
  [:rag, :pipeline, :step, :stop],
  fn _event, measurements, metadata, _config ->
    IO.puts("Step #{metadata.step} completed in #{measurements.duration}μs")
  end,
  nil
)
```

## Complete Example

```elixir
defmodule MyApp.RAGPipeline do
  alias Rag.Pipeline
  alias Rag.Pipeline.Context

  def build(router, retriever) do
    Pipeline.new(:rag_pipeline, description: "Complete RAG")
    |> Pipeline.add_step(
      name: :embed_query,
      module: __MODULE__,
      function: :embed_query,
      args: [router: router],
      timeout: 10_000,
      on_error: {:retry, 2},
      cache: true
    )
    |> Pipeline.add_step(
      name: :retrieve,
      module: __MODULE__,
      function: :retrieve,
      args: [retriever: retriever],
      inputs: [:embed_query],
      timeout: 5_000
    )
    |> Pipeline.add_step(
      name: :rerank,
      module: __MODULE__,
      function: :rerank,
      args: [router: router],
      inputs: [:retrieve],
      on_error: :continue  # Optional step
    )
    |> Pipeline.add_step(
      name: :generate,
      module: __MODULE__,
      function: :generate,
      args: [router: router],
      inputs: [:rerank],
      timeout: 30_000
    )
  end

  def embed_query(query, context, opts) do
    router = opts[:router]
    case Router.execute(router, :embeddings, [query], []) do
      {:ok, [embedding], _} ->
        {:ok, embedding, %{context | query: query, query_embedding: embedding}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  def retrieve(embedding, context, opts) do
    retriever = opts[:retriever]
    case Retriever.retrieve(retriever, {embedding, context.query}, limit: 10) do
      {:ok, results} ->
        {:ok, results, %{context | retrieval_results: results}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  def rerank(results, context, opts) do
    router = opts[:router]
    reranker = Rag.Reranker.LLM.new(router: router)
    case Rag.Reranker.rerank(reranker, context.query, results, top_k: 5) do
      {:ok, reranked} ->
        {:ok, reranked, %{context | reranked_results: reranked}}
      {:error, _} ->
        # Return original results if reranking fails
        {:ok, results}
    end
  end

  def generate(results, context, opts) do
    router = opts[:router]
    context_text = Enum.map(results, & &1.content) |> Enum.join("\n\n")

    prompt = """
    Answer based on context:
    #{context_text}

    Question: #{context.query}
    """

    case Router.execute(router, :text, prompt, []) do
      {:ok, response, _} ->
        {:ok, response, %{context | response: response, context_text: context_text}}
      {:error, reason} ->
        {:error, reason}
    end
  end
end

# Usage
{:ok, router} = Router.new(providers: [:gemini])
retriever = %Rag.Retriever.Hybrid{repo: Repo}

pipeline = MyApp.RAGPipeline.build(router, retriever)
context = Context.new("What is GenServer?")

case Pipeline.execute(pipeline, context.input) do
  {:ok, response, final_context} ->
    IO.puts("Answer: #{response}")
    IO.puts("Used #{length(final_context.retrieval_results)} documents")

  {:error, reason} ->
    IO.puts("Pipeline failed: #{inspect(reason)}")
end
```

## Configuration Best Practices

### Timeouts

| Step Type | Suggested Timeout |
|-----------|-------------------|
| Embedding | 10-15 seconds |
| Database query | 5 seconds |
| LLM generation | 30-60 seconds |
| Overall pipeline | Sum + buffer |

### Caching

Enable for:
- Embeddings (deterministic)
- Expensive computations
- Repeated queries

Disable for:
- User-specific results
- Time-sensitive data

### Error Handling

| Step Type | Strategy |
|-----------|----------|
| Critical (embedding, retrieval) | `:halt` or `{:retry, 2}` |
| Enhancement (reranking) | `:continue` |
| External APIs | `{:retry, 3}` |

## Next Steps

- [Retrievers](retrievers.md) - Retrieval strategies for pipelines
- [Rerankers](rerankers.md) - Improve retrieval quality
- [Agent Framework](agent_framework.md) - Integrate agents in pipelines
