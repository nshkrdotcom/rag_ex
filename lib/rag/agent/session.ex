defmodule Rag.Agent.Session do
  @moduledoc """
  Session management for agent conversations.

  A session maintains the conversation history, context, and state
  for an agent interaction. It handles:

  - Message history (user, assistant, tool results)
  - Context storage (persistent data across turns)
  - Token estimation for context window management

  ## Usage

      session = Session.new()
        |> Session.add_message(:user, "Hello!")
        |> Session.add_message(:assistant, "Hi there!")
        |> Session.set_context(:repo, "my_app")

      # Get messages for LLM
      messages = Session.to_llm_messages(session)

  """

  defstruct [:id, :messages, :context, :metadata, :created_at]

  @type role :: :user | :assistant | :system | :tool
  @type message :: %{
          role: role(),
          content: String.t(),
          timestamp: integer(),
          tool_name: String.t() | nil,
          error: term() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          messages: [message()],
          context: map(),
          metadata: map(),
          created_at: integer()
        }

  # Rough estimate: 4 characters per token
  @chars_per_token 4

  @doc """
  Creates a new session.

  ## Options

  - `:id` - Custom session ID (generates UUID if not provided)
  - `:metadata` - Initial metadata map

  ## Examples

      iex> Session.new()
      %Session{id: "...", messages: [], context: %{}}

      iex> Session.new(id: "my-session", metadata: %{user: "alice"})
      %Session{id: "my-session", metadata: %{user: "alice"}}

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    id = Keyword.get(opts, :id) || generate_id()
    metadata = Keyword.get(opts, :metadata, %{})

    %__MODULE__{
      id: id,
      messages: [],
      context: %{},
      metadata: metadata,
      created_at: System.system_time(:millisecond)
    }
  end

  @doc """
  Adds a message to the session history.

  ## Parameters

  - `session` - The session struct
  - `role` - Message role (:user, :assistant, :system)
  - `content` - Message content

  ## Examples

      iex> session |> Session.add_message(:user, "Hello!")
      %Session{messages: [%{role: :user, content: "Hello!", ...}]}

  """
  @spec add_message(t(), role(), String.t()) :: t()
  def add_message(%__MODULE__{} = session, role, content) do
    message = %{
      role: role,
      content: content,
      timestamp: System.system_time(:millisecond),
      tool_name: nil,
      error: nil
    }

    %{session | messages: session.messages ++ [message]}
  end

  @doc """
  Adds a tool result to the session history.

  ## Parameters

  - `session` - The session struct
  - `tool_name` - Name of the tool that was called
  - `result` - Tool result as {:ok, content} or {:error, reason}

  """
  @spec add_tool_result(t(), String.t(), {:ok, term()} | {:error, term()}) :: t()
  def add_tool_result(%__MODULE__{} = session, tool_name, result) do
    {content, error} =
      case result do
        {:ok, value} -> {format_tool_result(value), nil}
        {:error, reason} -> {nil, reason}
      end

    message = %{
      role: :tool,
      content: content,
      timestamp: System.system_time(:millisecond),
      tool_name: tool_name,
      error: error
    }

    %{session | messages: session.messages ++ [message]}
  end

  @doc """
  Returns all messages in the session.
  """
  @spec messages(t()) :: [message()]
  def messages(%__MODULE__{messages: messages}), do: messages

  @doc """
  Returns the session context.
  """
  @spec context(t()) :: map()
  def context(%__MODULE__{context: context}), do: context

  @doc """
  Sets a context value.

  ## Examples

      iex> session |> Session.set_context(:key, "value")
      %Session{context: %{key: "value"}}

  """
  @spec set_context(t(), atom(), term()) :: t()
  def set_context(%__MODULE__{} = session, key, value) do
    %{session | context: Map.put(session.context, key, value)}
  end

  @doc """
  Merges values into the context.

  ## Examples

      iex> session |> Session.merge_context(%{a: 1, b: 2})
      %Session{context: %{a: 1, b: 2}}

  """
  @spec merge_context(t(), map()) :: t()
  def merge_context(%__MODULE__{} = session, new_context) do
    %{session | context: Map.merge(session.context, new_context)}
  end

  @doc """
  Gets a context value.

  ## Examples

      iex> Session.get_context(session, :key)
      "value"

      iex> Session.get_context(session, :missing, "default")
      "default"

  """
  @spec get_context(t(), atom(), term()) :: term()
  def get_context(%__MODULE__{} = session, key, default \\ nil) do
    Map.get(session.context, key, default)
  end

  @doc """
  Returns the number of messages in the session.
  """
  @spec message_count(t()) :: non_neg_integer()
  def message_count(%__MODULE__{messages: messages}), do: length(messages)

  @doc """
  Returns the last n messages.

  ## Examples

      iex> Session.last_messages(session, 5)
      [%{role: :user, ...}, %{role: :assistant, ...}]

  """
  @spec last_messages(t(), non_neg_integer()) :: [message()]
  def last_messages(%__MODULE__{messages: messages}, n) do
    messages
    |> Enum.take(-n)
  end

  @doc """
  Clears all messages but keeps context and metadata.
  """
  @spec clear_messages(t()) :: t()
  def clear_messages(%__MODULE__{} = session) do
    %{session | messages: []}
  end

  @doc """
  Formats messages for LLM API consumption.

  Returns a list of simplified message maps suitable for
  sending to LLM providers.

  ## Examples

      iex> Session.to_llm_messages(session)
      [%{role: :user, content: "Hello"}, %{role: :assistant, content: "Hi!"}]

  """
  @spec to_llm_messages(t()) :: [map()]
  def to_llm_messages(%__MODULE__{messages: messages}) do
    Enum.map(messages, fn msg ->
      base = %{role: msg.role, content: msg.content}

      if msg.tool_name do
        Map.put(base, :tool_name, msg.tool_name)
      else
        base
      end
    end)
  end

  @doc """
  Estimates the token count for the session.

  Uses a rough approximation based on character count.
  """
  @spec token_estimate(t()) :: non_neg_integer()
  def token_estimate(%__MODULE__{messages: messages}) do
    total_chars =
      Enum.reduce(messages, 0, fn msg, acc ->
        content_len = if msg.content, do: String.length(msg.content), else: 0
        acc + content_len
      end)

    div(total_chars, @chars_per_token)
  end

  # Private helpers

  defp generate_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  defp format_tool_result(value) when is_binary(value), do: value
  defp format_tool_result(value) when is_list(value), do: inspect(value)
  defp format_tool_result(value) when is_map(value), do: Jason.encode!(value)
  defp format_tool_result(value), do: inspect(value)
end
