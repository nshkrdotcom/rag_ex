defmodule Rag.Pipeline do
  @moduledoc """
  Pipeline definition and execution for composable RAG workflows.

  Pipelines are sequences of steps that transform data through
  retrieval, reranking, context building, and generation.

  ## Example

      pipeline =
        Pipeline.new(:my_pipeline)
        |> Pipeline.add_step(
          name: :embed_query,
          module: MyApp.Steps,
          function: :embed_query,
          args: []
        )
        |> Pipeline.add_step(
          name: :retrieve,
          module: MyApp.Steps,
          function: :retrieve,
          args: [],
          inputs: [:embed_query]
        )

      {:ok, result, context} = Pipeline.execute(pipeline, "What is RAG?")
  """

  alias Rag.Pipeline.{Context, Executor}

  defstruct [
    :name,
    :description,
    steps: [],
    config: %{},
    metadata: %{}
  ]

  defmodule Step do
    @moduledoc """
    A single step in a pipeline.

    Each step defines a transformation function and how it should be executed.
    """

    @type t :: %__MODULE__{
            name: atom(),
            module: module(),
            function: atom(),
            args: keyword(),
            inputs: list(atom()) | nil,
            parallel: boolean() | nil,
            on_error: :halt | :continue | {:retry, non_neg_integer()} | nil,
            cache: boolean() | nil,
            timeout: non_neg_integer() | nil
          }

    defstruct [
      :name,
      :module,
      :function,
      args: [],
      inputs: nil,
      parallel: false,
      on_error: :halt,
      cache: false,
      timeout: nil
    ]
  end

  @type t :: %__MODULE__{
          name: atom(),
          description: String.t() | nil,
          steps: list(Step.t()),
          config: map(),
          metadata: map()
        }

  @type step :: Step.t()

  @doc """
  Creates a new pipeline with the given name and options.

  ## Options

    * `:description` - A description of the pipeline
    * `:config` - Configuration map for the pipeline
    * `:metadata` - Additional metadata for the pipeline

  ## Examples

      iex> Pipeline.new(:my_pipeline)
      %Pipeline{name: :my_pipeline, steps: [], config: %{}, metadata: %{}}

      iex> Pipeline.new(:my_pipeline, description: "A test pipeline")
      %Pipeline{name: :my_pipeline, description: "A test pipeline", steps: [], config: %{}, metadata: %{}}
  """
  @spec new(name :: atom(), opts :: keyword()) :: t()
  def new(name, opts \\ []) when is_atom(name) do
    %__MODULE__{
      name: name,
      description: Keyword.get(opts, :description),
      steps: [],
      config: Keyword.get(opts, :config, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Adds a step to the pipeline.

  The step can be provided as a `Step` struct or as a keyword list
  that will be converted to a `Step` struct.

  ## Examples

      iex> pipeline = Pipeline.new(:test)
      iex> step = %Pipeline.Step{name: :step1, module: MyModule, function: :my_func}
      iex> Pipeline.add_step(pipeline, step)
      %Pipeline{steps: [%Pipeline.Step{name: :step1}]}

      iex> pipeline = Pipeline.new(:test)
      iex> Pipeline.add_step(pipeline, name: :step1, module: MyModule, function: :my_func)
      %Pipeline{steps: [%Pipeline.Step{name: :step1}]}
  """
  @spec add_step(pipeline :: t(), step :: step() | keyword()) :: t()
  def add_step(%__MODULE__{} = pipeline, %Step{} = step) do
    %{pipeline | steps: pipeline.steps ++ [step]}
  end

  def add_step(%__MODULE__{} = pipeline, step_opts) when is_list(step_opts) do
    step = struct(Step, step_opts)
    add_step(pipeline, step)
  end

  @doc """
  Executes the pipeline with the given input.

  Returns `{:ok, result, context}` on success or `{:error, reason}` on failure.

  ## Options

    * `:timeout` - Overall timeout for the pipeline execution
    * `:telemetry_metadata` - Additional metadata to include in telemetry events

  ## Examples

      iex> pipeline = Pipeline.new(:test) |> Pipeline.add_step(...)
      iex> Pipeline.execute(pipeline, "input data")
      {:ok, result, %Context{}}
  """
  @spec execute(pipeline :: t(), input :: any(), opts :: keyword()) ::
          {:ok, result :: any(), context :: Context.t()} | {:error, term()}
  def execute(%__MODULE__{} = pipeline, input, opts \\ []) do
    Executor.execute(pipeline, input, opts)
  end
end
