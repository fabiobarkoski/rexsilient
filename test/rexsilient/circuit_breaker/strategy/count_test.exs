defmodule Rexsilient.CircuitBreaker.Strategy.CountTest do
  use ExUnit.Case, async: true

  alias Rexsilient.CircuitBreaker.Strategy.Count

  @threshold 3

  defp new(opts \\ [threshold: @threshold]), do: Count.init(opts)

  defp fail(state, times), do: for(_ <- 1..times, do: Count.record(state, :failure, 0))

  describe "init/1" do
    test "requires a threshold" do
      assert_raise ArgumentError, "threshold is required", fn -> Count.init([]) end
    end

    test "requires a positive integer threshold" do
      assert_raise ArgumentError, ~r/threshold must be a positive integer/, fn ->
        Count.init(threshold: "5")
      end
    end
  end

  describe "record/3" do
    test "stays :ok below the threshold" do
      assert fail(new(), @threshold - 1) == List.duplicate(:ok, @threshold - 1)
    end

    test "trips at the threshold" do
      state = new()
      fail(state, @threshold - 1)
      assert Count.record(state, :failure, 0) == :trip
    end

    test "keeps tripping after the threshold" do
      state = new()
      fail(state, @threshold)
      assert Count.record(state, :failure, 0) == :trip
    end

    test "a success is :ok and does not reset the count" do
      state = new()
      fail(state, @threshold - 1)
      assert Count.record(state, :success, 0) == :ok
      assert Count.record(state, :failure, 0) == :trip
    end

    test "a threshold of 1 trips on the first failure" do
      assert Count.record(new(threshold: 1), :failure, 0) == :trip
    end

    test "counts every concurrent failure" do
      state = new(threshold: 1_000)

      1..999
      |> Task.async_stream(fn _ -> Count.record(state, :failure, 0) end, max_concurrency: 100)
      |> Stream.run()

      assert Count.record(state, :failure, 0) == :trip
    end
  end

  describe "reset/1" do
    test "starts the count again from 0" do
      state = new()
      fail(state, @threshold)

      assert Count.reset(state) == :ok
      assert fail(state, @threshold - 1) == List.duplicate(:ok, @threshold - 1)
      assert Count.record(state, :failure, 0) == :trip
    end
  end
end
