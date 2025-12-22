# Chunker Examples

## Basic Usage

### Simple Text Chunking

```elixir
alias Rag.Chunker
alias Rag.Chunker.{Character, Sentence, Paragraph, Recursive}

text = """
This is the first paragraph with multiple sentences. It contains important information.
The second sentence adds more context.

This is the second paragraph. It discusses a different topic entirely.
More details follow in subsequent sentences.

The third paragraph concludes our document.
"""

# Character-based (fixed size with smart boundaries)
chunker = %Character{max_chars: 200, overlap: 20}
chunks = Chunker.chunk(chunker, text)
IO.puts("Character chunks: #{length(chunks)}")

# Sentence-based
chunker = %Sentence{max_chars: 200, min_chars: 50}
chunks = Chunker.chunk(chunker, text)
IO.puts("Sentence chunks: #{length(chunks)}")

# Paragraph-based
chunker = %Paragraph{max_chars: 500}
chunks = Chunker.chunk(chunker, text)
IO.puts("Paragraph chunks: #{length(chunks)}")

# Recursive (tries paragraph -> sentence -> character)
chunker = %Recursive{max_chars: 150}
chunks = Chunker.chunk(chunker, text)
IO.puts("Recursive chunks: #{length(chunks)}")
```

### Inspecting Chunks

```elixir
chunker = %Recursive{max_chars: 100}
chunks = Chunker.chunk(chunker, text)

Enum.each(chunks, fn chunk ->
  IO.puts("""
  ---
  Index: #{chunk.index}
  Bytes: #{chunk.start_byte}..#{chunk.end_byte}
  Hierarchy: #{chunk.metadata[:hierarchy]}
  Content: #{String.slice(chunk.content, 0, 50)}...
  """)
end)
```

### Verifying Position Accuracy

```elixir
alias Rag.Chunker.Chunk

chunker = %Character{max_chars: 100}
chunks = Chunker.chunk(chunker, text)

# Verify all chunks have accurate positions
all_valid = Enum.all?(chunks, fn chunk ->
  Chunk.valid?(chunk, text)
end)

IO.puts("All positions valid: #{all_valid}")

# Extract content using positions
first = hd(chunks)
extracted = Chunk.extract_from_source(first, text)
IO.puts("Extracted matches content: #{extracted == first.content}")
```

---

## Code Chunking

### Elixir Source Files

```elixir
alias Rag.Chunker
alias Rag.Chunker.FormatAware

elixir_code = """
defmodule MyApp.Users do
  @moduledoc \"\"\"
  User management functions.
  \"\"\"

  alias MyApp.Repo
  alias MyApp.Schemas.User

  @doc \"\"\"
  List all users.
  \"\"\"
  def list_users do
    Repo.all(User)
  end

  @doc \"\"\"
  Get a user by ID.
  \"\"\"
  def get_user(id) do
    Repo.get(User, id)
  end

  @doc \"\"\"
  Create a new user.
  \"\"\"
  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end
end
"""

chunker = %FormatAware{format: :elixir, chunk_size: 300, chunk_overlap: 50}
chunks = Chunker.chunk(chunker, elixir_code)

Enum.each(chunks, fn chunk ->
  IO.puts("--- Chunk #{chunk.index} (#{chunk.start_byte}..#{chunk.end_byte}) ---")
  IO.puts(chunk.content)
end)
```

### Python Source Files

```elixir
python_code = """
class UserService:
    \"\"\"Service for user management.\"\"\"

    def __init__(self, db):
        self.db = db

    def get_user(self, user_id: int) -> User:
        \"\"\"Fetch a user by ID.\"\"\"
        return self.db.query(User).get(user_id)

    def create_user(self, data: dict) -> User:
        \"\"\"Create a new user.\"\"\"
        user = User(**data)
        self.db.add(user)
        self.db.commit()
        return user

def helper_function():
    \"\"\"A standalone helper.\"\"\"
    pass
"""

chunker = %FormatAware{format: :python, chunk_size: 250}
chunks = Chunker.chunk(chunker, python_code)

IO.puts("Python code split into #{length(chunks)} chunks")
```

### Markdown Documentation

```elixir
markdown = """
# User Guide

## Getting Started

Welcome to our application. This guide will help you get up and running.

### Installation

Run the following command:

```bash
mix deps.get
mix ecto.setup
```

### Configuration

Configure your environment variables in `.env`:

```
DATABASE_URL=postgres://localhost/myapp
SECRET_KEY_BASE=...
```

## API Reference

### Authentication

All API requests require authentication via Bearer token.

### Endpoints

#### GET /users

Returns a list of users.

#### POST /users

Creates a new user.
"""

chunker = %FormatAware{format: :markdown, chunk_size: 400}
chunks = Chunker.chunk(chunker, markdown)

Enum.each(chunks, fn chunk ->
  heading = Regex.run(~r/^#+ .+/m, chunk.content)
  IO.puts("Chunk #{chunk.index}: #{heading || "(no heading)"}")
end)
```

---

## Semantic Chunking

### With Embedding Provider

```elixir
alias Rag.Chunker
alias Rag.Chunker.Semantic

# Setup router with embedding provider
{:ok, router} = Rag.Router.new(providers: [:gemini], strategy: :fallback)

# Create embedding function using router
embedding_fn = fn text ->
  {:ok, [embedding], _router} = Rag.Router.execute(router, :embeddings, [text], [])
  embedding
end

chunker = %Semantic{
  embedding_fn: embedding_fn,
  threshold: 0.8,
  max_chars: 500
}

text = """
Machine learning is a subset of artificial intelligence. It focuses on algorithms
that improve through experience. Deep learning is a type of machine learning.

The weather today is sunny and warm. Perfect for outdoor activities.
Tomorrow might bring rain according to forecasts.

Neural networks are inspired by biological neurons. They form the basis of
deep learning systems. Training neural networks requires large datasets.
"""

chunks = Chunker.chunk(chunker, text)

# Semantic chunking should group related sentences together
Enum.each(chunks, fn chunk ->
  IO.puts("--- Semantic Group #{chunk.index} ---")
  IO.puts(chunk.content)
  IO.puts("")
end)
```

### With Local Embeddings (Nx)

```elixir
# Using Bumblebee for local embeddings
{:ok, model} = Bumblebee.load_model({:hf, "sentence-transformers/all-MiniLM-L6-v2"})
{:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "sentence-transformers/all-MiniLM-L6-v2"})
serving = Bumblebee.Text.TextEmbedding.text_embedding(model, tokenizer)

embedding_fn = fn text ->
  %{embedding: embedding} = Nx.Serving.run(serving, text)
  Nx.to_flat_list(embedding)
end

chunker = %Semantic{
  embedding_fn: embedding_fn,
  threshold: 0.85
}

chunks = Chunker.chunk(chunker, document_text)
```

---

## Pipeline Integration

### Ingestion Pipeline

```elixir
alias Rag.{Pipeline, Chunker, Embedding, VectorStore}
alias Rag.Chunker.Recursive

# Define chunker
chunker = %Recursive{max_chars: 500, min_chars: 100}

# Build pipeline
pipeline = %Pipeline{
  name: :document_ingestion,
  steps: [
    %Pipeline.Step{
      name: :load,
      module: Rag.Loading,
      function: :load_file
    },
    %Pipeline.Step{
      name: :chunk,
      module: Rag.Chunker,
      function: :chunk_ingestion,
      args: [chunker: chunker],
      inputs: [:load]
    },
    %Pipeline.Step{
      name: :prepare,
      module: __MODULE__,
      function: :prepare_for_embedding,
      inputs: [:chunk]
    },
    %Pipeline.Step{
      name: :embed,
      module: Rag.Embedding,
      function: :generate_embeddings_batch,
      inputs: [:prepare]
    },
    %Pipeline.Step{
      name: :store,
      module: __MODULE__,
      function: :store_chunks,
      inputs: [:embed]
    }
  ]
}

# Helper functions
def prepare_for_embedding(%{chunks: chunks, source: source}) do
  Enum.map(chunks, fn chunk ->
    %{
      text: chunk.content,
      source: source,
      metadata: Map.merge(chunk.metadata, %{
        start_byte: chunk.start_byte,
        end_byte: chunk.end_byte
      })
    }
  end)
end

def store_chunks(chunks_with_embeddings) do
  chunks_with_embeddings
  |> Enum.map(&VectorStore.prepare_for_insert/1)
  |> then(&Repo.insert_all(VectorStore.Chunk, &1))
end

# Execute
context = %Pipeline.Context{input: %{source: "docs/guide.md"}}
{:ok, result} = Pipeline.Executor.run(pipeline, context)
```

### Batch Processing Multiple Files

```elixir
alias Rag.Chunker
alias Rag.Chunker.FormatAware

files = [
  {"lib/myapp/users.ex", :elixir},
  {"lib/myapp/posts.ex", :elixir},
  {"README.md", :markdown},
  {"docs/api.md", :markdown}
]

all_chunks =
  files
  |> Task.async_stream(fn {path, format} ->
    content = File.read!(path)
    chunker = %FormatAware{format: format, chunk_size: 1000}
    chunks = Chunker.chunk(chunker, content)

    Enum.map(chunks, fn chunk ->
      %{
        content: chunk.content,
        source: path,
        start_byte: chunk.start_byte,
        end_byte: chunk.end_byte,
        metadata: Map.put(chunk.metadata, :format, format)
      }
    end)
  end, max_concurrency: 4)
  |> Enum.flat_map(fn {:ok, chunks} -> chunks end)

IO.puts("Total chunks: #{length(all_chunks)}")
```

---

## Custom Chunker Implementation

### Heading-Based Chunker

```elixir
defmodule MyApp.Chunker.ByHeading do
  @behaviour Rag.Chunker

  alias Rag.Chunker.Chunk

  defstruct levels: [1, 2], include_heading: true

  @impl true
  def default_opts, do: [levels: [1, 2], include_heading: true]

  @impl true
  def chunk(%__MODULE__{} = chunker, text, opts) do
    levels = opts[:levels] || chunker.levels
    include_heading = opts[:include_heading] || chunker.include_heading

    # Build regex for heading levels
    level_pattern = levels |> Enum.map(&Integer.to_string/1) |> Enum.join("")
    regex = Regex.compile!("^(\#{1,#{Enum.max(levels)}})\\s+(.+)$", [:multiline])

    # Find all headings with positions
    matches = Regex.scan(regex, text, return: :index)

    # Split text by headings
    split_at_headings(text, matches, include_heading)
    |> Enum.with_index()
    |> Enum.map(fn {{content, start_byte, end_byte}, index} ->
      Chunk.new(%{
        content: content,
        start_byte: start_byte,
        end_byte: end_byte,
        index: index,
        metadata: %{chunker: :by_heading}
      })
    end)
  end

  defp split_at_headings(text, [], _include) do
    [{text, 0, byte_size(text)}]
  end

  defp split_at_headings(text, matches, include_heading) do
    # Implementation to split text at heading positions
    # ... (tracking byte positions)
  end
end

# Usage
chunker = %MyApp.Chunker.ByHeading{levels: [1, 2, 3]}
chunks = Rag.Chunker.chunk(chunker, markdown_text)
```

### Token-Based Chunker

```elixir
defmodule MyApp.Chunker.ByTokens do
  @behaviour Rag.Chunker

  alias Rag.Chunker.Chunk

  defstruct [:tokenizer, max_tokens: 512, overlap_tokens: 50]

  @impl true
  def default_opts, do: [max_tokens: 512, overlap_tokens: 50]

  @impl true
  def chunk(%__MODULE__{tokenizer: nil}, _text, _opts) do
    raise ArgumentError, "tokenizer is required"
  end

  def chunk(%__MODULE__{} = chunker, text, opts) do
    max_tokens = opts[:max_tokens] || chunker.max_tokens
    overlap = opts[:overlap_tokens] || chunker.overlap_tokens
    tokenizer = chunker.tokenizer

    # Tokenize entire text
    tokens = tokenizer.encode(text)

    # Split into chunks of max_tokens with overlap
    tokens
    |> chunk_tokens(max_tokens, overlap)
    |> Enum.with_index()
    |> Enum.map(fn {token_range, index} ->
      content = tokenizer.decode(token_range)
      # Calculate byte positions from token positions
      {start_byte, end_byte} = calculate_byte_range(text, content, index)

      Chunk.new(%{
        content: content,
        start_byte: start_byte,
        end_byte: end_byte,
        index: index,
        metadata: %{
          chunker: :by_tokens,
          token_count: length(token_range)
        }
      })
    end)
  end

  defp chunk_tokens(tokens, max, overlap) do
    # Sliding window over tokens
    # ...
  end

  defp calculate_byte_range(source, content, chunk_index) do
    # Find content in source, accounting for position
    # ...
  end
end

# Usage with Tiktoken
{:ok, tokenizer} = Tiktoken.encoding_for_model("gpt-4")

chunker = %MyApp.Chunker.ByTokens{
  tokenizer: tokenizer,
  max_tokens: 500,
  overlap_tokens: 50
}

chunks = Rag.Chunker.chunk(chunker, text)
```

---

## Chunk Reconstruction

### Reassembling Original Text

```elixir
alias Rag.Chunker
alias Rag.Chunker.{Paragraph, Chunk}

text = File.read!("document.txt")
chunker = %Paragraph{max_chars: 500}
chunks = Chunker.chunk(chunker, text)

# Sort by position and reconstruct
reconstructed =
  chunks
  |> Enum.sort_by(& &1.start_byte)
  |> Enum.reduce({"", 0}, fn chunk, {acc, last_end} ->
    # Add any gap between chunks
    gap = if chunk.start_byte > last_end do
      binary_part(text, last_end, chunk.start_byte - last_end)
    else
      ""
    end

    {acc <> gap <> chunk.content, chunk.end_byte}
  end)
  |> elem(0)

# Handle trailing content
final_end = List.last(chunks).end_byte
trailing = if final_end < byte_size(text) do
  binary_part(text, final_end, byte_size(text) - final_end)
else
  ""
end

reconstructed = reconstructed <> trailing

IO.puts("Reconstruction matches: #{reconstructed == text}")
```

### Highlighting Source Locations

```elixir
defmodule MyApp.Highlighter do
  @doc """
  Highlight a chunk's location in the source document.
  """
  def highlight_chunk(source, chunk, context_lines \\ 2) do
    # Find line numbers for byte range
    {start_line, start_col} = byte_to_line_col(source, chunk.start_byte)
    {end_line, end_col} = byte_to_line_col(source, chunk.end_byte)

    lines = String.split(source, "\n")

    # Extract context
    first_line = max(0, start_line - context_lines)
    last_line = min(length(lines) - 1, end_line + context_lines)

    lines
    |> Enum.slice(first_line..last_line)
    |> Enum.with_index(first_line)
    |> Enum.map(fn {line, num} ->
      marker = if num >= start_line and num <= end_line, do: ">>", else: "  "
      "#{marker} #{num + 1}: #{line}"
    end)
    |> Enum.join("\n")
  end

  defp byte_to_line_col(text, byte_offset) do
    prefix = binary_part(text, 0, byte_offset)
    lines = String.split(prefix, "\n")
    line = length(lines) - 1
    col = String.length(List.last(lines))
    {line, col}
  end
end

# Usage after retrieval
{:ok, results} = Rag.Retriever.retrieve(retriever, query_embedding, limit: 5)

Enum.each(results, fn result ->
  source = File.read!(result.metadata.source)
  chunk = %Chunk{
    content: result.content,
    start_byte: result.metadata.start_byte,
    end_byte: result.metadata.end_byte,
    index: 0
  }

  IO.puts("\n=== Match in #{result.metadata.source} ===")
  IO.puts(MyApp.Highlighter.highlight_chunk(source, chunk))
end)
```
