defmodule Rag.Agent.Tools.AnalyzeCodeTest do
  use ExUnit.Case, async: true

  alias Rag.Agent.Tools.AnalyzeCode

  describe "behaviour implementation" do
    test "name/0 returns correct name" do
      assert AnalyzeCode.name() == "analyze_code"
    end

    test "description/0 returns a description" do
      description = AnalyzeCode.description()

      assert is_binary(description)
      assert String.contains?(description, "analyz") or String.contains?(description, "code")
    end

    test "parameters/0 returns valid JSON schema" do
      params = AnalyzeCode.parameters()

      assert params.type == "object"
      assert Map.has_key?(params.properties, :code)
      assert "code" in params.required
    end
  end

  describe "execute/2" do
    test "requires code parameter" do
      result = AnalyzeCode.execute(%{}, %{})

      assert {:error, :missing_code} = result
    end

    test "analyzes Elixir code structure" do
      code = """
      defmodule Hello do
        @moduledoc "Says hello"

        def hello(name) do
          "Hello, \#{name}!"
        end

        defp private_fn do
          :ok
        end
      end
      """

      result = AnalyzeCode.execute(%{"code" => code}, %{})

      assert {:ok, analysis} = result
      assert is_map(analysis)
      assert Map.has_key?(analysis, :modules)
      assert Map.has_key?(analysis, :functions)
    end

    test "extracts module names" do
      code = """
      defmodule Foo.Bar do
      end

      defmodule Baz do
      end
      """

      result = AnalyzeCode.execute(%{"code" => code}, %{})

      assert {:ok, analysis} = result
      assert "Foo.Bar" in analysis.modules or "Elixir.Foo.Bar" in analysis.modules
    end

    test "extracts function definitions" do
      code = """
      defmodule Test do
        def public_fn(a, b), do: a + b
        defp private_fn, do: :ok
      end
      """

      result = AnalyzeCode.execute(%{"code" => code}, %{})

      assert {:ok, analysis} = result
      assert length(analysis.functions) >= 1
    end

    test "supports language option" do
      code = "function hello() { return 'world'; }"

      result =
        AnalyzeCode.execute(
          %{"code" => code, "language" => "javascript"},
          %{}
        )

      # Should still return an analysis, even if basic
      assert {:ok, analysis} = result
      assert is_map(analysis)
    end

    test "returns basic info for non-Elixir languages without parsing" do
      # JavaScript code with single quotes - should NOT trigger charlist warning
      code = "const x = 'hello';"

      result =
        AnalyzeCode.execute(
          %{"code" => code, "language" => "javascript"},
          %{}
        )

      assert {:ok, analysis} = result
      # Non-Elixir languages return basic info without AST parsing
      assert analysis.language == "javascript"
      assert analysis.raw_length == String.length(code)
      assert analysis.modules == []
      assert analysis.functions == []
    end

    test "handles syntax errors gracefully" do
      code = "defmodule Invalid do def broken("

      result = AnalyzeCode.execute(%{"code" => code}, %{})

      # Should not crash, but might return error or partial analysis
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "uses provided analyze_fn when available" do
      context = %{
        analyze_fn: fn code, _opts ->
          {:ok,
           %{
             custom: true,
             length: String.length(code)
           }}
        end
      }

      result = AnalyzeCode.execute(%{"code" => "test"}, context)

      assert {:ok, %{custom: true, length: 4}} = result
    end
  end
end
