defmodule Rag.GraphStore.TripleStore.URITest do
  use ExUnit.Case, async: true

  alias Rag.GraphStore.TripleStore.URI

  describe "generation" do
    test "entity/1 generates entity URI" do
      assert URI.entity(42) == "urn:entity:42"
      assert URI.entity("abc") == "urn:entity:abc"
    end

    test "type/1 generates type URI" do
      assert URI.type(:function) == "urn:type:function"
      assert URI.type("module") == "urn:type:module"
    end

    test "rel/1 generates relationship URI" do
      assert URI.rel(:calls) == "urn:rel:calls"
    end

    test "prop/1 generates property URI" do
      assert URI.prop(:name) == "urn:prop:name"
    end
  end

  describe "parsing" do
    test "parse/1 extracts entity id" do
      assert URI.parse("urn:entity:42") == {:ok, {:entity, 42}}
      assert URI.parse("urn:entity:abc") == {:ok, {:entity, "abc"}}
    end

    test "parse/1 returns error for unknown scheme" do
      assert URI.parse("http://example.com") == {:error, :unknown_uri_scheme}
    end
  end

  describe "predicates" do
    test "entity?/1 identifies entity URIs" do
      assert URI.entity?("urn:entity:1") == true
      assert URI.entity?("urn:type:foo") == false
    end

    test "relationship?/1 identifies relationship URIs" do
      assert URI.relationship?("urn:rel:calls") == true
      assert URI.relationship?("urn:prop:name") == false
    end
  end
end
