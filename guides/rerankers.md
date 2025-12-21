# Rerankers

Rerankers improve retrieval quality by scoring documents based on relevance to the query.

## Overview

The library provides two reranker implementations:

| Reranker | Method | Use Case |
|----------|--------|----------|
| **LLM** | LLM-based scoring | Production quality |
| **Passthrough** | No-op | Testing/baselines |

## Reranker Behaviour

All rerankers implement the `Rag.Reranker` behaviour:

```elixir
@callback rerank(reranker, query, documents, opts) ::
  {:ok, [document()]} | {:error, term()}

@type document :: %{
  id: any(),
  content: String.t(),
  score: float(),
  metadata: map()
}
```

## LLM Reranker

Uses an LLM to score document relevance on a 1-10 scale.

### Creating

```elixir
alias Rag.Reranker.LLM
alias Rag.Router

# Default configuration
reranker = LLM.new()

# With custom router
{:ok, router} = Router.new(providers: [:gemini, :claude])
reranker = LLM.new(router: router)

# With custom prompt
template = """
Score these documents for relevance to: {query}

Documents:
{documents}

Return JSON: [{"doc_index": 0, "score": 8}, ...]
"""
reranker = LLM.new(prompt_template: template)
```

### Reranking

```elixir
alias Rag.Reranker

documents = [
  %{id: 1, content: "Elixir programming", score: 0.7, metadata: %{}},
  %{id: 2, content: "Python basics", score: 0.8, metadata: %{}}
]

# Basic reranking
{:ok, reranked} = Reranker.rerank(reranker, "What is Elixir?", documents)

# With options
{:ok, reranked} = Reranker.rerank(reranker, "What is Elixir?", documents,
  top_k: 5,
  normalize_scores: true
)
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `top_k` | all | Return only top K documents |
| `normalize_scores` | false | Normalize scores to 0-1 range |

### Scoring

The LLM scores documents on a 1-10 scale:
- **1-3**: Not relevant or minimally relevant
- **4-6**: Somewhat relevant
- **7-9**: Highly relevant
- **10**: Extremely relevant

### Default Prompt Template

```
You are a relevance scoring assistant. Given a query and a list of documents,
score each document's relevance to the query on a scale from 1 to 10...

Query: {query}

Documents:
{documents}

Return ONLY a JSON array with the scores in this exact format:
[{"doc_index": 0, "score": 8}, {"doc_index": 1, "score": 5}, ...]
```

### Score Normalization

When `normalize_scores: true`:
- Maps LLM scores (1-10) to 0-1 range
- Formula: `(score - min) / (max - min)`
- Equal scores normalize to 1.0

## Passthrough Reranker

Returns documents unchanged. Useful for testing.

```elixir
alias Rag.Reranker
alias Rag.Reranker.Passthrough

reranker = %Passthrough{}

# Documents returned unchanged
{:ok, same_docs} = Reranker.rerank(reranker, "query", documents)
```

## Complete RAG Pipeline

```elixir
alias Rag.Router
alias Rag.Retriever
alias Rag.Retriever.Hybrid
alias Rag.Reranker
alias Rag.Reranker.LLM

# Setup
{:ok, router} = Router.new(providers: [:gemini])
query = "How does GenServer handle state?"

# 1. Get query embedding
{:ok, [embedding], router} = Router.execute(router, :embeddings, [query], [])

# 2. Hybrid retrieval
retriever = %Hybrid{repo: Repo}
{:ok, results} = Retriever.retrieve(retriever, {embedding, query}, limit: 20)

# 3. Rerank with LLM
reranker = LLM.new(router: router)
{:ok, reranked} = Reranker.rerank(reranker, query, results,
  top_k: 5,
  normalize_scores: true
)

# 4. Build context from top results
context = reranked
  |> Enum.map(fn doc ->
    "- #{doc.content} (Score: #{Float.round(doc.score, 2)})"
  end)
  |> Enum.join("\n")

# 5. Generate answer
rag_prompt = """
Answer based on the following context:

#{context}

Question: #{query}
"""

{:ok, answer, _} = Router.execute(router, :text, rag_prompt, [])
IO.puts(answer)
```

## Comparison: With vs Without Reranking

```elixir
# Without reranking - use initial retrieval scores
{:ok, results} = Retriever.retrieve(hybrid_retriever, {embedding, query}, limit: 5)

# With reranking - LLM improves relevance ordering
{:ok, results} = Retriever.retrieve(hybrid_retriever, {embedding, query}, limit: 20)
{:ok, reranked} = Reranker.rerank(reranker, query, results, top_k: 5)
```

**Benefits of reranking:**
- More accurate relevance scoring
- Better context for answer generation
- Handles retriever score inconsistencies
- Can catch false positives from vector search

**Trade-offs:**
- Additional LLM API call
- Increased latency
- Higher cost

## Pipeline Integration

```elixir
alias Rag.Pipeline

Pipeline.new(:rag_with_rerank)
|> Pipeline.add_step(
  name: :retrieve,
  module: Steps,
  function: :retrieve,
  args: [limit: 20]
)
|> Pipeline.add_step(
  name: :rerank,
  module: Steps,
  function: :rerank,
  inputs: [:retrieve],
  args: [top_k: 5],
  on_error: :continue  # Skip reranking on error
)
|> Pipeline.add_step(
  name: :generate,
  module: Steps,
  function: :generate,
  inputs: [:rerank]
)
```

## Best Practices

1. **Retrieve more, rerank fewer** - Get 20 results, rerank to 5
2. **Use with hybrid search** - Reranking helps reconcile different scores
3. **Handle errors gracefully** - Fall back to unreranked results
4. **Normalize scores** - For consistent downstream processing
5. **Consider cost** - Reranking adds an LLM call

## Next Steps

- [Retrievers](retrievers.md) - Different retrieval strategies
- [Pipeline](pipelines.md) - Build complete RAG workflows
