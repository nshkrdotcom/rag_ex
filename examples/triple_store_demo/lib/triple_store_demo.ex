defmodule TripleStoreDemo do
  @moduledoc """
  Demonstrates Rag.GraphStore.TripleStore usage.
  """

  alias Rag.GraphStore.TripleStore

  def run do
    IO.puts("=== TripleStore Demo ===\n")

    data_dir = "priv/demo_graph"
    File.mkdir_p!(data_dir)

    IO.puts("Opening TripleStore at #{data_dir}...")
    {:ok, store} = TripleStore.open(data_dir: data_dir)

    IO.puts("\nCreating nodes...")

    {:ok, mod} =
      Rag.GraphStore.create_node(store, %{
        type: :module,
        name: "Orders",
        properties: %{file: "lib/orders.ex"}
      })

    IO.puts("  Created module: #{mod.name} (id: #{mod.id})")

    {:ok, fn1} =
      Rag.GraphStore.create_node(store, %{
        type: :function,
        name: "calculate_total",
        properties: %{arity: 1, visibility: :public}
      })

    IO.puts("  Created function: #{fn1.name} (id: #{fn1.id})")

    {:ok, fn2} =
      Rag.GraphStore.create_node(store, %{
        type: :function,
        name: "apply_discount",
        properties: %{arity: 2, visibility: :private}
      })

    IO.puts("  Created function: #{fn2.name} (id: #{fn2.id})")

    IO.puts("\nCreating edges...")

    {:ok, _} =
      Rag.GraphStore.create_edge(store, %{
        from_id: mod.id,
        to_id: fn1.id,
        type: :defines
      })

    IO.puts("  #{mod.name} -defines-> #{fn1.name}")

    {:ok, _} =
      Rag.GraphStore.create_edge(store, %{
        from_id: mod.id,
        to_id: fn2.id,
        type: :defines
      })

    IO.puts("  #{mod.name} -defines-> #{fn2.name}")

    {:ok, _} =
      Rag.GraphStore.create_edge(store, %{
        from_id: fn1.id,
        to_id: fn2.id,
        type: :calls
      })

    IO.puts("  #{fn1.name} -calls-> #{fn2.name}")

    IO.puts("\nQuerying neighbors of #{mod.name}...")
    {:ok, neighbors} = Rag.GraphStore.find_neighbors(store, mod.id, direction: :out)

    Enum.each(neighbors, fn n ->
      IO.puts("  -> #{n.name} (#{n.type})")
    end)

    IO.puts("\nTraversing from #{mod.name} (depth: 2)...")
    {:ok, nodes} = Rag.GraphStore.traverse(store, mod.id, max_depth: 2)

    Enum.each(nodes, fn n ->
      IO.puts("  [depth #{n.depth}] #{n.name} (#{n.type})")
    end)

    IO.puts("\nCreating community...")

    {:ok, community} =
      Rag.GraphStore.create_community(store, %{
        entity_ids: [mod.id, fn1.id, fn2.id],
        level: 0,
        summary: "Order processing module and functions"
      })

    IO.puts("  Community #{community.id}: #{community.summary}")

    IO.puts("\nClosing store...")
    TripleStore.close(store)

    IO.puts("\n=== Demo Complete ===")
  end
end
