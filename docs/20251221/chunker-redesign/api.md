# Chunker API Reference

## Rag.Chunker

The main behavior module for text chunking.

### Types

```elixir
@type t :: struct()
```

Any struct implementing the `Rag.Chunker` behavior.

### Callbacks

#### chunk/3

```elixir
@callback chunk(chunker :: t(), text :: String.t(), opts :: keyword()) :: [Chunk.t()]
```

Split text into chunks. Returns a list of `Rag.Chunker.Chunk` structs.

#### default_opts/0 (optional)

```elixir
@callback default_opts() :: keyword()
```

Returns default options for this chunker. Merged with runtime opts.

### Functions

#### chunk/3

```elixir
@spec chunk(chunker :: t(), text :: String.t(), opts :: keyword()) :: [Chunk.t()]
```

Dispatch to the chunker implementation.

```elixir
chunker = %Rag.Chunker.Character{max_chars: 500}
chunks = Rag.Chunker.chunk(chunker, "Long text here...", overlap: 100)
```

#### chunk_ingestion/3

```elixir
@spec chunk_ingestion(chunker :: t(), ingestion :: map(), opts :: keyword()) :: map()
```

Chunk an ingestion map. Expects `:document` key, adds `:chunks` key.

```elixir
ingestion = %{source: "file.md", document: "# Hello\n\nWorld"}
chunker = %Rag.Chunker.Paragraph{}
result = Rag.Chunker.chunk_ingestion(chunker, ingestion)
# => %{source: "file.md", document: "...", chunks: [...]}
```

---

## Rag.Chunker.Chunk

Struct representing a single chunk with position information.

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `content` | `String.t()` | The text content |
| `start_byte` | `non_neg_integer()` | Byte offset of start in source |
| `end_byte` | `non_neg_integer()` | Byte offset of end in source |
| `index` | `non_neg_integer()` | Sequential index (0-based) |
| `metadata` | `map()` | Additional information |

### Functions

#### new/1

```elixir
@spec new(map()) :: t()
```

Create a new Chunk struct.

```elixir
chunk = Chunk.new(%{
  content: "Hello world",
  start_byte: 0,
  end_byte: 11,
  index: 0,
  metadata: %{chunker: :character}
})
```

#### extract_from_source/2

```elixir
@spec extract_from_source(t(), String.t()) :: binary()
```

Extract chunk content from source text using byte positions.

```elixir
source = "Hello world, this is a test."
chunk = %Chunk{start_byte: 0, end_byte: 11, ...}
Chunk.extract_from_source(chunk, source)
# => "Hello world"
```

#### valid?/2

```elixir
@spec valid?(t(), String.t()) :: boolean()
```

Verify chunk positions match content.

```elixir
Chunk.valid?(chunk, source_text)
# => true
```

---

## Built-in Chunkers

### Rag.Chunker.Character

Fixed-size chunking with smart boundary detection.

#### Struct Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_chars` | `pos_integer()` | `500` | Maximum characters per chunk |
| `overlap` | `non_neg_integer()` | `50` | Overlap between chunks |

#### Example

```elixir
chunker = %Rag.Chunker.Character{max_chars: 300, overlap: 30}
chunks = Rag.Chunker.chunk(chunker, text)
```

---

### Rag.Chunker.Sentence

Sentence-boundary chunking.

#### Struct Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_chars` | `pos_integer()` | `500` | Maximum characters per chunk |
| `min_chars` | `pos_integer() \| nil` | `nil` | Minimum chars (combines small sentences) |

#### Example

```elixir
chunker = %Rag.Chunker.Sentence{max_chars: 400, min_chars: 100}
chunks = Rag.Chunker.chunk(chunker, text)
```

---

### Rag.Chunker.Paragraph

Paragraph-boundary chunking (splits on `\n\n`).

#### Struct Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_chars` | `pos_integer()` | `500` | Maximum characters per chunk |
| `min_chars` | `pos_integer() \| nil` | `nil` | Minimum chars (combines short paragraphs) |

#### Example

```elixir
chunker = %Rag.Chunker.Paragraph{max_chars: 800}
chunks = Rag.Chunker.chunk(chunker, markdown_text)
```

---

### Rag.Chunker.Recursive

Hierarchical chunking: paragraph -> sentence -> character.

#### Struct Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_chars` | `pos_integer()` | `500` | Maximum characters per chunk |
| `min_chars` | `pos_integer() \| nil` | `nil` | Minimum characters per chunk |

#### Metadata

Each chunk includes `:hierarchy` in metadata:
- `:paragraph` - Split at paragraph boundary
- `:sentence` - Split at sentence boundary
- `:character` - Split at character level

#### Example

```elixir
chunker = %Rag.Chunker.Recursive{max_chars: 500}
chunks = Rag.Chunker.chunk(chunker, text)

Enum.each(chunks, fn chunk ->
  IO.puts("#{chunk.metadata.hierarchy}: #{String.slice(chunk.content, 0, 50)}...")
end)
```

---

### Rag.Chunker.Semantic

Embedding-based similarity grouping.

#### Struct Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `embedding_fn` | `(String.t() -> [float()])` | required | Function to generate embeddings |
| `threshold` | `float()` | `0.8` | Similarity threshold (0.0-1.0) |
| `max_chars` | `pos_integer()` | `500` | Maximum characters per chunk |

#### Example

```elixir
chunker = %Rag.Chunker.Semantic{
  embedding_fn: fn text ->
    {:ok, [embedding], _} = Rag.Router.execute(router, :embeddings, [text], [])
    embedding
  end,
  threshold: 0.85,
  max_chars: 600
}

chunks = Rag.Chunker.chunk(chunker, document_text)
```

---

### Rag.Chunker.FormatAware

Format-aware chunking via TextChunker.

#### Struct Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `format` | `atom()` | `:plaintext` | Document format (see below) |
| `chunk_size` | `pos_integer()` | `2000` | Maximum size in code points |
| `chunk_overlap` | `non_neg_integer()` | `200` | Overlap between chunks |
| `size_fn` | `(String.t() -> integer()) \| nil` | `nil` | Custom size calculation |

#### Supported Formats

**Code:**
- `:elixir` - Module/function definitions, @doc, control structures
- `:python` - Class/function definitions
- `:javascript`, `:typescript` - Classes, functions, exports
- `:ruby` - Classes, methods, blocks
- `:php` - Classes, functions (public/protected/private)
- `:vue` - Vue template tags + JavaScript

**Markup:**
- `:markdown` - Headings, code blocks, dividers
- `:html` - HTML tags (h1-h6, p, ul, article, section, etc.)
- `:latex` - LaTeX sections and environments

**Documents:**
- `:plaintext` - Basic separators (paragraphs, lines, spaces)
- `:doc`, `:docx`, `:pdf`, `:rtf`, `:epub`, `:odt` - Treated as plaintext

#### Example

```elixir
# Chunk Elixir source code
chunker = %Rag.Chunker.FormatAware{
  format: :elixir,
  chunk_size: 1500,
  chunk_overlap: 150
}
chunks = Rag.Chunker.chunk(chunker, elixir_source)

# Chunk with token counting
chunker = %Rag.Chunker.FormatAware{
  format: :markdown,
  chunk_size: 500,
  size_fn: &Tokenizer.count/1
}
chunks = Rag.Chunker.chunk(chunker, markdown_doc)
```

---

## Options Reference

Options can be passed either as struct fields or as the third argument to `chunk/3`. Runtime options override struct fields.

```elixir
# Via struct
chunker = %Rag.Chunker.Character{max_chars: 500, overlap: 50}
Rag.Chunker.chunk(chunker, text)

# Via options (overrides struct)
Rag.Chunker.chunk(chunker, text, max_chars: 300)

# Mixed
chunker = %Rag.Chunker.Character{max_chars: 500}
Rag.Chunker.chunk(chunker, text, overlap: 100)  # Uses 500 max_chars, 100 overlap
```

### Common Options

| Option | Type | Chunkers | Description |
|--------|------|----------|-------------|
| `max_chars` | `pos_integer()` | All except FormatAware | Maximum characters per chunk |
| `min_chars` | `pos_integer()` | Sentence, Paragraph, Recursive | Minimum chars (combine small chunks) |
| `overlap` | `non_neg_integer()` | Character | Overlap between chunks |

### FormatAware Options

| Option | Type | Description |
|--------|------|-------------|
| `format` | `atom()` | Document format |
| `chunk_size` | `pos_integer()` | Maximum size in code points |
| `chunk_overlap` | `non_neg_integer()` | Overlap in code points |
| `size_fn` | `function()` | Custom size calculator |

### Semantic Options

| Option | Type | Description |
|--------|------|-------------|
| `embedding_fn` | `function()` | Embedding generator (required) |
| `threshold` | `float()` | Similarity threshold (0.0-1.0) |
| `max_chars` | `pos_integer()` | Maximum chunk size |
