defmodule Rag.Agent.SessionTest do
  use ExUnit.Case, async: true

  alias Rag.Agent.Session

  describe "new/1" do
    test "creates a new session with unique id" do
      session = Session.new()

      assert session.id != nil
      assert is_binary(session.id)
    end

    test "creates a session with custom id" do
      session = Session.new(id: "custom-123")

      assert session.id == "custom-123"
    end

    test "creates a session with metadata" do
      session = Session.new(metadata: %{user: "test_user"})

      assert session.metadata == %{user: "test_user"}
    end

    test "initializes empty message history" do
      session = Session.new()

      assert Session.messages(session) == []
    end

    test "initializes empty context" do
      session = Session.new()

      assert Session.context(session) == %{}
    end
  end

  describe "add_message/3" do
    test "adds user message to history" do
      session =
        Session.new()
        |> Session.add_message(:user, "Hello!")

      messages = Session.messages(session)

      assert length(messages) == 1
      assert hd(messages).role == :user
      assert hd(messages).content == "Hello!"
    end

    test "adds assistant message to history" do
      session =
        Session.new()
        |> Session.add_message(:assistant, "Hi there!")

      messages = Session.messages(session)

      assert length(messages) == 1
      assert hd(messages).role == :assistant
    end

    test "preserves message order" do
      session =
        Session.new()
        |> Session.add_message(:user, "First")
        |> Session.add_message(:assistant, "Second")
        |> Session.add_message(:user, "Third")

      messages = Session.messages(session)

      assert length(messages) == 3
      assert Enum.at(messages, 0).content == "First"
      assert Enum.at(messages, 1).content == "Second"
      assert Enum.at(messages, 2).content == "Third"
    end

    test "adds timestamp to messages" do
      session =
        Session.new()
        |> Session.add_message(:user, "Test")

      [message] = Session.messages(session)

      assert message.timestamp != nil
      assert is_integer(message.timestamp)
    end
  end

  describe "add_tool_result/3" do
    test "adds tool result to history" do
      session =
        Session.new()
        |> Session.add_tool_result("search", {:ok, ["result1", "result2"]})

      messages = Session.messages(session)

      assert length(messages) == 1
      assert hd(messages).role == :tool
      assert hd(messages).tool_name == "search"
    end

    test "stores tool result content" do
      session =
        Session.new()
        |> Session.add_tool_result("read_file", {:ok, "file content"})

      [message] = Session.messages(session)

      assert message.content == "file content"
    end

    test "handles tool errors" do
      session =
        Session.new()
        |> Session.add_tool_result("search", {:error, :not_found})

      [message] = Session.messages(session)

      assert message.role == :tool
      assert message.error == :not_found
    end
  end

  describe "set_context/3" do
    test "sets a context value" do
      session =
        Session.new()
        |> Session.set_context(:repo, "my_app")

      assert Session.get_context(session, :repo) == "my_app"
    end

    test "allows updating context values" do
      session =
        Session.new()
        |> Session.set_context(:key, "value1")
        |> Session.set_context(:key, "value2")

      assert Session.get_context(session, :key) == "value2"
    end
  end

  describe "merge_context/2" do
    test "merges multiple context values" do
      session =
        Session.new()
        |> Session.set_context(:a, 1)
        |> Session.merge_context(%{b: 2, c: 3})

      context = Session.context(session)

      assert context.a == 1
      assert context.b == 2
      assert context.c == 3
    end
  end

  describe "get_context/2" do
    test "returns nil for missing keys" do
      session = Session.new()

      assert Session.get_context(session, :missing) == nil
    end

    test "returns default for missing keys" do
      session = Session.new()

      assert Session.get_context(session, :missing, "default") == "default"
    end
  end

  describe "message_count/1" do
    test "returns number of messages" do
      session =
        Session.new()
        |> Session.add_message(:user, "1")
        |> Session.add_message(:assistant, "2")
        |> Session.add_message(:user, "3")

      assert Session.message_count(session) == 3
    end
  end

  describe "last_messages/2" do
    test "returns last n messages" do
      session =
        Session.new()
        |> Session.add_message(:user, "1")
        |> Session.add_message(:assistant, "2")
        |> Session.add_message(:user, "3")
        |> Session.add_message(:assistant, "4")

      last_two = Session.last_messages(session, 2)

      assert length(last_two) == 2
      assert Enum.at(last_two, 0).content == "3"
      assert Enum.at(last_two, 1).content == "4"
    end

    test "returns all if n > message count" do
      session =
        Session.new()
        |> Session.add_message(:user, "1")

      messages = Session.last_messages(session, 10)

      assert length(messages) == 1
    end
  end

  describe "clear_messages/1" do
    test "removes all messages but keeps context" do
      session =
        Session.new()
        |> Session.add_message(:user, "Hello")
        |> Session.set_context(:key, "value")
        |> Session.clear_messages()

      assert Session.messages(session) == []
      assert Session.get_context(session, :key) == "value"
    end
  end

  describe "to_llm_messages/1" do
    test "formats messages for LLM API" do
      session =
        Session.new()
        |> Session.add_message(:user, "Hello")
        |> Session.add_message(:assistant, "Hi!")

      llm_messages = Session.to_llm_messages(session)

      assert length(llm_messages) == 2
      assert Enum.at(llm_messages, 0) == %{role: :user, content: "Hello"}
      assert Enum.at(llm_messages, 1) == %{role: :assistant, content: "Hi!"}
    end

    test "formats tool results appropriately" do
      session =
        Session.new()
        |> Session.add_tool_result("search", {:ok, "found it"})

      llm_messages = Session.to_llm_messages(session)

      [msg] = llm_messages
      assert msg.role == :tool
      assert msg.content == "found it"
    end
  end

  describe "token_estimate/1" do
    test "estimates token count for messages" do
      session =
        Session.new()
        |> Session.add_message(:user, "Hello world")
        |> Session.add_message(:assistant, "Hi there!")

      estimate = Session.token_estimate(session)

      # Should be a reasonable estimate
      assert estimate > 0
      assert is_integer(estimate)
    end
  end
end
