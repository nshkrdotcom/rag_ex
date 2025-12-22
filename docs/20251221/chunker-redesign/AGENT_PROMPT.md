# Agent Prompt: Implement Chunker Redesign

## Mission

Implement the `Rag.Chunker` behavior-based chunking system to replace the monolithic `Rag.Chunking` module. This is a breaking change - no backwards compatibility needed. Use TDD throughout.

---

## Required Reading

### Design Documents (READ FIRST)

Read these in order before writing any code:

1. `docs/20251221/chunker-redesign/README.md` - Overview and goals
2. `docs/20251221/chunker-redesign/design.md` - Full architecture specification
3. `docs/20251221/chunker-redesign/api.md` - API reference
4. `docs/20251221/chunker-redesign/examples.md` - Usage patterns
5. `docs/20251221/chunker-redesign/implementation.md` - Implementation checklist and code templates

### Source Files to Understand

Read these to understand current implementation and patterns:

```
# Current chunking (TO BE REPLACED)
lib/rag/chunking.ex
test/rag/chunking_test.exs

# Behavior patterns to match (REFERENCE)
lib/rag/retriever.ex
lib/rag/retriever/semantic.ex
lib/rag/reranker.ex
lib/rag/ai/provider.ex

# Integration points
lib/rag/vector_store.ex
lib/rag/vector_store/chunk.ex
lib/rag/pipeline.ex
lib/rag/pipeline/executor.ex
lib/rag/loading.ex
lib/rag/embedding.ex

# TextChunker (external library to adapt)
text_chunker_ex/lib/text_chunker.ex
text_chunker_ex/lib/text_chunker/chunk.ex
text_chunker_ex/lib/text_chunker/strategies/recursive_chunk/recursive_chunk.ex
```

### Documentation to Update

Find and update ALL of these:

```
README.md
docs/**/*.md
guides/**/*.md
```

Use `find . -name "*.md" -not -path "./text_chunker_ex/*" -not -path "./_build/*" -not -path "./deps/*"` to locate all markdown files.

---

## Context

### Why This Change

1. `Rag.Chunking` uses case-statement dispatch - inconsistent with rest of library
2. Other components use behaviors: `Retriever`, `Reranker`, `Provider`, `VectorStore.Store`
3. No byte position tracking in current chunks - can't highlight source locations
4. No way to integrate external chunkers like TextChunker
5. Need extensibility for custom chunking strategies

### What's Changing

| Before | After |
|--------|-------|
| `Rag.Chunking.chunk(text, strategy: :character)` | `Rag.Chunker.chunk(%Chunker.Character{}, text)` |
| `%{content, index, metadata}` maps | `%Rag.Chunker.Chunk{}` structs |
| No byte positions | `start_byte`, `end_byte` on all chunks |
| Closed strategies | Open via `@behaviour Rag.Chunker` |
| No TextChunker integration | `Rag.Chunker.FormatAware` adapter |

---

## Implementation Instructions

### Phase 1: Core Infrastructure (TDD)

#### 1.1 Create Chunk Struct

**Test first:** `test/rag/chunker/chunk_test.exs`

```elixir
defmodule Rag.Chunker.ChunkTest do
  use ExUnit.Case, async: true
  alias Rag.Chunker.Chunk

  describe "new/1" do
    test "creates chunk with required fields" do
      chunk = Chunk.new(%{
        content: "hello",
        start_byte: 0,
        end_byte: 5,
        index: 0
      })

      assert chunk.content == "hello"
      assert chunk.start_byte == 0
      assert chunk.end_byte == 5
      assert chunk.index == 0
      assert chunk.metadata == %{}
    end

    test "accepts metadata" do
      chunk = Chunk.new(%{
        content: "hello",
        start_byte: 0,
        end_byte: 5,
        index: 0,
        metadata: %{chunker: :test}
      })

      assert chunk.metadata == %{chunker: :test}
    end

    test "raises on missing required fields" do
      assert_raise KeyError, fn ->
        Chunk.new(%{content: "hello"})
      end
    end
  end

  describe "extract_from_source/2" do
    test "extracts content using byte positions" do
      source = "Hello world, this is a test."
      chunk = Chunk.new(%{content: "world", start_byte: 6, end_byte: 11, index: 0})

      assert Chunk.extract_from_source(chunk, source) == "world"
    end

    test "handles Unicode" do
      source = "Hello 世界 test"
      # "世界" is 6 bytes (2 chars × 3 bytes each)
      chunk = Chunk.new(%{content: "世界", start_byte: 6, end_byte: 12, index: 0})

      assert Chunk.extract_from_source(chunk, source) == "世界"
    end
  end

  describe "valid?/2" do
    test "returns true when positions match content" do
      source = "Hello world"
      chunk = Chunk.new(%{content: "Hello", start_byte: 0, end_byte: 5, index: 0})

      assert Chunk.valid?(chunk, source)
    end

    test "returns false when positions don't match" do
      source = "Hello world"
      chunk = Chunk.new(%{content: "Hello", start_byte: 0, end_byte: 6, index: 0})

      refute Chunk.valid?(chunk, source)
    end
  end
end
```

**Then implement:** `lib/rag/chunker/chunk.ex`

#### 1.2 Create Behavior Module

**Test first:** `test/rag/chunker_test.exs`

```elixir
defmodule Rag.ChunkerTest do
  use ExUnit.Case, async: true
  alias Rag.Chunker

  # Define a test chunker
  defmodule TestChunker do
    @behaviour Rag.Chunker
    defstruct prefix: "chunk"

    @impl true
    def default_opts, do: [prefix: "chunk"]

    @impl true
    def chunk(%__MODULE__{} = chunker, text, opts) do
      prefix = opts[:prefix] || chunker.prefix
      [Rag.Chunker.Chunk.new(%{
        content: "#{prefix}: #{text}",
        start_byte: 0,
        end_byte: byte_size(text),
        index: 0,
        metadata: %{chunker: :test}
      })]
    end
  end

  describe "chunk/3" do
    test "dispatches to chunker implementation" do
      chunker = %TestChunker{}
      [chunk] = Chunker.chunk(chunker, "hello")

      assert chunk.content == "chunk: hello"
    end

    test "merges default opts with runtime opts" do
      chunker = %TestChunker{prefix: "default"}
      [chunk] = Chunker.chunk(chunker, "hello", prefix: "override")

      assert chunk.content == "override: hello"
    end
  end

  describe "chunk_ingestion/3" do
    test "adds chunks to ingestion map" do
      chunker = %TestChunker{}
      ingestion = %{source: "test.txt", document: "hello"}

      result = Chunker.chunk_ingestion(chunker, ingestion)

      assert Map.has_key?(result, :chunks)
      assert length(result.chunks) == 1
      assert result.source == "test.txt"
    end
  end
end
```

**Then implement:** `lib/rag/chunker.ex`

### Phase 2: Built-in Chunkers (TDD)

For each chunker, follow this pattern:

1. Write comprehensive tests first
2. Port logic from `lib/rag/chunking.ex`
3. Add byte position tracking
4. Ensure all tests pass

#### Order of Implementation

1. **Character** - Simplest, good reference
2. **Sentence** - Builds on sentence splitting logic
3. **Paragraph** - Similar to sentence
4. **Recursive** - Composes above strategies
5. **Semantic** - Most complex, needs embedding_fn
6. **FormatAware** - TextChunker adapter

#### Test Requirements for Each Chunker

Each chunker test file must include:

```elixir
describe "chunk/3" do
  test "returns list of Chunk structs"
  test "respects max_chars limit"
  test "byte positions are accurate (using Chunk.valid?)"
  test "handles empty text"
  test "handles text shorter than max_chars"
  test "handles Unicode correctly"
  test "handles emoji and composite graphemes"
  test "sequential indexes starting at 0"
  test "metadata includes chunker type"
  # Strategy-specific tests...
end
```

#### Porting Logic

The existing implementations in `lib/rag/chunking.ex` are correct - port the algorithm but add byte tracking:

- `chunk_by_character/3` → `Rag.Chunker.Character`
- `chunk_by_sentence/3` → `Rag.Chunker.Sentence`
- `chunk_by_paragraph/3` → `Rag.Chunker.Paragraph`
- `chunk_recursive/3` → `Rag.Chunker.Recursive`
- `chunk_by_semantic/4` → `Rag.Chunker.Semantic`

**Critical:** Track byte positions as you split. Use `byte_size/1` not `String.length/1` for positions.

### Phase 3: FormatAware Chunker

This adapts TextChunker. Handle the optional dependency:

```elixir
defmodule Rag.Chunker.FormatAware do
  @behaviour Rag.Chunker

  @impl true
  def chunk(%__MODULE__{} = chunker, text, opts) do
    unless Code.ensure_loaded?(TextChunker) do
      raise """
      FormatAware chunker requires TextChunker.
      Add to your mix.exs deps:

          {:text_chunker, "~> 0.5.2"}
      """
    end

    # ... implementation
  end
end
```

**Test with:** Conditionally skip if TextChunker not available:

```elixir
@moduletag :format_aware

setup do
  unless Code.ensure_loaded?(TextChunker) do
    raise ExUnit.AssertionError, "TextChunker required for these tests"
  end
  :ok
end
```

### Phase 4: VectorStore Integration

Update `lib/rag/vector_store.ex`:

```elixir
@doc """
Convert Chunker.Chunk structs to VectorStore format.
"""
def from_chunker_chunks(chunks, source) when is_list(chunks) do
  Enum.map(chunks, fn %Rag.Chunker.Chunk{} = chunk ->
    build_chunk(%{
      content: chunk.content,
      source: source,
      metadata: Map.merge(chunk.metadata, %{
        start_byte: chunk.start_byte,
        end_byte: chunk.end_byte,
        chunk_index: chunk.index
      })
    })
  end)
end
```

Add tests in `test/rag/vector_store_test.exs`.

### Phase 5: Delete Old Code

After all new tests pass:

```bash
rm lib/rag/chunking.ex
rm test/rag/chunking_test.exs
```

### Phase 6: Update All Documentation

#### Find All Docs

```bash
find . -name "*.md" -not -path "./text_chunker_ex/*" -not -path "./_build/*" -not -path "./deps/*" -not -path "./.git/*"
```

#### Update Pattern

Search for and replace:

| Find | Replace With |
|------|--------------|
| `Rag.Chunking.chunk` | `Rag.Chunker.chunk` |
| `strategy: :character` | `%Rag.Chunker.Character{}` |
| `strategy: :sentence` | `%Rag.Chunker.Sentence{}` |
| `strategy: :paragraph` | `%Rag.Chunker.Paragraph{}` |
| `strategy: :recursive` | `%Rag.Chunker.Recursive{}` |
| `strategy: :semantic` | `%Rag.Chunker.Semantic{}` |
| `chunk.metadata.strategy` | `chunk.metadata.chunker` |

#### README.md Updates

- Update feature list to mention behavior-based chunking
- Update quick start examples
- Update API overview
- Update version badge if present

#### Guides Updates

Each guide mentioning chunking needs:

1. New import/alias statements
2. Updated function calls
3. Updated output format expectations
4. New examples showing byte positions

### Phase 7: Update Examples

Find all example files:

```bash
find . -path "./examples/*" -name "*.ex" -o -path "./examples/*" -name "*.exs"
```

Update each to use new chunker API.

### Phase 8: Version Bump

#### mix.exs

Find current version and increment patch:
- `0.3.3` → `0.3.4`

```elixir
def project do
  [
    app: :rag_ex,
    version: "0.3.4",  # Updated
    ...
  ]
end
```

#### README.md

Update version references:
```markdown
{:rag_ex, "~> 0.3.4"}
```

#### Create Changelog Entry

Create or update `CHANGELOG.md`:

```markdown
# Changelog

## [0.3.4] - 2025-12-21

### Breaking Changes

- **Chunking API redesigned**: Replaced `Rag.Chunking` module with behavior-based `Rag.Chunker` system
  - Old: `Rag.Chunking.chunk(text, strategy: :character, max_chars: 500)`
  - New: `Rag.Chunker.chunk(%Rag.Chunker.Character{max_chars: 500}, text)`

### Added

- `Rag.Chunker` behaviour for extensible chunking strategies
- `Rag.Chunker.Chunk` struct with byte position tracking (`start_byte`, `end_byte`)
- Built-in chunkers:
  - `Rag.Chunker.Character` - Fixed-size with smart boundaries
  - `Rag.Chunker.Sentence` - Sentence-boundary splitting
  - `Rag.Chunker.Paragraph` - Paragraph-boundary splitting
  - `Rag.Chunker.Recursive` - Hierarchical (paragraph → sentence → character)
  - `Rag.Chunker.Semantic` - Embedding-based similarity grouping
  - `Rag.Chunker.FormatAware` - Format-aware splitting via TextChunker (19 formats)
- `Rag.Chunker.chunk_ingestion/3` for pipeline integration
- `Rag.VectorStore.from_chunker_chunks/2` for VectorStore integration
- Byte-accurate position tracking enables source highlighting

### Removed

- `Rag.Chunking` module (replaced by `Rag.Chunker` behavior)

### Migration Guide

See `docs/20251221/chunker-redesign/implementation.md` for detailed migration instructions.
```

---

## Quality Checklist

### All Tests Pass

```bash
mix test
```

Must be green with no failures.

### No Warnings

```bash
mix compile --warnings-as-errors
```

Must compile cleanly.

### No Dialyzer Errors

```bash
mix dialyzer
```

Must pass. Add typespecs to all public functions:

```elixir
@spec chunk(t(), String.t(), keyword()) :: [Chunk.t()]
```

### Code Formatting

```bash
mix format --check-formatted
```

Run `mix format` before committing.

### Documentation

```bash
mix docs
```

Generate and review. All public modules and functions need `@moduledoc` and `@doc`.

---

## File Checklist

### Create

- [ ] `lib/rag/chunker.ex`
- [ ] `lib/rag/chunker/chunk.ex`
- [ ] `lib/rag/chunker/character.ex`
- [ ] `lib/rag/chunker/sentence.ex`
- [ ] `lib/rag/chunker/paragraph.ex`
- [ ] `lib/rag/chunker/recursive.ex`
- [ ] `lib/rag/chunker/semantic.ex`
- [ ] `lib/rag/chunker/format_aware.ex`
- [ ] `test/rag/chunker_test.exs`
- [ ] `test/rag/chunker/chunk_test.exs`
- [ ] `test/rag/chunker/character_test.exs`
- [ ] `test/rag/chunker/sentence_test.exs`
- [ ] `test/rag/chunker/paragraph_test.exs`
- [ ] `test/rag/chunker/recursive_test.exs`
- [ ] `test/rag/chunker/semantic_test.exs`
- [ ] `test/rag/chunker/format_aware_test.exs`
- [ ] `CHANGELOG.md` (or update if exists)

### Delete

- [ ] `lib/rag/chunking.ex`
- [ ] `test/rag/chunking_test.exs`

### Update

- [ ] `lib/rag/vector_store.ex` - Add `from_chunker_chunks/2`
- [ ] `test/rag/vector_store_test.exs` - Add tests for new function
- [ ] `mix.exs` - Bump version
- [ ] `README.md` - Update version, examples, docs
- [ ] All guides in `docs/` and `guides/`
- [ ] All examples in `examples/`

---

## Success Criteria

1. `mix test` - All tests pass
2. `mix compile --warnings-as-errors` - No warnings
3. `mix dialyzer` - No errors
4. `mix format --check-formatted` - Formatted
5. All documentation updated with new API
6. Version bumped in `mix.exs` and `README.md`
7. `CHANGELOG.md` has 2025-12-21 entry
8. Old `Rag.Chunking` module deleted
9. No references to old API remain in codebase

---

## Notes

- TextChunker is published on Hex (current: `~> 0.5.2`)
- The `FormatAware` chunker wraps TextChunker - make it optional (check `Code.ensure_loaded?`)
- Preserve all existing test coverage - the old tests validate correct behavior, port them
- Byte positions are CRITICAL - every chunk must have accurate `start_byte`/`end_byte`
- Use `byte_size/1` for byte calculations, `String.length/1` for character counts
- Match the existing behavior patterns exactly (see `Retriever`, `Reranker` for reference)
