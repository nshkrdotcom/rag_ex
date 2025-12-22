import Config

config :rag_demo,
  ecto_repos: [RagDemo.Repo]

config :rag_demo, RagDemo.Repo,
  database: "rag_demo_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5432,
  types: RagDemo.PostgrexTypes

# RAG provider configuration
config :rag, :providers, %{
  gemini: %{
    module: Rag.Ai.Gemini,
    api_key: System.get_env("GEMINI_API_KEY"),
    model: :flash_lite_latest
  }
}

# Optional: Add more providers if you have API keys
# config :rag, :providers, %{
#   gemini: %{...},
#   claude: %{
#     module: Rag.Ai.Claude,
#     api_key: System.get_env("ANTHROPIC_API_KEY"),
#     model: "claude-sonnet-4-20250514"
#   },
#   codex: %{
#     module: Rag.Ai.Codex,
#     api_key: System.get_env("OPENAI_API_KEY"),
#     model: "gpt-4o"
#   }
# }

config :logger, level: :info
