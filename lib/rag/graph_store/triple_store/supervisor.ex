defmodule Rag.GraphStore.TripleStore.Supervisor do
  @moduledoc """
  Supervisor for TripleStore-related processes.
  """

  use Supervisor

  @id_table :triplestore_ids

  @doc """
  Start the supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)

    :ok = File.mkdir_p(data_dir)
    ensure_id_table()

    Supervisor.init([], strategy: :one_for_one)
  end

  defp ensure_id_table do
    case :ets.whereis(@id_table) do
      :undefined ->
        try do
          :ets.new(@id_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

        :ok

      _ ->
        :ok
    end
  end
end
