defmodule Rag.Agent.Tools.ReadFileTest do
  use ExUnit.Case, async: true

  alias Rag.Agent.Tools.ReadFile

  describe "behaviour implementation" do
    test "name/0 returns correct name" do
      assert ReadFile.name() == "read_file"
    end

    test "description/0 returns a description" do
      description = ReadFile.description()

      assert is_binary(description)
      assert String.contains?(description, "file")
    end

    test "parameters/0 returns valid JSON schema" do
      params = ReadFile.parameters()

      assert params.type == "object"
      assert Map.has_key?(params.properties, :path)
      assert "path" in params.required
    end
  end

  describe "execute/2" do
    test "requires path parameter" do
      result = ReadFile.execute(%{}, %{})

      assert {:error, :missing_path} = result
    end

    test "reads file content using provided read_fn" do
      context = %{
        read_fn: fn path ->
          if path == "lib/hello.ex" do
            {:ok, "defmodule Hello do\n  def hello, do: :world\nend"}
          else
            {:error, :not_found}
          end
        end
      }

      result = ReadFile.execute(%{"path" => "lib/hello.ex"}, context)

      assert {:ok, content} = result
      assert String.contains?(content, "defmodule Hello")
    end

    test "returns error for non-existent file" do
      context = %{
        read_fn: fn _path -> {:error, :not_found} end
      }

      result = ReadFile.execute(%{"path" => "missing.ex"}, context)

      assert {:error, :not_found} = result
    end

    test "supports line range extraction" do
      full_content = """
      defmodule Hello do
        def hello do
          :world
        end

        def goodbye do
          :farewell
        end
      end
      """

      context = %{
        read_fn: fn _path -> {:ok, full_content} end
      }

      result =
        ReadFile.execute(
          %{"path" => "hello.ex", "start_line" => 2, "end_line" => 4},
          context
        )

      assert {:ok, content} = result
      assert String.contains?(content, "def hello")
      refute String.contains?(content, "defmodule")
    end

    test "uses File.read when no read_fn provided" do
      # Create a temp file for testing
      path = Path.join(System.tmp_dir!(), "rag_test_#{:rand.uniform(10000)}.ex")
      File.write!(path, "test content")

      try do
        result = ReadFile.execute(%{"path" => path}, %{})
        assert {:ok, "test content"} = result
      after
        File.rm(path)
      end
    end

    test "returns error for missing file without read_fn" do
      result = ReadFile.execute(%{"path" => "/nonexistent/path.ex"}, %{})

      assert {:error, _} = result
    end
  end
end
