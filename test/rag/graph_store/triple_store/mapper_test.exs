defmodule Rag.GraphStore.TripleStore.MapperTest do
  use ExUnit.Case, async: true

  alias Rag.GraphStore.TripleStore.Mapper
  alias Rag.GraphStore.TripleStore.URI

  describe "node_to_triples/2" do
    test "converts basic node to RDF triples" do
      attrs = %{type: :function, name: "foo"}
      triples = Mapper.node_to_triples(attrs, 1)

      entity = RDF.iri(URI.entity(1))

      assert length(triples) >= 2
      assert {entity, RDF.type(), RDF.iri(URI.type(:function))} in triples
      assert {entity, RDF.iri(URI.prop(:name)), RDF.literal("foo")} in triples
    end

    test "converts properties to triples" do
      attrs = %{
        type: :function,
        name: "foo",
        properties: %{file: "lib/foo.ex", line: 42}
      }

      triples = Mapper.node_to_triples(attrs, 1)
      entity = RDF.iri(URI.entity(1))

      assert {entity, RDF.iri(URI.prop(:file)), RDF.literal("lib/foo.ex")} in triples
      assert {entity, RDF.iri(URI.prop(:line)), RDF.literal(42)} in triples
    end

    test "handles source_chunk_ids" do
      attrs = %{type: :function, name: "foo", source_chunk_ids: [1, 2, 3]}
      triples = Mapper.node_to_triples(attrs, 1)

      entity = RDF.iri(URI.entity(1))
      json = Jason.encode!([1, 2, 3])

      assert {entity, RDF.iri(URI.meta(:source_chunk_ids)), RDF.literal(json)} in triples
    end
  end

  describe "edge_to_triples/2" do
    test "converts simple edge to single triple" do
      attrs = %{from_id: 1, to_id: 2, type: :calls}
      triples = Mapper.edge_to_triples(attrs, 100)

      assert length(triples) == 1
      assert {RDF.iri(URI.entity(1)), RDF.iri(URI.rel(:calls)), RDF.iri(URI.entity(2))} in triples
    end

    test "converts edge with properties to reified triples" do
      attrs = %{
        from_id: 1,
        to_id: 2,
        type: :depends_on,
        weight: 0.8,
        properties: %{optional: true}
      }

      triples = Mapper.edge_to_triples(attrs, 100)
      edge_uri = RDF.iri(URI.edge(100))

      assert length(triples) > 1

      assert {edge_uri, RDF.type(),
              RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#Statement")} in triples
    end
  end

  describe "triples_to_node/2" do
    test "reconstructs node from triples" do
      attrs = %{
        type: :function,
        name: "foo",
        properties: %{file: "lib/foo.ex", line: 42},
        source_chunk_ids: [1, 2]
      }

      triples = Mapper.node_to_triples(attrs, 1)
      node = Mapper.triples_to_node(1, triples)

      assert node.id == 1
      assert node.type == :function
      assert node.name == "foo"
      assert node.properties.file == "lib/foo.ex"
      assert node.properties.line == 42
      assert node.source_chunk_ids == [1, 2]
    end
  end
end
