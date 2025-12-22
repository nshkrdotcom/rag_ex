# CHANGELOG

## v0.3.1 (2025-12-21)

### Fixes
* Made Ecto/pgvector dependencies optional - modules using Ecto.Schema and Ecto.Query are now conditionally compiled only when Ecto is available
* Projects can now use rag_ex without PostgreSQL/Ecto by omitting those dependencies

## v0.3.0 (2025-12-21)

### Major Features
* **Modular RAG Architecture**: Complete overhaul for configurable RAG pipelines
  * `Rag.Retriever` behaviour with Semantic, FullText, Hybrid, and Graph implementations
  * `Rag.VectorStore.Store` behaviour for pluggable vector backends
  * `Rag.GraphStore` behaviour for knowledge graph storage (pgvector and Neo4j ready)
  * `Rag.Reranker` behaviour with LLM-based reranking
* **GraphRAG Support**: Knowledge graph-enhanced retrieval
  * Entity and relationship extraction via LLM
  * Community detection with summarization
  * Local, global, and hybrid graph search modes
  * PostgreSQL-based graph storage with recursive CTEs
* **Advanced Chunking Strategies**: Flexible text splitting
  * Character-based chunking with smart boundaries
  * Sentence-based chunking
  * Semantic chunking with embedding similarity
  * Recursive chunking for hierarchical documents
* **Pipeline System**: Composable RAG pipelines
  * `Rag.Pipeline` struct for pipeline definitions
  * `Rag.Pipeline.Executor` for step orchestration
  * Parallel step execution with caching
  * Error handling and retry logic
* **Reranking**: Improve retrieval quality
  * LLM-based reranking with configurable prompts
  * Cross-encoder style relevance scoring
  * Cohere reranker integration ready
* **Multi-LLM Provider Support**: Add `Rag.Ai.Gemini`, `Rag.Ai.Claude`, and `Rag.Ai.Codex` providers for Gemini, Claude, and OpenAI-compatible APIs
* **Smart Router**: New `Rag.Router` module with pluggable routing strategies:
  * `Rag.Router.Fallback` - Try providers in order until one succeeds
  * `Rag.Router.RoundRobin` - Distribute load across providers
  * `Rag.Router.Specialist` - Route based on task type
* **Vector Store**: New `Rag.VectorStore` module with pgvector integration:
  * Semantic search with embeddings
  * Full-text search with PostgreSQL tsvector
  * Hybrid search with RRF (Reciprocal Rank Fusion) scoring
  * Text chunking with overlap support
  * `Rag.VectorStore.Chunk` Ecto schema for document storage
* **Embedding Service**: New `Rag.Embedding.Service` GenServer for managed embedding operations with auto-batching
* **Agent Framework**: New `Rag.Agent` module for building tool-using agents:
  * `Rag.Agent.Session` for conversation memory management
  * `Rag.Agent.Registry` for tool registration
  * `Rag.Agent.Tool` behaviour for custom tools
* **Built-in Agent Tools**:
  * `Rag.Agent.Tools.SearchRepos` - Semantic search over indexed repositories
  * `Rag.Agent.Tools.ReadFile` - Read file contents with optional line ranges
  * `Rag.Agent.Tools.GetRepoContext` - Get repository structure and metadata
  * `Rag.Agent.Tools.AnalyzeCode` - Parse and analyze code structure
* **Provider Capabilities**: New `Rag.Ai.Capabilities` module to check provider feature support

### Enhancements
* New live examples for all major features
* Comprehensive test coverage with supertester principles
* Updated documentation with modular RAG guides

### Breaking Changes
* Removed igniter-based Mix tasks: `rag.install`, `rag.gen_rag_module`, `rag.gen_servings`, `rag.gen_eval`
* Library no longer includes its own Ecto Repo - consuming applications must provide their own

### Dependencies
* Added `pgvector`, `ecto_sql`, `postgrex` for vector store functionality
* Temporarily disabled `torus` and `igniter` due to Elixir 1.18 compatibility issues with `inflex`

## v0.2.3
* Add `Rag.Ai.Ollama` as ollama provider
* Add `build_context/3`, `build_context_sources/3`, `build_prompt/3` to enable full pipeline interface
* Enable streaming of responses (@W3NDO, thank you for your contribution!)

## v0.2.2
* Add `ref` to `Generation` for referencing in telemetry handler

## v0.2.1

* fix credo issues in generator
* helpful error for missing servings in nx provider
* fix typespecs with optional fields
* more robust fulltext search with postgres in generator

## v0.2.0

* syntax updates
* unified embedding, generation, and evaluation modules

## v0.1.0

* initial release
