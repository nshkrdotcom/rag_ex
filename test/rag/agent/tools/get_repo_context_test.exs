defmodule Rag.Agent.Tools.GetRepoContextTest do
  use ExUnit.Case, async: true

  alias Rag.Agent.Tools.GetRepoContext

  describe "behaviour implementation" do
    test "name/0 returns correct name" do
      assert GetRepoContext.name() == "get_repo_context"
    end

    test "description/0 returns a description" do
      description = GetRepoContext.description()

      assert is_binary(description)

      assert String.contains?(description, "context") or
               String.contains?(description, "repository")
    end

    test "parameters/0 returns valid JSON schema" do
      params = GetRepoContext.parameters()

      assert params.type == "object"
      assert Map.has_key?(params.properties, :repo_name)
      assert "repo_name" in params.required
    end
  end

  describe "execute/2" do
    test "requires repo_name parameter" do
      result = GetRepoContext.execute(%{}, %{})

      assert {:error, :missing_repo_name} = result
    end

    test "returns repo context using provided context_fn" do
      context = %{
        context_fn: fn repo_name ->
          if repo_name == "my_app" do
            {:ok,
             %{
               name: "my_app",
               description: "A sample application",
               languages: ["Elixir"],
               files: ["lib/my_app.ex", "mix.exs"],
               readme: "# My App\n\nA sample app."
             }}
          else
            {:error, :not_found}
          end
        end
      }

      result = GetRepoContext.execute(%{"repo_name" => "my_app"}, context)

      assert {:ok, repo_context} = result
      assert repo_context.name == "my_app"
      assert "Elixir" in repo_context.languages
    end

    test "returns error for unknown repository" do
      context = %{
        context_fn: fn _repo -> {:error, :not_found} end
      }

      result = GetRepoContext.execute(%{"repo_name" => "unknown"}, context)

      assert {:error, :not_found} = result
    end

    test "supports include_files option" do
      context = %{
        context_fn: fn _repo_name ->
          {:ok,
           %{
             name: "app",
             files: ["lib/app.ex"]
           }}
        end,
        read_fn: fn _path -> {:ok, "file content"} end
      }

      result =
        GetRepoContext.execute(
          %{"repo_name" => "app", "include_files" => true},
          context
        )

      assert {:ok, repo_context} = result
      assert Map.has_key?(repo_context, :name)
    end

    test "returns empty context when no context_fn provided" do
      result = GetRepoContext.execute(%{"repo_name" => "test"}, %{})

      assert {:ok, %{name: "test"}} = result
    end
  end
end
