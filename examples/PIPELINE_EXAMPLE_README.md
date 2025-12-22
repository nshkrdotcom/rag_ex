# Pipeline Example - Complete Working Implementation

This example demonstrates the full capabilities of the RAG Pipeline system with real database and API integrations.

## Overview

The pipeline example showcases:

- **Real PostgreSQL database** with pgvector extension for vector storage
- **Real LLM APIs** (Gemini) for embeddings and text generation
- **Complete RAG workflows** from query to response
- **Multiple pipeline patterns** (sequential, parallel, hybrid search)
- **Production features** (caching, retries, error handling, timeouts)

## What You'll Learn

### 1. Pipeline Basics
- Creating pipelines with `Rag.Pipeline.new/2`
- Adding steps with `Pipeline.add_step/2`
- Executing pipelines with `Pipeline.execute/3`
- Using `Rag.Pipeline.Context` to pass data between steps

### 2. Step Configuration
- **Dependencies**: Using `inputs:` to depend on previous steps
- **Parallel execution**: Using `parallel: true` for concurrent steps
- **Error handling**: `on_error: :halt | :continue | {:retry, n}`
- **Caching**: `cache: true` to cache expensive operations
- **Timeouts**: `timeout: milliseconds` to prevent hanging

### 3. Real-World Integration
- Embedding generation with Router
- Vector database queries with VectorStore
- LLM response generation
- Document chunking and ingestion

## Prerequisites

### 1. PostgreSQL with pgvector

You need a PostgreSQL database with the pgvector extension:

```bash
# Install PostgreSQL (if not already installed)
# On macOS
brew install postgresql@15

# On Ubuntu/Debian
sudo apt-get install postgresql-15

# Install pgvector extension
# Follow instructions at: https://github.com/pgvector/pgvector
```

### 2. Gemini API Key

Get a free API key from Google AI Studio:

1. Visit: https://aistudio.google.com/apikey
2. Create a new API key
3. Export it in your shell:

```bash
export GEMINI_API_KEY="your-api-key-here"
```

### 3. Database Setup

Set up the demo database:

```bash
cd examples/rag_demo
mix deps.get
mix setup
```

This creates the database, runs migrations, and sets up the pgvector extension.

## Running the Example

### Quick Start

```bash
# From the rag_demo directory
cd examples/rag_demo
export GEMINI_API_KEY="your-key-here"
mix run ../pipeline_example.exs
```

### What Happens

The example runs **4 complete demonstrations**:

1. **Basic RAG Pipeline** - Sequential execution through all RAG steps
2. **Hybrid Search Pipeline** - Parallel semantic + full-text search with RRF
3. **Caching Demo** - Shows performance improvements from caching
4. **Document Ingestion** - Pipeline for adding documents to vector store

## Example Structure

### Pipeline Steps

Each step is a function with signature:
```elixir
def step_name(input, context, opts) do
  # Process input
  # Access previous results: Context.get_step_result(context, :step_name)
  # Return: {:ok, result} | {:ok, result, updated_context} | {:error, reason}
end
```

### Example 1: Basic RAG Pipeline

```elixir
Pipeline.new(:rag_pipeline)
|> Pipeline.add_step(
  name: :extract_query,
  module: RAGPipelineSteps,
  function: :extract_query
)
|> Pipeline.add_step(
  name: :generate_embedding,
  module: RAGPipelineSteps,
  function: :generate_embedding,
  inputs: [:extract_query],  # Depends on extract_query
  cache: true,                # Cache results
  timeout: 10_000,            # 10s timeout
  on_error: {:retry, 2}       # Retry 2 times
)
|> Pipeline.add_step(
  name: :retrieve_documents,
  module: RAGPipelineSteps,
  function: :retrieve_documents,
  inputs: [:generate_embedding],
  args: [limit: 10]
)
# ... more steps
```

### Example 2: Parallel Execution

```elixir
Pipeline.new(:hybrid_search)
|> Pipeline.add_step(
  name: :semantic_search,
  module: RAGPipelineSteps,
  function: :retrieve_documents,
  parallel: true  # Run in parallel
)
|> Pipeline.add_step(
  name: :fulltext_search,
  module: RAGPipelineSteps,
  function: :fulltext_search,
  parallel: true  # Also parallel
)
|> Pipeline.add_step(
  name: :combine_results,
  module: RAGPipelineSteps,
  function: :combine_search_results,
  inputs: [:semantic_search, :fulltext_search]  # Wait for both
)
```

## Pipeline Steps Explained

### 1. Extract Query
Validates and extracts the user query from input.

**Input**: String or `%{query: string}`
**Output**: Validated query string

### 2. Generate Embedding
Creates an embedding vector using Gemini's configured default embedding model.

**Input**: Query string
**Output**: Embedding vector `[float()]`
**Features**: Cached, retries on failure

### 3. Retrieve Documents
Performs semantic search using vector similarity (L2 distance).

**Input**: Embedding vector
**Output**: List of relevant documents
**Database**: Queries pgvector-enabled PostgreSQL

### 4. Rerank Documents
Reorders documents by relevance score.

**Input**: List of documents
**Output**: Top-k documents
**Note**: Simple implementation, can be replaced with LLM-based reranker

### 5. Build Context
Creates formatted context text from documents.

**Input**: List of documents
**Output**: Formatted context string

### 6. Generate Response
Generates final answer using LLM with retrieved context.

**Input**: Context string
**Output**: Generated response
**Features**: Long timeout (30s), retry logic

## Error Handling

The pipeline supports three error handling strategies:

### 1. Halt (`:halt`)
Stop pipeline execution immediately on error.

```elixir
on_error: :halt
```

### 2. Continue (`:continue`)
Log error but continue pipeline execution.

```elixir
on_error: :continue
```

### 3. Retry (`{:retry, n}`)
Retry step up to `n` times before failing.

```elixir
on_error: {:retry, 2}  # Retry up to 2 times
```

## Performance Features

### Caching

Expensive operations (embeddings) are cached using ETS:

```elixir
Pipeline.add_step(
  name: :generate_embedding,
  cache: true,  # Results cached across pipeline runs
  # ...
)
```

### Parallel Execution

Independent steps run concurrently:

```elixir
# These run in parallel
Pipeline.add_step(name: :task1, parallel: true)
Pipeline.add_step(name: :task2, parallel: true)
# This waits for both
Pipeline.add_step(name: :combine, inputs: [:task1, :task2])
```

### Timeouts

Prevent hanging on slow operations:

```elixir
Pipeline.add_step(
  timeout: 10_000,  # 10 second timeout
  # ...
)
```

## Observability

The pipeline emits telemetry events for monitoring:

- `[:rag, :pipeline, :step, :start]` - Step execution starts
- `[:rag, :pipeline, :step, :stop]` - Step execution completes
- `[:rag, :pipeline, :step, :exception]` - Step execution fails

Example telemetry handler:

```elixir
:telemetry.attach(
  "pipeline-logger",
  [:rag, :pipeline, :step, :stop],
  fn _event, measurements, metadata, _config ->
    IO.puts("Step #{metadata.step} completed in #{measurements.duration}ms")
  end,
  nil
)
```

## Sample Output

```
================================================================================
EXAMPLE 1: BASIC RAG PIPELINE
================================================================================

✓ Vector store contains 5 documents

Pipeline Configuration
--------------------------------------------------------------------------------
Pipeline: rag_pipeline
Description: Complete RAG pipeline with semantic search and generation
Steps: 6
  1. extract_query - RAGPipelineSteps.extract_query/3 (halt, cache: false)
  2. generate_embedding - RAGPipelineSteps.generate_embedding/3 ({:retry, 2}, cache: true)
  3. retrieve_documents - RAGPipelineSteps.retrieve_documents/3 (halt, cache: false)
  4. rerank_documents - RAGPipelineSteps.rerank_documents/3 (continue, cache: false)
  5. build_context - RAGPipelineSteps.build_context/3 (halt, cache: false)
  6. generate_response - RAGPipelineSteps.generate_response/3 ({:retry, 1}, cache: false)

Executing Pipeline
--------------------------------------------------------------------------------
Query: "How does pattern matching work in Elixir?"

  📊 Generating embedding for query...
  ✓ Embedding generated (dimension: 768)
  🔍 Retrieving top 10 documents from vector store...
  ✓ Retrieved 5 documents
  🎯 Reranking documents (keeping top 3)...
  ✓ Reranked to 3 documents
  📝 Building context from 3 documents...
  ✓ Context built (512 characters)
  🤖 Generating response with LLM...
  ✓ Response generated (287 characters)

✓ Pipeline completed successfully in 3421ms

Final Response
--------------------------------------------------------------------------------
According to Document 1, pattern matching is a powerful feature in Elixir
that allows you to destructure data and match it against specific patterns.
It's used in function definitions, case statements, and variable assignments...
```

## Customization

### Add Your Own Steps

```elixir
defmodule MySteps do
  def my_custom_step(input, context, opts) do
    # Your logic here
    result = process(input)
    {:ok, result}
  end
end

pipeline
|> Pipeline.add_step(
  name: :custom,
  module: MySteps,
  function: :my_custom_step,
  args: [option: "value"]
)
```

### Use Different LLM Providers

```elixir
# Use Claude instead of Gemini
{:ok, router} = Router.new(providers: [:claude])

Pipeline.add_step(
  name: :generate,
  function: :generate_response,
  args: [router: router]  # Pass router to step
)
```

## Troubleshooting

### "Missing GEMINI_API_KEY"

Set the environment variable:
```bash
export GEMINI_API_KEY="your-key-here"
```

### "No data in vector store"

The example automatically adds sample documents on first run.

### Database Connection Errors

Ensure PostgreSQL is running:
```bash
# Check status
pg_ctl status

# Start if needed
pg_ctl start

# Or using Homebrew (macOS)
brew services start postgresql@15
```

### "pgvector extension not found"

Install the pgvector extension:
```sql
CREATE EXTENSION vector;
```

## Next Steps

1. **Explore the code** - Read through `RAGPipelineSteps` module
2. **Modify pipelines** - Try different step configurations
3. **Add your data** - Ingest your own documents
4. **Build workflows** - Create custom pipelines for your use case
5. **Monitor performance** - Add telemetry handlers

## Related Examples

- `examples/vector_store.exs` - Vector store operations
- `examples/routing_strategies.exs` - Multi-LLM routing
- `examples/agent.exs` - Agent framework with tools
- `examples/rag_demo/priv/demo.exs` - Complete RAG demo

## Resources

- [Pipeline Module Documentation](../lib/rag/pipeline.ex)
- [Pipeline Context](../lib/rag/pipeline/context.ex)
- [Pipeline Executor](../lib/rag/pipeline/executor.ex)
- [Vector Store Documentation](../lib/rag/vector_store.ex)
- [Router Documentation](../lib/rag/router/router.ex)
