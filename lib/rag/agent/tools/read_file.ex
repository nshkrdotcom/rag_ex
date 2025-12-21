defmodule Rag.Agent.Tools.ReadFile do
  @moduledoc """
  Tool for reading file contents.

  Reads the contents of a file, optionally extracting specific line ranges.

  ## Context Requirements

  - `:read_fn` - Optional function to read files: `(path) -> {:ok, content} | {:error, reason}`

  If no `read_fn` is provided, uses `File.read/1`.

  """

  @behaviour Rag.Agent.Tool

  @impl true
  def name, do: "read_file"

  @impl true
  def description do
    "Read the contents of a file. Can optionally extract specific line ranges. " <>
      "Use this to examine code or documentation in detail."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "Path to the file to read"
        },
        start_line: %{
          type: "integer",
          description: "Optional start line (1-indexed)"
        },
        end_line: %{
          type: "integer",
          description: "Optional end line (inclusive)"
        }
      },
      required: ["path"]
    }
  end

  @impl true
  def execute(args, context) do
    with {:ok, path} <- get_path(args),
         {:ok, content} <- read_file(path, context) do
      extract_lines(content, args)
    end
  end

  defp get_path(%{"path" => path}) when is_binary(path) and path != "", do: {:ok, path}
  defp get_path(%{path: path}) when is_binary(path) and path != "", do: {:ok, path}
  defp get_path(_), do: {:error, :missing_path}

  defp read_file(path, context) do
    read_fn = Map.get(context, :read_fn)

    if read_fn do
      read_fn.(path)
    else
      case File.read(path) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp extract_lines(content, args) do
    start_line = Map.get(args, "start_line") || Map.get(args, :start_line)
    end_line = Map.get(args, "end_line") || Map.get(args, :end_line)

    if start_line || end_line do
      lines = String.split(content, "\n")
      start_idx = (start_line || 1) - 1
      end_idx = (end_line || length(lines)) - 1

      extracted =
        lines
        |> Enum.slice(start_idx..end_idx)
        |> Enum.join("\n")

      {:ok, extracted}
    else
      {:ok, content}
    end
  end
end
