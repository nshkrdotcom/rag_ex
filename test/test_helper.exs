Application.ensure_all_started(:mimic)
Mimic.copy(Nx.Serving)
Mimic.copy(Req)
Mimic.copy(Rag.Ai.Gemini)

# Build exclusion list based on available credentials
exclusions = [:integration_test, :integration]

exclusions =
  if System.get_env("CODEX_API_KEY") || System.get_env("OPENAI_API_KEY") do
    exclusions
  else
    [:skip_without_codex_api_key | exclusions]
  end

exclusions =
  if System.get_env("GEMINI_API_KEY") do
    exclusions
  else
    [:skip_without_gemini_api_key | exclusions]
  end

exclusions =
  if System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_AGENT_OAUTH_TOKEN") do
    exclusions
  else
    [:skip_without_anthropic_api_key | exclusions]
  end

ExUnit.start(exclude: exclusions)
