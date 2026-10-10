defmodule Rexsilient.CircuitBreaker.Strategy.SlidingWindowTest do
  use ExUnit.Case, async: true

  alias Rexsilient.CircuitBreaker.Strategy.SlidingWindow

  @threshold 3
  # Long enough that no test without a sleep leaves the window.
  @window :timer.seconds(60)

  defp new(opts \\ [threshold: @threshold, window: @window]), do: SlidingWindow.init(opts)

  defp fail(state, times), do: for(_ <- 1..times, do: SlidingWindow.record(state, :failure, 0))

  describe "init/1" do
    test "requires a threshold and a window" do
      assert_raise ArgumentError, ~r/window/, fn -> SlidingWindow.init(threshold: 3) end
      assert_raise ArgumentError, ~r/threshold/, fn -> SlidingWindow.init(window: 1_000) end
    end

    test "rejects a threshold of 0" do
      assert_raise ArgumentError, ~r/threshold must be a positive integer/, fn ->
        SlidingWindow.init(threshold: 0, window: 1_000)
      end
    end
  end

  describe "record/3" do
    test "stays :ok below the threshold" do
      assert fail(new(), @threshold - 1) == List.duplicate(:ok, @threshold - 1)
    end

    test "trips at the threshold within the window" do
      state = new()
      fail(state, @threshold - 1)
      assert SlidingWindow.record(state, :failure, 0) == :trip
    end

    test "keeps tripping as the ring wraps around" do
      results = fail(new(), @threshold * 4)

      assert results ==
               List.duplicate(:ok, @threshold - 1) ++
                 List.duplicate(:trip, @threshold * 4 - (@threshold - 1))
    end

    test "a success is :ok and does not touch the window" do
      state = new()
      fail(state, @threshold - 1)
      assert SlidingWindow.record(state, :success, 0) == :ok
      assert SlidingWindow.record(state, :failure, 0) == :trip
    end

    test "failures spread wider than the window do not trip" do
      state = new(threshold: 3, window: 100)

      # failures at ~0, ~60 and ~120 ms: the first and the third are > 100 ms apart
      assert SlidingWindow.record(state, :failure, 0) == :ok
      Process.sleep(60)
      assert SlidingWindow.record(state, :failure, 0) == :ok
      Process.sleep(60)
      assert SlidingWindow.record(state, :failure, 0) == :ok

      # failures at ~60, ~120 and ~120 ms fit in the window again
      assert SlidingWindow.record(state, :failure, 0) == :trip
    end

    test "a threshold of 1 trips on the first failure" do
      assert SlidingWindow.record(new(threshold: 1, window: @window), :failure, 0) == :trip
    end
  end

  describe "reset/1" do
    test "forgets the failures recorded before it" do
      state = new()
      fail(state, @threshold)

      assert SlidingWindow.reset(state) == :ok
      assert fail(state, @threshold - 1) == List.duplicate(:ok, @threshold - 1)
      assert SlidingWindow.record(state, :failure, 0) == :trip
    end

    test "works with a threshold of 1" do
      assert SlidingWindow.reset(new(threshold: 1, window: @window)) == :ok
    end
  end
end
