defmodule RagDemoTest do
  use ExUnit.Case
  doctest RagDemo

  test "greets the world" do
    assert RagDemo.hello() == :world
  end
end
