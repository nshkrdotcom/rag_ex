# RAG Library Examples

This directory contains runnable examples demonstrating the RAG library features.

## Prerequisites

Set at least one API key:

```bash
# Gemini (recommended - supports embeddings)
export GEMINI_API_KEY="your-api-key"

# Claude (best for analysis and reasoning)
export ANTHROPIC_API_KEY="your-api-key"

# OpenAI/Codex (best for code generation)
export OPENAI_API_KEY="your-api-key"
# or
export CODEX_API_KEY="your-api-key"
```

For database examples, you'll need PostgreSQL with pgvector:
```bash
# Install pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;
```

## Running Examples

All examples run from the project root using `mix run`:

```bash
# Run a single example
mix run examples/basic_chat.exs

# Run all examples
./examples/run_all.sh

# Run only quick examples (no DB required)
./examples/run_all.sh --quick

# Skip database-dependent examples
./examples/run_all.sh --skip-db
```

## Available Examples

### Basic Examples

#### basic_chat.exs

Simple LLM interaction using the Router.

**Demonstrates:**
- Creating a router with a single provider
- Simple text generation
- Using system prompts
- Multiple conversation exchanges

---

#### routing_strategies.exs

Multi-LLM provider routing strategies.

**Demonstrates:**
- Provider capabilities inspection
- Fallback strategy (try providers in order)
- Round-robin strategy (load distribution)
- Specialist strategy (route by task type)
- Filtering providers by capability

---

### Router & Agent Examples

#### multi_llm_router.exs

**Comprehensive demonstration of the Multi-LLM Router system.**

**Demonstrates:**
- Automatic provider detection based on environment variables
- Provider capabilities inspection and comparison
- All three routing strategies: Fallback, Round-Robin, Specialist
- Task-based provider selection (code, analysis, embeddings, etc.)
- Text generation with various options (system prompt, temperature)
- Streaming responses
- Automatic failure handling and provider fallback
- Embeddings generation
- Runtime capability checking
- Cost and performance considerations

**API Keys:** Works with any combination of Gemini, Claude, and Codex. Gracefully handles missing providers.

---

#### agent.exs

Agent framework with tool usage.

**Demonstrates:**
- Creating a tool registry
- Tool parameter schemas
- Direct tool execution (analyze_code)
- Session memory management
- Agent creation and configuration
- Formatting tools for LLM consumption

---

### Text Processing Examples

#### chunking_strategies.exs

Text chunking strategies for document processing.

**Demonstrates:**
- Character-based chunking (fixed size with overlap)
- Sentence-based chunking (preserve sentence boundaries)
- Paragraph-based chunking (preserve topic boundaries)
- Recursive chunking (hierarchical splitting)
- Semantic chunking (embedding-based similarity)
- Format-aware chunking (TextChunker adapter)
- Chunk overlap configuration
- Strategy comparison and selection guide

**Note:** Format-aware chunking requires TextChunker (`{:text_chunker, "~> 0.5.2"}`). Semantic chunking requires GEMINI_API_KEY and falls back to mock embeddings if not available.

---

#### vector_store.exs

Building and querying a vector store.

**Demonstrates:**
- Building chunks from documents
- Generating embeddings via Router
- In-memory semantic search with cosine similarity
- Text chunking with overlap

**Note:** Runs in-memory without database. For database persistence, see the `rag_demo` example.

---

### RAG Workflow Examples

#### basic_rag.exs

**Complete end-to-end RAG workflow with real database and APIs.**

**Demonstrates:**
- Document ingestion and chunking
- Embedding generation via Router
- Vector storage in PostgreSQL with pgvector
- Semantic search retrieval
- Context building for LLM
- RAG answer generation
- Multiple retrieval methods comparison

**Prerequisites:**
- PostgreSQL with pgvector extension
- GEMINI_API_KEY (or other provider)
- Database tables created via migrations

**Run with:**
```bash
mix run examples/basic_rag.exs
```

---

#### hybrid_search.exs

**Comprehensive hybrid search demonstration with semantic, full-text, and RRF fusion.**

**Demonstrates:**
- Semantic search (vector similarity)
- Full-text search (PostgreSQL tsvector)
- Hybrid search with Reciprocal Rank Fusion (RRF)
- Side-by-side comparison of search methods
- LLM-based reranking with `Rag.Reranker.LLM`
- Complete RAG pipeline with answer generation
- Score normalization and result merging

**Prerequisites:**
- PostgreSQL with pgvector extension
- Full-text search index on content column
- GEMINI_API_KEY (or other provider)

**Run with:**
```bash
mix run examples/hybrid_search.exs
```

**Key Concepts:**
- Semantic search finds conceptually similar content
- Full-text search matches exact keywords and phrases
- Hybrid search combines both for better recall and precision
- RRF merges rankings without requiring score normalization
- Reranking uses LLM to score relevance more accurately

---

### GraphRAG Examples

#### graph_rag.exs

**Complete GraphRAG workflow demonstration showing knowledge graph construction and retrieval.**

**Demonstrates:**
- Entity and relationship extraction from text using LLM (Rag.GraphRAG.Extractor)
- Entity resolution and deduplication
- Embedding generation for entities
- Knowledge graph storage in PostgreSQL with pgvector (Rag.GraphStore.Pgvector)
- Community detection using label propagation (Rag.GraphRAG.CommunityDetector)
- Graph traversal (BFS and DFS algorithms)
- Graph-based retrieval with three modes (Rag.Retriever.Graph):
  - **Local Search**: Vector search + graph expansion for specific queries
  - **Global Search**: Community summary search for broad context
  - **Hybrid Search**: RRF-merged combination of local and global
- Vector similarity search on entities
- Hierarchical community detection

**Prerequisites:**
- PostgreSQL database with pgvector extension
- GEMINI_API_KEY or other LLM provider API key
- Graph tables (graph_entities, graph_edges, graph_communities) created via migrations

**Run with:**
```bash
mix run examples/graph_rag.exs
```

**Key Concepts:**
- GraphRAG extends traditional RAG by building a knowledge graph from documents
- Entities and relationships are extracted using LLM prompts
- Communities represent clusters of related entities
- Graph structure enables better contextual retrieval
- Local search provides detailed context, global search provides high-level summaries
- Hybrid search combines both for comprehensive results

---

### Pipeline Examples

#### pipeline_example.exs

**Complete working Pipeline system demonstration with real database and APIs.**

**Demonstrates:**
- Creating multi-step RAG pipelines
- Sequential and parallel step execution
- Context passing between steps
- Error handling strategies (halt, continue, retry)
- Caching expensive operations (embeddings)
- Timeout configuration
- Real PostgreSQL + pgvector integration
- Real LLM API calls (Gemini)
- Complete RAG workflow (query → embed → retrieve → rerank → generate)
- Hybrid search with RRF (semantic + full-text)
- Document ingestion pipeline

**Prerequisites:**
- PostgreSQL with pgvector extension
- GEMINI_API_KEY environment variable
- Database setup: `cd examples/rag_demo && mix setup`

**Run with:**
```bash
cd examples/rag_demo && mix run ../pipeline_example.exs
```

**See:** [PIPELINE_EXAMPLE_README.md](PIPELINE_EXAMPLE_README.md) for detailed documentation.

---

## Example Summary

| Example | Requires DB | API Calls | Complexity |
|---------|-------------|-----------|------------|
| basic_chat.exs | No | Yes | Basic |
| routing_strategies.exs | No | Yes | Basic |
| multi_llm_router.exs | No | Yes | Intermediate |
| agent.exs | No | Yes | Intermediate |
| chunking_strategies.exs | No | Optional | Basic |
| vector_store.exs | No | Yes | Basic |
| basic_rag.exs | Yes | Yes | Intermediate |
| hybrid_search.exs | Yes | Yes | Intermediate |
| graph_rag.exs | Yes | Yes | Advanced |
| pipeline_example.exs | Yes | Yes | Advanced |

## Full Demo Application

For a complete end-to-end example with database persistence, see:

```
examples/rag_demo/
```

This demonstrates:
- Phoenix app integration
- Database setup with pgvector
- Document ingestion pipeline
- Semantic search with stored embeddings
