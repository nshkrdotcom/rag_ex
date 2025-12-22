defmodule Rag.PipelineTest do
  use ExUnit.Case, async: true

  alias Rag.Pipeline
  alias Rag.Pipeline.Step
  alias Rag.Pipeline.Context

  describe "new/2" do
    test "creates a new pipeline with name" do
      pipeline = Pipeline.new(:test_pipeline)

      assert %Pipeline{
               name: :test_pipeline,
               steps: [],
               config: %{},
               metadata: %{}
             } = pipeline
    end

    test "creates a new pipeline with options" do
      pipeline =
        Pipeline.new(:test_pipeline,
          description: "A test pipeline",
          config: %{timeout: 5000},
          metadata: %{version: "1.0"}
        )

      assert %Pipeline{
               name: :test_pipeline,
               description: "A test pipeline",
               config: %{timeout: 5000},
               metadata: %{version: "1.0"}
             } = pipeline
    end
  end

  describe "add_step/2" do
    test "adds a step struct to pipeline" do
      pipeline = Pipeline.new(:test_pipeline)

      step = %Step{
        name: :step1,
        module: SomeModule,
        function: :some_function,
        args: []
      }

      pipeline = Pipeline.add_step(pipeline, step)

      assert [%Step{name: :step1}] = pipeline.steps
    end

    test "adds a step from keyword list" do
      pipeline = Pipeline.new(:test_pipeline)

      pipeline =
        Pipeline.add_step(pipeline,
          name: :step1,
          module: SomeModule,
          function: :some_function,
          args: [arg1: "value"]
        )

      assert [%Step{name: :step1, module: SomeModule, function: :some_function}] =
               pipeline.steps
    end

    test "adds multiple steps in order" do
      pipeline =
        Pipeline.new(:test_pipeline)
        |> Pipeline.add_step(name: :step1, module: Mod1, function: :func1)
        |> Pipeline.add_step(name: :step2, module: Mod2, function: :func2)

      assert [%Step{name: :step1}, %Step{name: :step2}] = pipeline.steps
    end
  end

  describe "execute/3 - sequential execution" do
    test "executes steps sequentially and returns result" do
      pipeline =
        Pipeline.new(:test_pipeline)
        |> Pipeline.add_step(
          name: :double,
          module: __MODULE__.TestSteps,
          function: :double,
          args: []
        )
        |> Pipeline.add_step(
          name: :add_ten,
          module: __MODULE__.TestSteps,
          function: :add_ten,
          args: []
        )

      assert {:ok, 30, context} = Pipeline.execute(pipeline, 10)
      assert %Context{input: 10} = context
      assert context.metadata[:step_results][:double] == 20
      assert context.metadata[:step_results][:add_ten] == 30
    end

    test "passes context between steps" do
      pipeline =
        Pipeline.new(:test_pipeline)
        |> Pipeline.add_step(
          name: :set_value,
          module: __MODULE__.TestSteps,
          function: :set_value,
          args: [key: :test, value: "hello"]
        )
        |> Pipeline.add_step(
          name: :get_value,
          module: __MODULE__.TestSteps,
          function: :get_value,
          args: [key: :test]
        )

      assert {:ok, "hello", _context} = Pipeline.execute(pipeline, nil)
    end

    test "emits telemetry events for each step" do
      pipeline =
        Pipeline.new(:test_pipeline)
        |> Pipeline.add_step(
          name: :step1,
          module: __MODULE__.TestSteps,
          function: :double,
          args: []
        )

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:rag, :pipeline, :step, :start],
          [:rag, :pipeline, :step, :stop]
        ])

      Pipeline.execute(pipeline, 5)

      assert_received {[:rag, :pipeline, :step, :start], ^ref, _measurement,
                       %{pipeline: :test_pipeline, step: :step1}}

      assert_received {[:rag, :pipeline, :step, :stop], ^ref, _measurement,
                       %{pipeline: :test_pipeline, step: :step1}}
    end
  end

  describe "execute/3 - parallel execution" do
    test "executes independent steps in parallel" do
      pipeline =
        Pipeline.new(:test_pipeline)
        |> Pipeline.add_step(
          name: :slow_step1,
          module: __MODULE__.TestSteps,
          function: :slow_operation,
          args: [result: "result1"],
          parallel: true
        )
        |> Pipeline.add_step(
          name: :slow_step2,
          module: __MODULE__.TestSteps,
          function: :slow_operation,
          args: [result: "result2"],
          parallel: true
        )
        |> Pipeline.add_step(
          name: :combine,
          module: __MODULE__.TestSteps,
          function: :combine_results,
          args: [],
          inputs: [:slow_step1, :slow_step2]
        )

      start_time = System.monotonic_time(:millisecond)
      assert {:ok, result, _context} = Pipeline.execute(pipeline, nil)
      end_time = System.monotonic_time(:millisecond)

      # Should complete faster than sequential (2x 100ms = 200ms)
      # Parallel should be ~100ms
      assert end_time - start_time < 150

      assert result == "result1,result2"
    end

    test "respects step dependencies with inputs" do
      pipeline =
        Pipeline.new(:test_pipeline)
        |> Pipeline.add_step(
          name: :step1,
          module: __MODULE__.TestSteps,
          function: :double,
          args: []
        )
        |> Pipeline.add_step(
          name: :step2,
          module: __MODULE__.TestSteps,
          function: :use_previous_result,
          args: [],
          inputs: [:step1]
        )

      assert {:ok, 40, _context} = Pipeline.execute(pipeline, 10)
    end
  end

  describe "execute/3 - error handling" do
    test "halts pipeline on error with :halt strategy" do
      pipeline =
        Pipeline.new(:test_pipeline)
        |> Pipeline.add_step(
          name: :failing_step,
          module: __MODULE__.TestSteps,
          function: :fail,
          args: [],
          on_error: :halt
        )
        |> Pipeline.add_step(
          name: :should_not_run,
          module: __MODULE__.TestSteps,
          function: :double,
          args: []
        )

      assert {:error, {:step_failed, :failing_step, "intentional failure"}} =
               Pipeline.execute(pipeline, 10)
    end

    test "continues pipeline on error with :continue strategy" do
      pipeline =
        Pipeline.new(:test_pipeline)
        |> Pipeline.add_step(
          name: :failing_step,
          module: __MODULE__.TestSteps,
          function: :fail,
          args: [],
          on_error: :continue
        )
        |> Pipeline.add_step(
          name: :should_run,
          module: __MODULE__.TestSteps,
          function: :double,
          args: []
        )

      assert {:ok, 20, context} = Pipeline.execute(pipeline, 10)
      assert length(context.errors) == 1
      assert {:failing_step, "intentional failure"} in context.errors
    end

    test "retries step on error with :retry strategy" do
      # Start with 3 failures, then succeed
      {:ok, agent} = Agent.start_link(fn -> 3 end)

      pipeline =
        Pipeline.new(:test_pipeline)
        |> Pipeline.add_step(
          name: :retry_step,
          module: __MODULE__.TestSteps,
          function: :fail_n_times,
          args: [agent: agent],
          on_error: {:retry, 3}
        )

      assert {:ok, :success, _context} = Pipeline.execute(pipeline, nil)

      Agent.stop(agent)
    end

    test "fails after max retries" do
      {:ok, agent} = Agent.start_link(fn -> 10 end)

      pipeline =
        Pipeline.new(:test_pipeline)
        |> Pipeline.add_step(
          name: :retry_step,
          module: __MODULE__.TestSteps,
          function: :fail_n_times,
          args: [agent: agent],
          on_error: {:retry, 2}
        )

      assert {:error, {:step_failed, :retry_step, "intentional failure"}} =
               Pipeline.execute(pipeline, nil)

      Agent.stop(agent)
    end
  end

  describe "execute/3 - caching" do
    test "caches step results when cache: true" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      # Use unique pipeline name to avoid cache collision between tests
      pipeline_name = :"cache_test_#{:erlang.unique_integer()}"

      pipeline =
        Pipeline.new(pipeline_name)
        |> Pipeline.add_step(
          name: :expensive_step,
          module: __MODULE__.TestSteps,
          function: :increment_counter,
          args: [agent: agent],
          cache: true
        )
        |> Pipeline.add_step(
          name: :use_cached,
          module: __MODULE__.TestSteps,
          function: :use_previous_result,
          args: [],
          inputs: [:expensive_step]
        )

      # First execution
      assert {:ok, 2, _context} = Pipeline.execute(pipeline, nil)
      assert Agent.get(agent, & &1) == 1

      # Second execution should use cache
      assert {:ok, 2, _context} = Pipeline.execute(pipeline, nil)
      # Counter should still be 1 (not incremented again)
      assert Agent.get(agent, & &1) == 1

      Agent.stop(agent)
    end

    test "does not cache when cache: false" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      # Use unique pipeline name
      pipeline_name = :"no_cache_test_#{:erlang.unique_integer()}"

      pipeline =
        Pipeline.new(pipeline_name)
        |> Pipeline.add_step(
          name: :not_cached,
          module: __MODULE__.TestSteps,
          function: :increment_counter,
          args: [agent: agent],
          cache: false
        )

      # First execution
      assert {:ok, 1, _context} = Pipeline.execute(pipeline, nil)
      assert Agent.get(agent, & &1) == 1

      # Second execution should NOT use cache
      assert {:ok, 2, _context} = Pipeline.execute(pipeline, nil)
      assert Agent.get(agent, & &1) == 2

      Agent.stop(agent)
    end
  end

  describe "execute/3 - timeouts" do
    test "respects step timeout" do
      pipeline =
        Pipeline.new(:test_pipeline)
        |> Pipeline.add_step(
          name: :slow_step,
          module: __MODULE__.TestSteps,
          function: :very_slow_operation,
          args: [],
          timeout: 50
        )

      assert {:error, {:step_timeout, :slow_step}} = Pipeline.execute(pipeline, nil)
    end

    test "does not timeout when step completes in time" do
      pipeline =
        Pipeline.new(:test_pipeline)
        |> Pipeline.add_step(
          name: :fast_step,
          module: __MODULE__.TestSteps,
          function: :double,
          args: [],
          timeout: 1000
        )

      assert {:ok, 20, _context} = Pipeline.execute(pipeline, 10)
    end
  end

  # Test helper module with step functions
  defmodule TestSteps do
    def double(input, _context, _opts) when is_number(input) do
      {:ok, input * 2}
    end

    def add_ten(input, _context, _opts) when is_number(input) do
      {:ok, input + 10}
    end

    def set_value(_input, context, opts) do
      key = Keyword.fetch!(opts, :key)
      value = Keyword.fetch!(opts, :value)
      new_metadata = Map.put(context.metadata, key, value)
      {:ok, value, %{context | metadata: new_metadata}}
    end

    def get_value(_input, context, opts) do
      key = Keyword.fetch!(opts, :key)
      {:ok, context.metadata[key]}
    end

    def slow_operation(_input, _context, opts) do
      Process.sleep(100)
      result = Keyword.fetch!(opts, :result)
      {:ok, result}
    end

    def combine_results(_input, context, _opts) do
      results = context.metadata.step_results
      result = "#{results[:slow_step1]},#{results[:slow_step2]}"
      {:ok, result}
    end

    def use_previous_result(input, _context, _opts) do
      {:ok, input * 2}
    end

    def fail(_input, _context, _opts) do
      {:error, "intentional failure"}
    end

    def fail_n_times(_input, _context, opts) do
      agent = Keyword.fetch!(opts, :agent)

      case Agent.get_and_update(agent, fn count -> {count, max(0, count - 1)} end) do
        0 -> {:ok, :success}
        _ -> {:error, "intentional failure"}
      end
    end

    def increment_counter(_input, _context, opts) do
      agent = Keyword.fetch!(opts, :agent)
      value = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)
      {:ok, value}
    end

    def very_slow_operation(_input, _context, _opts) do
      Process.sleep(5000)
      {:ok, :done}
    end
  end
end
