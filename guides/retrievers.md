# Retrievers

Retrievers provide different strategies for finding relevant documents based on queries.

## Overview

The library provides four retriever implementations:

| Retriever | Method | Query Type | Best For |
|-----------|--------|------------|----------|
| **Semantic** | Vector similarity | Embedding | Conceptual matching |
| **FullText** | Keyword matching | Text | Exact keywords |
| **Hybrid** | RRF fusion | Both | Balanced results |
| **Graph** | Knowledge graph | Both | Entity relationships |

## Retriever Behaviour

All retrievers implement the `Rag.Retriever` behaviour:

```elixir
@callback retrieve(retriever, query, opts) :: {:ok, [result()]} | {:error, term()}

@type result :: %{
  id: any(),
  content: String.t(),
  score: float(),
  metadata: map()
}
```

## Semantic Retriever

Uses pgvector L2 distance for vector similarity search.

```elixir
alias Rag.Retriever
alias Rag.Retriever.Semantic

# Create retriever
retriever = %Semantic{repo: MyApp.Repo}

# Search with embedding
{:ok, results} = Retriever.retrieve(retriever, query_embedding, limit: 10)
```

**Scoring:**
- Score = 1.0 - L2_distance
- Range: 0.0 (dissimilar) to 1.0 (identical)

**Capabilities:**
- `supports_embedding?()` - true
- `supports_text_query?()` - false

**Best for:**
- Finding conceptually similar content
- When query meaning matters more than exact words

## FullText Retriever

Uses PostgreSQL tsvector for keyword matching.

```elixir
alias Rag.Retriever
alias Rag.Retriever.FullText

# Create retriever
retriever = %FullText{repo: MyApp.Repo}

# Search with text
{:ok, results} = Retriever.retrieve(retriever, "GenServer state", limit: 10)
```

**Scoring:**
- Score from PostgreSQL ts_rank function
- Multiple terms combined with AND

**Capabilities:**
- `supports_embedding?()` - false
- `supports_text_query?()` - true

**Best for:**
- Finding documents with specific keywords
- Technical term searches
- When exact matches matter

## Hybrid Retriever

Combines semantic and full-text using Reciprocal Rank Fusion (RRF).

```elixir
alias Rag.Retriever
alias Rag.Retriever.Hybrid

# Create retriever
retriever = %Hybrid{repo: MyApp.Repo}

# Search with both embedding and text
{:ok, results} = Retriever.retrieve(retriever, {embedding, "search text"}, limit: 10)
```

**Query Format:**
- Tuple of `{embedding_vector, text_query}`

**Scoring (RRF):**
```
RRF(d) = Σ 1 / (k + rank(d))  where k = 60
```
- Documents in both result sets get combined scores
- Balances semantic understanding with keyword precision

**Capabilities:**
- `supports_embedding?()` - true
- `supports_text_query?()` - true

**Best for:**
- Balanced semantic + keyword search
- When you want best of both methods
- Production RAG systems

## Graph Retriever

Uses knowledge graph structure for context-aware retrieval.

```elixir
alias Rag.Retriever.Graph

# Create retriever
retriever = Graph.new(
  graph_store: graph_store,
  vector_store: vector_store,
  mode: :hybrid,
  depth: 2,
  local_weight: 0.7,
  global_weight: 0.3
)

# Search
{:ok, results} = Retriever.retrieve(retriever, query_embedding,
  limit: 10,
  embedding_fn: &embed/1
)
```

### Search Modes

**Local Search (`:local`)**
- Vector search on entity embeddings
- Graph traversal to related entities
- Collect source chunks from entities
- Score by graph distance

```elixir
{:ok, results} = Graph.local_search(retriever, query, limit: 10)
```

**Global Search (`:global`)**
- Vector search on community summaries
- Returns high-level context
- Good for overview questions

```elixir
{:ok, results} = Graph.global_search(retriever, query, limit: 10)
```

**Hybrid Search (`:hybrid`)**
- Runs local and global in parallel
- Combines with weighted RRF
- Best of both approaches

```elixir
{:ok, results} = Graph.hybrid_search(retriever, query, limit: 10)
```

### Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `graph_store` | required | Graph store module |
| `vector_store` | required | Vector store module |
| `mode` | `:local` | Search mode |
| `depth` | 2 | Graph traversal depth |
| `local_weight` | 1.0 | Weight for local in hybrid |
| `global_weight` | 1.0 | Weight for global in hybrid |

## Scoring Comparison

| Retriever | Score Source | Range | Formula |
|-----------|--------------|-------|---------|
| Semantic | L2 distance | 0-1 | `1.0 - distance` |
| FullText | ts_rank | 0-1+ | PostgreSQL rank |
| Hybrid | RRF | varies | `Σ 1/(60+rank)` |
| Graph Local | Depth | 0-1 | `1/(1+depth)` |
| Graph Global | Rank | 0-1 | `1/(1+rank)` |

## Complete Example

```elixir
alias Rag.Router
alias Rag.Retriever
alias Rag.Retriever.{Semantic, FullText, Hybrid}
alias Rag.Reranker
alias Rag.Reranker.LLM

# Setup
{:ok, router} = Router.new(providers: [:gemini])
query = "How does GenServer handle state?"

# Get query embedding
{:ok, [query_embedding], router} = Router.execute(router, :embeddings, [query], [])

# Semantic search
semantic_retriever = %Semantic{repo: Repo}
{:ok, semantic_results} = Retriever.retrieve(semantic_retriever, query_embedding, limit: 10)

# Full-text search
fulltext_retriever = %FullText{repo: Repo}
{:ok, fulltext_results} = Retriever.retrieve(fulltext_retriever, query, limit: 10)

# Hybrid search
hybrid_retriever = %Hybrid{repo: Repo}
{:ok, hybrid_results} = Retriever.retrieve(hybrid_retriever, {query_embedding, query}, limit: 10)

# Compare results
IO.puts("Semantic: #{length(semantic_results)} results")
IO.puts("FullText: #{length(fulltext_results)} results")
IO.puts("Hybrid: #{length(hybrid_results)} results")

# Rerank hybrid results
reranker = LLM.new(router: router)
{:ok, reranked} = Reranker.rerank(reranker, query, hybrid_results, top_k: 5)

# Use top results for RAG
context = Enum.map(reranked, & &1.content) |> Enum.join("\n\n")
```

## Choosing a Retriever

**Use Semantic when:**
- Query meaning matters more than keywords
- Finding conceptually similar content
- Working with paraphrased queries

**Use FullText when:**
- Searching for specific terms
- Technical/domain-specific queries
- Exact keyword matching needed

**Use Hybrid when:**
- Want balanced results
- Building production RAG systems
- Unsure which method works best

**Use Graph when:**
- Entity relationships matter
- Need multi-hop reasoning
- Building knowledge-intensive applications

## Pipeline Integration

```elixir
# In a pipeline step
def retrieve_step(input, context, _opts) do
  retriever = %Hybrid{repo: context.repo}
  embedding = Context.get_step_result(context, :embed_query)
  query = context.query

  case Retriever.retrieve(retriever, {embedding, query}, limit: 10) do
    {:ok, results} -> {:ok, results}
    {:error, reason} -> {:error, reason}
  end
end
```

## Next Steps

- [Rerankers](rerankers.md) - Improve retrieval quality with reranking
- [GraphRAG](graph_rag.md) - Build knowledge graphs for retrieval
- [Pipeline](pipelines.md) - Combine retrievers in workflows
