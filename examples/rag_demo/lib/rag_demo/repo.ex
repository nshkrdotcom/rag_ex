defmodule RagDemo.Repo do
  use Ecto.Repo,
    otp_app: :rag_demo,
    adapter: Ecto.Adapters.Postgres
end
