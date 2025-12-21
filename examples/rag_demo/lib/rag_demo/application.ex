defmodule RagDemo.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RagDemo.Repo
    ]

    opts = [strategy: :one_for_one, name: RagDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
