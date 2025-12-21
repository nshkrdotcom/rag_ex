defmodule Rag.Agent.Tools.GetRepoContext do
  @moduledoc """
  Tool for retrieving repository context.

  Returns comprehensive information about a repository including
  its description, languages, structure, and README.

  ## Context Requirements

  - `:context_fn` - Function to get repo context: `(repo_name) -> {:ok, context} | {:error, reason}`
  - `:read_fn` - Optional function for reading files when `include_files` is true

  If no `context_fn` is provided, returns a minimal context with just the name.

  """

  @behaviour Rag.Agent.Tool

  @impl true
  def name, do: "get_repo_context"

  @impl true
  def description do
    "Get comprehensive context about a repository including its description, " <>
      "languages, file structure, and README content."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        repo_name: %{
          type: "string",
          description: "Name of the repository to get context for"
        },
        include_files: %{
          type: "boolean",
          description: "Whether to include file contents (default: false)"
        }
      },
      required: ["repo_name"]
    }
  end

  @impl true
  def execute(args, context) do
    with {:ok, repo_name} <- get_repo_name(args) do
      get_context(repo_name, args, context)
    end
  end

  defp get_repo_name(%{"repo_name" => name}) when is_binary(name) and name != "", do: {:ok, name}
  defp get_repo_name(%{repo_name: name}) when is_binary(name) and name != "", do: {:ok, name}
  defp get_repo_name(_), do: {:error, :missing_repo_name}

  defp get_context(repo_name, args, context) do
    context_fn = Map.get(context, :context_fn)

    if context_fn do
      case context_fn.(repo_name) do
        {:ok, repo_context} ->
          maybe_include_files(repo_context, args, context)

        {:error, _} = error ->
          error
      end
    else
      # No context function - return minimal context
      {:ok, %{name: repo_name}}
    end
  end

  defp maybe_include_files(repo_context, args, _context) do
    include_files = Map.get(args, "include_files") || Map.get(args, :include_files)

    if include_files do
      # If include_files is requested and we have a read_fn, we could
      # expand the context with file contents. For now, just return as-is.
      {:ok, repo_context}
    else
      {:ok, repo_context}
    end
  end
end
