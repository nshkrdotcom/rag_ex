defmodule Rag.Agent.Tools.SearchRepos do
  @moduledoc """
  Tool for semantic search across repositories.

  Uses the vector store to find relevant code snippets and documentation
  based on semantic similarity to the query.

  ## Context Requirements

  - `:search_fn` - Function to perform search: `(query, opts) -> {:ok, results} | {:error, reason}`

  If no `search_fn` is provided, returns empty results.

  """

  @behaviour Rag.Agent.Tool

  @impl true
  def name, do: "search_repos"

  @impl true
  def description do
    "Search across repositories for relevant code, documentation, and context. " <>
      "Returns snippets matching the semantic meaning of the query."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        query: %{
          type: "string",
          description: "The search query describing what you're looking for"
        },
        limit: %{
          type: "integer",
          description: "Maximum number of results to return (default: 10)"
        },
        source_filter: %{
          type: "string",
          description: "Optional filter to limit search to specific files or directories"
        }
      },
      required: ["query"]
    }
  end

  @impl true
  def execute(args, context) do
    with {:ok, query} <- get_query(args) do
      opts = build_opts(args)
      do_search(query, opts, context)
    end
  end

  defp get_query(%{"query" => query}) when is_binary(query) and query != "", do: {:ok, query}
  defp get_query(%{query: query}) when is_binary(query) and query != "", do: {:ok, query}
  defp get_query(_), do: {:error, :missing_query}

  defp build_opts(args) do
    opts = []

    opts =
      case Map.get(args, "limit") || Map.get(args, :limit) do
        nil -> opts
        limit -> Keyword.put(opts, :limit, limit)
      end

    opts =
      case Map.get(args, "source_filter") || Map.get(args, :source_filter) do
        nil -> opts
        filter -> Keyword.put(opts, :source_filter, filter)
      end

    opts
  end

  defp do_search(query, opts, context) do
    search_fn = Map.get(context, :search_fn)

    if search_fn do
      search_fn.(query, opts)
    else
      # No search function provided - return empty results
      {:ok, []}
    end
  end
end
