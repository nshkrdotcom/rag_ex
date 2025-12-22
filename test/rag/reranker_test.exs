defmodule Rag.RerankerTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Rag.Reranker
  alias Rag.Reranker.LLM
  alias Rag.Reranker.Passthrough

  setup :set_mimic_global
  setup :verify_on_exit!

  @sample_documents [
    %{id: 1, content: "Elixir is a functional programming language.", score: 0.8, metadata: %{}},
    %{id: 2, content: "Phoenix is a web framework for Elixir.", score: 0.75, metadata: %{}},
    %{id: 3, content: "Python is an interpreted programming language.", score: 0.7, metadata: %{}}
  ]

  describe "Reranker behaviour" do
    test "defines the rerank callback" do
      assert Reranker.behaviour_info(:callbacks) ==
               [rerank: 4]
    end
  end

  describe "Reranker.rerank/4 convenience function" do
    test "calls the rerank callback on the reranker struct" do
      reranker = %Passthrough{}
      query = "What is Elixir?"

      {:ok, results} = Reranker.rerank(reranker, query, @sample_documents, [])

      # Passthrough should return documents unchanged
      assert results == @sample_documents
    end
  end

  describe "Passthrough reranker" do
    test "returns documents unchanged" do
      reranker = %Passthrough{}
      query = "What is Elixir?"

      {:ok, results} = Passthrough.rerank(reranker, query, @sample_documents, [])

      assert results == @sample_documents
      assert length(results) == 3
    end

    test "returns empty list when given empty documents" do
      reranker = %Passthrough{}
      query = "What is Elixir?"

      {:ok, results} = Passthrough.rerank(reranker, query, [], [])

      assert results == []
    end

    test "preserves document order" do
      reranker = %Passthrough{}
      query = "test query"

      docs = [
        %{id: 3, content: "third", score: 0.5, metadata: %{}},
        %{id: 1, content: "first", score: 0.9, metadata: %{}},
        %{id: 2, content: "second", score: 0.7, metadata: %{}}
      ]

      {:ok, results} = Passthrough.rerank(reranker, query, docs, [])

      assert Enum.map(results, & &1.id) == [3, 1, 2]
    end
  end

  describe "LLM reranker" do
    @tag :requires_llm_provider
    test "creates reranker with default options" do
      reranker = LLM.new()

      assert %LLM{} = reranker
      assert reranker.router != nil
      assert is_binary(reranker.prompt_template)
    end

    test "creates reranker with custom router" do
      {:ok, router} = Rag.Router.new(providers: [:gemini])
      reranker = LLM.new(router: router)

      assert reranker.router == router
    end

    @tag :requires_llm_provider
    test "creates reranker with custom prompt template" do
      custom_template = "Custom template: {query} {documents}"
      reranker = LLM.new(prompt_template: custom_template)

      assert reranker.prompt_template == custom_template
    end

    @tag :requires_llm_provider
    test "reranks documents using LLM scores" do
      reranker = LLM.new()
      query = "What is Elixir?"

      # Mock the router to return scoring response
      llm_response = """
      [
        {"doc_index": 0, "score": 9},
        {"doc_index": 1, "score": 7},
        {"doc_index": 2, "score": 3}
      ]
      """

      expect(Rag.Router, :execute, fn _router, :text, prompt, _opts ->
        assert String.contains?(prompt, query)
        assert String.contains?(prompt, "Elixir is a functional programming language")
        {:ok, llm_response, reranker.router}
      end)

      {:ok, results} = LLM.rerank(reranker, query, @sample_documents, [])

      # Should be sorted by LLM scores (descending)
      assert length(results) == 3
      assert Enum.at(results, 0).id == 1
      assert Enum.at(results, 0).score == 9.0
      assert Enum.at(results, 1).id == 2
      assert Enum.at(results, 1).score == 7.0
      assert Enum.at(results, 2).id == 3
      assert Enum.at(results, 2).score == 3.0
    end

    @tag :requires_llm_provider
    test "handles LLM errors gracefully" do
      reranker = LLM.new()
      query = "What is Elixir?"

      expect(Rag.Router, :execute, fn _router, :text, _prompt, _opts ->
        {:error, :timeout}
      end)

      {:error, :timeout} = LLM.rerank(reranker, query, @sample_documents, [])
    end

    @tag :requires_llm_provider
    test "handles invalid JSON response" do
      reranker = LLM.new()
      query = "What is Elixir?"

      expect(Rag.Router, :execute, fn _router, :text, _prompt, _opts ->
        {:ok, "invalid json", reranker.router}
      end)

      {:error, %Jason.DecodeError{}} = LLM.rerank(reranker, query, @sample_documents, [])
    end

    @tag :requires_llm_provider
    test "handles empty document list" do
      reranker = LLM.new()
      query = "What is Elixir?"

      {:ok, results} = LLM.rerank(reranker, query, [], [])

      assert results == []
    end

    @tag :requires_llm_provider
    test "passes top_k option to limit results" do
      reranker = LLM.new()
      query = "What is Elixir?"

      llm_response = """
      [
        {"doc_index": 0, "score": 9},
        {"doc_index": 1, "score": 7},
        {"doc_index": 2, "score": 3}
      ]
      """

      expect(Rag.Router, :execute, fn _router, :text, _prompt, _opts ->
        {:ok, llm_response, reranker.router}
      end)

      {:ok, results} = LLM.rerank(reranker, query, @sample_documents, top_k: 2)

      # Should only return top 2 documents
      assert length(results) == 2
      assert Enum.at(results, 0).id == 1
      assert Enum.at(results, 1).id == 2
    end

    @tag :requires_llm_provider
    test "preserves document metadata" do
      reranker = LLM.new()
      query = "test"

      docs = [
        %{id: 1, content: "doc1", score: 0.5, metadata: %{source: "file1.txt"}},
        %{id: 2, content: "doc2", score: 0.6, metadata: %{source: "file2.txt"}}
      ]

      llm_response = """
      [
        {"doc_index": 0, "score": 8},
        {"doc_index": 1, "score": 9}
      ]
      """

      expect(Rag.Router, :execute, fn _router, :text, _prompt, _opts ->
        {:ok, llm_response, reranker.router}
      end)

      {:ok, results} = LLM.rerank(reranker, query, docs, [])

      assert Enum.at(results, 0).metadata == %{source: "file2.txt"}
      assert Enum.at(results, 1).metadata == %{source: "file1.txt"}
    end

    @tag :requires_llm_provider
    test "handles partial scoring (missing some doc indices)" do
      reranker = LLM.new()
      query = "test"

      # LLM only scores first 2 documents
      llm_response = """
      [
        {"doc_index": 0, "score": 9},
        {"doc_index": 1, "score": 7}
      ]
      """

      expect(Rag.Router, :execute, fn _router, :text, _prompt, _opts ->
        {:ok, llm_response, reranker.router}
      end)

      {:ok, results} = LLM.rerank(reranker, query, @sample_documents, [])

      # Should still return all documents, unscored ones keep original scores
      assert length(results) == 3
    end

    @tag :requires_llm_provider
    test "normalizes scores to 0-1 range when requested" do
      reranker = LLM.new()
      query = "test"

      llm_response = """
      [
        {"doc_index": 0, "score": 10},
        {"doc_index": 1, "score": 5},
        {"doc_index": 2, "score": 0}
      ]
      """

      expect(Rag.Router, :execute, fn _router, :text, _prompt, _opts ->
        {:ok, llm_response, reranker.router}
      end)

      {:ok, results} = LLM.rerank(reranker, query, @sample_documents, normalize_scores: true)

      # Scores should be normalized from 10-point scale to 0-1
      assert Enum.at(results, 0).score == 1.0
      assert Enum.at(results, 1).score == 0.5
      assert Enum.at(results, 2).score == 0.0
    end
  end

  describe "integration with convenience function" do
    @tag :requires_llm_provider
    test "works with LLM reranker through convenience function" do
      reranker = LLM.new()
      query = "What is Elixir?"

      llm_response = """
      [
        {"doc_index": 0, "score": 9},
        {"doc_index": 1, "score": 7},
        {"doc_index": 2, "score": 3}
      ]
      """

      expect(Rag.Router, :execute, fn _router, :text, _prompt, _opts ->
        {:ok, llm_response, reranker.router}
      end)

      {:ok, results} = Reranker.rerank(reranker, query, @sample_documents)

      assert length(results) == 3
      assert Enum.at(results, 0).id == 1
    end

    test "works with Passthrough reranker through convenience function" do
      reranker = %Passthrough{}
      query = "What is Elixir?"

      {:ok, results} = Reranker.rerank(reranker, query, @sample_documents)

      assert results == @sample_documents
    end
  end
end
