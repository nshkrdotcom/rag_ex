defmodule Rag.Agent.Tools.SearchReposTest do
  use ExUnit.Case, async: true

  alias Rag.Agent.Tools.SearchRepos

  describe "behaviour implementation" do
    test "name/0 returns correct name" do
      assert SearchRepos.name() == "search_repos"
    end

    test "description/0 returns a description" do
      description = SearchRepos.description()

      assert is_binary(description)
      assert String.length(description) > 0
    end

    test "parameters/0 returns valid JSON schema" do
      params = SearchRepos.parameters()

      assert params.type == "object"
      assert Map.has_key?(params.properties, :query)
      assert "query" in params.required
    end
  end

  describe "execute/2" do
    test "requires query parameter" do
      result = SearchRepos.execute(%{}, %{})

      assert {:error, :missing_query} = result
    end

    test "returns results for valid query" do
      context = %{
        search_fn: fn _query, _opts ->
          {:ok,
           [
             %{content: "def hello", source: "lib/hello.ex", score: 0.9},
             %{content: "def world", source: "lib/world.ex", score: 0.8}
           ]}
        end
      }

      result = SearchRepos.execute(%{"query" => "hello function"}, context)

      assert {:ok, results} = result
      assert is_list(results)
      assert length(results) == 2
    end

    test "respects limit option" do
      context = %{
        search_fn: fn _query, opts ->
          limit = Keyword.get(opts, :limit, 10)

          results =
            Enum.map(1..limit, fn i ->
              %{content: "result #{i}", source: "file#{i}.ex", score: 1.0 / i}
            end)

          {:ok, results}
        end
      }

      result = SearchRepos.execute(%{"query" => "test", "limit" => 5}, context)

      assert {:ok, results} = result
      assert length(results) == 5
    end

    test "handles search errors" do
      context = %{
        search_fn: fn _query, _opts -> {:error, :search_failed} end
      }

      result = SearchRepos.execute(%{"query" => "test"}, context)

      assert {:error, :search_failed} = result
    end

    test "uses default search when no search_fn provided" do
      # Without search_fn, should return empty results
      result = SearchRepos.execute(%{"query" => "test"}, %{})

      assert {:ok, []} = result
    end
  end
end
