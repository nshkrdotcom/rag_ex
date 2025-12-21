defmodule Rag.Agent.Tools.AnalyzeCode do
  @moduledoc """
  Tool for analyzing code structure.

  Parses code and extracts structural information like modules,
  functions, and their relationships.

  ## Context Requirements

  - `:analyze_fn` - Optional custom analysis function: `(code, opts) -> {:ok, analysis}`

  If no `analyze_fn` is provided, uses built-in Elixir code analysis.

  """

  @behaviour Rag.Agent.Tool

  @impl true
  def name, do: "analyze_code"

  @impl true
  def description do
    "Analyze code structure to extract modules, functions, and their signatures. " <>
      "Useful for understanding code organization and dependencies."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        code: %{
          type: "string",
          description: "The code to analyze"
        },
        language: %{
          type: "string",
          description: "Programming language (default: elixir)"
        }
      },
      required: ["code"]
    }
  end

  @impl true
  def execute(args, context) do
    with {:ok, code} <- get_code(args) do
      language = Map.get(args, "language") || Map.get(args, :language, "elixir")
      opts = [language: language]
      analyze(code, opts, context)
    end
  end

  defp get_code(%{"code" => code}) when is_binary(code), do: {:ok, code}
  defp get_code(%{code: code}) when is_binary(code), do: {:ok, code}
  defp get_code(_), do: {:error, :missing_code}

  defp analyze(code, opts, context) do
    analyze_fn = Map.get(context, :analyze_fn)

    cond do
      analyze_fn ->
        analyze_fn.(code, opts)

      opts[:language] in ["elixir", nil] ->
        analyze_elixir(code)

      true ->
        # For non-Elixir languages without a custom analyzer, return basic info
        {:ok,
         %{
           modules: [],
           functions: [],
           language: opts[:language],
           raw_length: String.length(code)
         }}
    end
  end

  defp analyze_elixir(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} ->
        analysis = extract_info(ast)
        {:ok, analysis}

      {:error, _} ->
        # Return partial analysis on parse error
        {:ok,
         %{
           modules: [],
           functions: [],
           parse_error: true,
           raw_length: String.length(code)
         }}
    end
  end

  defp extract_info(ast) do
    modules = extract_modules(ast)
    functions = extract_functions(ast)

    %{
      modules: modules,
      functions: functions,
      module_count: length(modules),
      function_count: length(functions)
    }
  end

  defp extract_modules(ast) do
    ast
    |> find_all(:defmodule)
    |> Enum.map(&extract_module_name/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_module_name({:defmodule, _, [{:__aliases__, _, parts} | _]}) do
    parts
    |> Enum.map(&to_string/1)
    |> Enum.join(".")
  end

  defp extract_module_name({:defmodule, _, [name | _]}) when is_atom(name) do
    name |> to_string() |> String.replace_prefix("Elixir.", "")
  end

  defp extract_module_name(_), do: nil

  defp extract_functions(ast) do
    defs = find_all(ast, :def) ++ find_all(ast, :defp)

    Enum.map(defs, fn
      {type, _, [{name, _, args} | _]} when is_atom(name) ->
        arity = if is_list(args), do: length(args), else: 0

        %{
          name: to_string(name),
          arity: arity,
          type: type
        }

      {type, _, [{:when, _, [{name, _, args} | _]} | _]} when is_atom(name) ->
        arity = if is_list(args), do: length(args), else: 0

        %{
          name: to_string(name),
          arity: arity,
          type: type
        }

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp find_all(ast, target) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {^target, _, _} = node, acc -> {node, [node | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(acc)
  end
end
