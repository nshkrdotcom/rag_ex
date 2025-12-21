# RAG Library Examples

This directory contains runnable examples demonstrating the RAG library features.

## Prerequisites

Set your API key:

```bash
export GEMINI_API_KEY="your-api-key"
```

## Running Examples

All examples run from the project root using `mix run`:

```bash
# Run a single example
mix run examples/basic_chat.exs

# Run all examples
./examples/run_all.sh
```

## Available Examples

### basic_chat.exs

Simple LLM interaction using the Router.

**Demonstrates:**
- Creating a router with a single provider
- Simple text generation
- Using system prompts
- Multiple conversation exchanges

### routing_strategies.exs

Multi-LLM provider routing strategies.

**Demonstrates:**
- Provider capabilities inspection
- Fallback strategy (try providers in order)
- Round-robin strategy (load distribution)
- Specialist strategy (route by task type)
- Filtering providers by capability

### agent.exs

Agent framework with tool usage.

**Demonstrates:**
- Creating a tool registry
- Tool parameter schemas
- Direct tool execution (analyze_code)
- Session memory management
- Agent creation and configuration
- Formatting tools for LLM consumption

### vector_store.exs

Building and querying a vector store.

**Demonstrates:**
- Building chunks from documents
- Generating embeddings via Router
- In-memory semantic search with cosine similarity
- Text chunking with overlap

**Note:** Runs in-memory without database. For database persistence, see the `rag_demo` example.

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
