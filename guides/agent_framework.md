# Agent Framework

The Agent Framework enables building tool-using agents with conversation memory and multi-turn interactions.

## Overview

The framework consists of four components:

| Component | Purpose |
|-----------|---------|
| **Agent** | Core orchestrator for LLM + tool execution |
| **Session** | Conversation memory and context |
| **Registry** | Tool registration and dispatch |
| **Tool** | Behaviour for custom tools |

## Creating an Agent

```elixir
alias Rag.Agent.Agent
alias Rag.Agent.Tools.{SearchRepos, ReadFile, AnalyzeCode}

# Simple agent
agent = Agent.new()

# Agent with tools
agent = Agent.new(
  tools: [SearchRepos, ReadFile, AnalyzeCode],
  max_iterations: 10
)

# With existing session
agent = Agent.new(
  tools: [SearchRepos, ReadFile],
  session: existing_session,
  provider: :gemini
)
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `tools` | `[]` | Tool modules to register |
| `session` | new Session | Session for memory |
| `provider` | Gemini | LLM provider |
| `max_iterations` | 10 | Max tool calling rounds |

## Processing Queries

### Simple Processing (No Tools)

```elixir
{:ok, response, agent} = Agent.process(agent, "What is Elixir?")
IO.puts(response)
```

### Processing with Tools

```elixir
{:ok, response, agent} = Agent.process_with_tools(agent,
  "Find all GenServer modules in the codebase"
)
```

The agent will:
1. Send query to LLM with available tools
2. If LLM requests a tool, execute it
3. Send tool result back to LLM
4. Repeat until final answer or max_iterations

## Context Management

```elixir
# Add context for tools
agent = agent
  |> Agent.with_context(:repo, MyApp.Repo)
  |> Agent.with_context(:user_id, 123)
  |> Agent.with_context(:search_fn, &vector_store_search/2)

# Access history
history = Agent.get_history(agent)

# Clear history
agent = Agent.clear_history(agent)
```

## Session

Sessions maintain conversation state:

```elixir
alias Rag.Agent.Session

# Create session
session = Session.new()
session = Session.new(id: "session-123", metadata: %{user: "alice"})

# Add messages
session = session
  |> Session.add_message(:user, "Hello")
  |> Session.add_message(:assistant, "Hi there!")
  |> Session.add_message(:system, "Context info")

# Add tool result
session = Session.add_tool_result(session, "search", {:ok, results})

# Query session
Session.messages(session)        # All messages
Session.last_messages(session, 5) # Last 5
Session.message_count(session)   # Count
Session.token_estimate(session)  # Approximate tokens

# Context management
session = Session.set_context(session, :repo, repo)
session = Session.merge_context(session, %{repo: repo, user_id: 123})
context = Session.context(session)
repo = Session.get_context(session, :repo, nil)

# Format for LLM
llm_messages = Session.to_llm_messages(session)
```

## Registry

Manage tool registration:

```elixir
alias Rag.Agent.Registry

# Create registry
registry = Registry.new()
registry = Registry.new(tools: [SearchRepos, ReadFile])

# Register tools
registry = Registry.register(registry, CustomTool)
registry = Registry.register_all(registry, [Tool1, Tool2])

# Query tools
Registry.get(registry, "search")     # {:ok, module} | {:error, :not_found}
Registry.list(registry)              # [module1, module2, ...]
Registry.names(registry)             # ["search", "read_file", ...]
Registry.count(registry)             # 3
Registry.has_tool?(registry, "search") # true

# Unregister
registry = Registry.unregister(registry, "old_tool")

# Execute tool
{:ok, result} = Registry.execute(registry, "search",
  %{"query" => "authentication"},
  %{repo: repo, user_id: 123}
)

# Format for LLM
tool_definitions = Registry.format_for_llm(registry)
```

## Creating Custom Tools

Implement the `Rag.Agent.Tool` behaviour:

```elixir
defmodule MyApp.Tools.CustomSearch do
  @behaviour Rag.Agent.Tool

  @impl true
  def name, do: "custom_search"

  @impl true
  def description do
    "Search for information in the knowledge base"
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        query: %{
          type: "string",
          description: "The search query"
        },
        limit: %{
          type: "integer",
          description: "Maximum results to return"
        }
      },
      required: ["query"]
    }
  end

  @impl true
  def execute(args, context) do
    query = Map.get(args, "query")
    limit = Map.get(args, "limit", 10)

    # Access context values
    repo = Map.get(context, :repo)
    search_fn = Map.get(context, :search_fn)

    case search_fn.(query, limit: limit) do
      {:ok, results} -> {:ok, results}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### Tool Callbacks

| Callback | Return | Description |
|----------|--------|-------------|
| `name/0` | `String.t()` | Unique tool identifier |
| `description/0` | `String.t()` | Description for LLM |
| `parameters/0` | `map()` | JSON Schema for args |
| `execute/2` | `{:ok, term} \| {:error, term}` | Execute the tool |

### Context Values

The context map passed to `execute/2` contains:
- `:session_id` - Current session ID
- `:user_id` - User identifier (if set)
- `:repo` - Ecto repo (if set)
- `:router` - Router for LLM calls (if set)
- Any custom context from `Rag.Agent.Agent.with_context/3`

## Built-in Tools

### ReadFile

Read file contents with optional line ranges:

```elixir
Registry.execute(registry, "read_file",
  %{"path" => "lib/my_module.ex", "start_line" => 10, "end_line" => 30},
  %{read_fn: &File.read/1}
)
```

**Parameters:**
- `path` (string, required) - File path
- `start_line` (integer, optional) - Start line (1-indexed)
- `end_line` (integer, optional) - End line (inclusive)

### AnalyzeCode

Analyze code structure:

```elixir
Registry.execute(registry, "analyze_code",
  %{"code" => code_string, "language" => "elixir"},
  %{}
)
# Returns: %{modules: [...], functions: [...], module_count: N, function_count: N}
```

**Parameters:**
- `code` (string, required) - Code to analyze
- `language` (string, optional) - Language (default: "elixir")

### SearchRepos

Semantic search over repositories:

```elixir
Registry.execute(registry, "search_repos",
  %{"query" => "authentication", "limit" => 5},
  %{search_fn: &vector_store_search/2}
)
```

**Parameters:**
- `query` (string, required) - Search query
- `limit` (integer, optional) - Max results
- `source_filter` (string, optional) - Filter by source

### GetRepoContext

Get repository metadata:

```elixir
Registry.execute(registry, "get_repo_context",
  %{"repo_name" => "my_project"},
  %{context_fn: &get_repo_info/1}
)
```

**Parameters:**
- `repo_name` (string, required) - Repository name
- `include_files` (boolean, optional) - Include file contents

## Tool Calling Workflow

```
User Query
    |
    v
Build prompt with tools (Registry.format_for_llm)
    |
    v
Send to LLM
    |
    v
Parse response (Agent.parse_tool_call)
    |
    +---> Tool call: {"tool": "name", "args": {...}}
    |         |
    |         v
    |     Execute tool (Registry.execute)
    |         |
    |         v
    |     Record result (Session.add_tool_result)
    |         |
    |         v
    |     Loop back to LLM (until max_iterations)
    |
    +---> Final answer
              |
              v
          Return response
```

## Complete Example

```elixir
alias Rag.Agent.{Agent, Registry}
alias Rag.Agent.Tools.{SearchRepos, ReadFile, AnalyzeCode}

# 1. Create agent with tools
agent = Agent.new(
  tools: [SearchRepos, ReadFile, AnalyzeCode],
  max_iterations: 5
)

# 2. Add context for tools
agent = agent
  |> Agent.with_context(:repo, MyApp.Repo)
  |> Agent.with_context(:search_fn, fn query, opts ->
    # Vector store search implementation
    {:ok, results}
  end)
  |> Agent.with_context(:read_fn, &File.read/1)

# 3. Process query with tools
case Agent.process_with_tools(agent, "Find and explain the authentication module") do
  {:ok, response, updated_agent} ->
    IO.puts("Response: #{response}")

    # Check history
    history = Agent.get_history(updated_agent)
    IO.puts("Messages: #{length(history)}")

  {:error, :max_iterations_exceeded} ->
    IO.puts("Too many tool calls")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end
```

## Direct Tool Execution

Use tools without the full agent loop:

```elixir
alias Rag.Agent.Registry
alias Rag.Agent.Tools.AnalyzeCode

# Create registry
registry = Registry.new(tools: [AnalyzeCode])

# Execute directly
code = """
defmodule Calculator do
  def add(a, b), do: a + b
  defp validate(n), do: n > 0
end
"""

{:ok, result} = Registry.execute(registry, "analyze_code",
  %{"code" => code},
  %{}
)

IO.puts("Modules: #{inspect(result.modules)}")
IO.puts("Functions: #{length(result.functions)}")
```

## Best Practices

1. **Set max_iterations** - Prevent infinite loops
2. **Provide necessary context** - Tools need access to resources
3. **Handle errors** - Tools can fail, handle gracefully
4. **Use descriptive tool names** - LLM selects based on name/description
5. **Clear parameter schemas** - Help LLM provide correct args

## Next Steps

- [Pipeline](pipelines.md) - Integrate agents in pipelines
- [GraphRAG](graph_rag.md) - Use agents with knowledge graphs
