defmodule Rag.Pipeline.Context do
  @moduledoc """
  Context passed between pipeline steps.

  The context holds all intermediate results and state as a pipeline
  executes. Steps can read from and write to the context to pass
  data between stages.
  """

  @type t :: %__MODULE__{
          input: any(),
          query: String.t() | nil,
          query_embedding: list(number()) | nil,
          retrieval_results: any(),
          reranked_results: any(),
          context_text: String.t() | nil,
          response: String.t() | nil,
          metadata: map(),
          errors: list(any())
        }

  defstruct [
    :input,
    :query,
    :query_embedding,
    :retrieval_results,
    :reranked_results,
    :context_text,
    :response,
    metadata: %{},
    errors: []
  ]

  @doc """
  Creates a new context with the given input.
  """
  @spec new(input :: any()) :: t()
  def new(input) do
    %__MODULE__{
      input: input,
      metadata: %{step_results: %{}}
    }
  end

  @doc """
  Puts a value in the context metadata.
  """
  @spec put_metadata(t(), key :: atom(), value :: any()) :: t()
  def put_metadata(%__MODULE__{} = context, key, value) do
    %{context | metadata: Map.put(context.metadata, key, value)}
  end

  @doc """
  Puts a step result in the context metadata.
  """
  @spec put_step_result(t(), step_name :: atom(), result :: any()) :: t()
  def put_step_result(%__MODULE__{} = context, step_name, result) do
    step_results = Map.put(context.metadata.step_results, step_name, result)
    put_in(context.metadata.step_results, step_results)
  end

  @doc """
  Gets a step result from the context metadata.
  """
  @spec get_step_result(t(), step_name :: atom()) :: any()
  def get_step_result(%__MODULE__{} = context, step_name) do
    context.metadata.step_results[step_name]
  end

  @doc """
  Adds an error to the context.
  """
  @spec add_error(t(), error :: any()) :: t()
  def add_error(%__MODULE__{} = context, error) do
    %{context | errors: [error | context.errors]}
  end
end
