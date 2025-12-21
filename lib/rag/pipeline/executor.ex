defmodule Rag.Pipeline.Executor do
  @moduledoc """
  Executes pipeline steps with:
  - Sequential and parallel execution
  - Caching between steps
  - Error handling with retry/halt/continue
  - Telemetry emission
  """

  alias Rag.Pipeline
  alias Rag.Pipeline.{Context, Step}

  @type cache :: %{atom() => any()}
  @type execution_state :: %{
          pipeline: Pipeline.t(),
          context: Context.t(),
          cache: cache(),
          current_result: any()
        }

  @doc """
  Executes a pipeline with the given input.

  Returns `{:ok, result, context}` on success or `{:error, reason}` on failure.
  """
  @spec execute(Pipeline.t(), any(), keyword()) ::
          {:ok, any(), Context.t()} | {:error, term()}
  def execute(%Pipeline{} = pipeline, input, _opts \\ []) do
    context = Context.new(input)
    cache = initialize_cache(pipeline.name)

    state = %{
      pipeline: pipeline,
      context: context,
      cache: cache,
      current_result: input
    }

    case execute_steps(pipeline.steps, state) do
      {:ok, final_state} ->
        # Don't cleanup cache, keep it for future runs
        {:ok, final_state.current_result, final_state.context}

      {:error, reason} ->
        # Don't cleanup cache on error either
        {:error, reason}
    end
  end

  # Initialize cache using ETS for persistent caching across executions
  defp initialize_cache(pipeline_name) do
    table_name = cache_table_name(pipeline_name)

    # Check if table already exists
    case :ets.whereis(table_name) do
      :undefined ->
        # Create new ETS table
        :ets.new(table_name, [:set, :public, :named_table])

      _ref ->
        # Table already exists, reuse it
        table_name
    end
  end

  defp cache_table_name(pipeline_name) do
    :"rag_pipeline_cache_#{pipeline_name}"
  end

  # Execute all steps in the pipeline
  defp execute_steps(steps, state) do
    # Group steps by parallel execution
    step_groups = group_steps_for_execution(steps)

    Enum.reduce_while(step_groups, {:ok, state}, fn group, {:ok, current_state} ->
      case execute_step_group(group, current_state) do
        {:ok, new_state} -> {:cont, {:ok, new_state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Group steps into sequential and parallel groups
  defp group_steps_for_execution(steps) do
    steps
    |> Enum.chunk_by(fn step -> step.parallel end)
    |> Enum.map(fn group ->
      case group do
        [%Step{parallel: true} | _] -> {:parallel, group}
        _ -> {:sequential, group}
      end
    end)
  end

  # Execute a group of steps (either sequential or parallel)
  defp execute_step_group({:sequential, steps}, state) do
    Enum.reduce_while(steps, {:ok, state}, fn step, {:ok, current_state} ->
      case execute_single_step(step, current_state) do
        {:ok, new_state} -> {:cont, {:ok, new_state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp execute_step_group({:parallel, steps}, state) do
    # Execute steps in parallel using Task.async_stream
    tasks =
      steps
      |> Enum.map(fn step ->
        Task.async(fn ->
          # Each parallel step gets the current state
          execute_single_step(step, state)
        end)
      end)

    # Wait for all tasks to complete
    results =
      tasks
      |> Enum.map(&Task.await(&1, :infinity))

    # Check if any failed
    case Enum.find(results, fn result -> match?({:error, _}, result) end) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        # All succeeded, merge results into state
        final_state =
          Enum.reduce(results, state, fn {:ok, step_state}, acc_state ->
            # Merge step results and context
            # Cache is shared (ETS table), so no need to merge
            %{
              acc_state
              | context: merge_contexts(acc_state.context, step_state.context)
            }
          end)

        {:ok, final_state}
    end
  end

  # Execute a single step
  defp execute_single_step(%Step{} = step, state) do
    # Check cache first
    case get_cached_result(step, state.cache) do
      {:ok, cached_result} ->
        # Use cached result
        new_state = update_state_with_result(state, step, cached_result)
        {:ok, new_state}

      :miss ->
        # Execute the step
        execute_step_with_retry(step, state, 0)
    end
  end

  # Execute step with retry logic
  defp execute_step_with_retry(%Step{} = step, state, attempt) do
    max_retries =
      case step.on_error do
        {:retry, n} -> n
        _ -> 0
      end

    # Determine input for this step
    input = determine_step_input(step, state)

    # Emit telemetry start event
    metadata = %{
      pipeline: state.pipeline.name,
      step: step.name,
      attempt: attempt
    }

    start_time = System.monotonic_time()
    :telemetry.execute([:rag, :pipeline, :step, :start], %{}, metadata)

    # Execute the step function with timeout if specified
    result =
      if step.timeout do
        execute_with_timeout(step, input, state.context, step.timeout)
      else
        execute_step_function(step, input, state.context)
      end

    duration = System.monotonic_time() - start_time

    case result do
      {:ok, step_result} ->
        # Emit telemetry stop event
        :telemetry.execute(
          [:rag, :pipeline, :step, :stop],
          %{duration: duration},
          metadata
        )

        # Update state with result
        new_state = update_state_with_result(state, step, step_result)

        # Cache if needed
        if step.cache do
          cache_result(step, state.cache, step_result)
        end

        {:ok, new_state}

      {:ok, step_result, updated_context} ->
        # Step returned updated context
        :telemetry.execute(
          [:rag, :pipeline, :step, :stop],
          %{duration: duration},
          metadata
        )

        new_state = %{
          state
          | current_result: step_result,
            context: Context.put_step_result(updated_context, step.name, step_result)
        }

        if step.cache do
          cache_result(step, state.cache, step_result)
        end

        {:ok, new_state}

      {:error, error} ->
        # Emit telemetry exception event
        :telemetry.execute(
          [:rag, :pipeline, :step, :exception],
          %{duration: duration},
          Map.put(metadata, :error, error)
        )

        handle_step_error(step, state, error, attempt, max_retries)
    end
  end

  # Execute step function
  defp execute_step_function(%Step{} = step, input, context) do
    apply(step.module, step.function, [input, context, step.args])
  end

  # Execute with timeout
  defp execute_with_timeout(%Step{} = step, input, context, timeout) do
    task = Task.async(fn -> execute_step_function(step, input, context) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, {:timeout, step.name}}
    end
  end

  # Handle step errors based on error strategy
  defp handle_step_error(step, state, error, attempt, max_retries) do
    case step.on_error do
      :halt ->
        handle_halt_error(step, error)

      :continue ->
        # Add error to context and continue
        new_context = Context.add_error(state.context, {step.name, error})
        {:ok, %{state | context: new_context}}

      {:retry, _} when attempt < max_retries ->
        # Retry the step
        execute_step_with_retry(step, state, attempt + 1)

      {:retry, _} ->
        # Max retries reached
        handle_halt_error(step, error)

      _ ->
        handle_halt_error(step, error)
    end
  end

  # Handle halt error, checking for timeout
  defp handle_halt_error(step, {:timeout, _step_name}) do
    {:error, {:step_timeout, step.name}}
  end

  defp handle_halt_error(step, error) do
    {:error, {:step_failed, step.name, error}}
  end

  # Determine input for a step based on its dependencies
  defp determine_step_input(%Step{inputs: nil}, state) do
    # No dependencies, use current result
    state.current_result
  end

  defp determine_step_input(%Step{inputs: [single_input]}, state) do
    # Single dependency, use its result
    Context.get_step_result(state.context, single_input)
  end

  defp determine_step_input(%Step{inputs: inputs}, state) when is_list(inputs) do
    # Multiple dependencies, pass map of results
    Enum.reduce(inputs, %{}, fn input_name, acc ->
      Map.put(acc, input_name, Context.get_step_result(state.context, input_name))
    end)
  end

  # Update state with step result
  defp update_state_with_result(state, step, result) do
    new_context = Context.put_step_result(state.context, step.name, result)

    %{state | current_result: result, context: new_context}
  end

  # Get cached result for a step
  defp get_cached_result(%Step{cache: true, name: name}, cache) do
    case :ets.lookup(cache, name) do
      [{^name, result}] -> {:ok, result}
      [] -> :miss
    end
  end

  defp get_cached_result(%Step{cache: false}, _cache), do: :miss
  defp get_cached_result(%Step{cache: nil}, _cache), do: :miss

  # Cache a result for a step
  defp cache_result(%Step{name: name}, cache, result) do
    :ets.insert(cache, {name, result})
  end

  # Merge contexts from parallel execution
  defp merge_contexts(context1, context2) do
    # Merge step results
    merged_step_results =
      Map.merge(
        context1.metadata.step_results,
        context2.metadata.step_results
      )

    # Merge errors
    merged_errors = context1.errors ++ context2.errors

    # Merge other metadata
    merged_metadata =
      context1.metadata
      |> Map.merge(context2.metadata)
      |> Map.put(:step_results, merged_step_results)

    %{context1 | metadata: merged_metadata, errors: merged_errors}
  end
end
