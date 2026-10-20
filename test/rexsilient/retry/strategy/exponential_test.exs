defmodule Rexsilient.Retry.Strategy.ExponentialTest do
  use ExUnit.Case, async: true

  alias Rexsilient.Retry.Strategy.Exponential

  @opts [base_delay: 100, max_delay: 1_000]

  defp context(attempt), do: %{attempt: attempt, outcome: {:value, :error}}

  defp delays(state, attempts) do
    for attempt <- attempts do
      {:retry, delay, ^state} = Exponential.delay(context(attempt), state)
      delay
    end
  end

  describe "init/1" do
    test "requires a base_delay" do
      assert_raise ArgumentError, "base_delay is required", fn ->
        Exponential.init(max_delay: 1_000)
      end
    end

    test "requires a max_delay" do
      assert_raise ArgumentError, "max_delay is required", fn ->
        Exponential.init(base_delay: 100)
      end
    end

    test "rejects a max_delay less than base_delay" do
      assert_raise ArgumentError, "max_delay must not be less than base_delay", fn ->
        Exponential.init(base_delay: 100, max_delay: 50)
      end
    end

    test "defaults jitter to :none" do
      assert %{jitter: :none} = Exponential.init(@opts)
    end

    test "rejects an unknown jitter" do
      assert_raise ArgumentError, ~r/jitter must be one of \[:none, :full, :equal\]/, fn ->
        Exponential.init(@opts ++ [jitter: :random])
      end
    end

    test "rejects options that are not a keyword list" do
      assert_raise ArgumentError, ~r/options must be a keyword list/, fn ->
        Exponential.init(:nope)
      end
    end
  end

  describe "delay/2" do
    test "doubles the delay after every attempt, up to max_delay" do
      assert delays(Exponential.init(@opts), 1..6) == [100, 200, 400, 800, 1_000, 1_000]
    end

    test "with :full jitter, returns a delay from 0 to the exponential one" do
      state = Exponential.init(@opts ++ [jitter: :full])

      for attempt <- 1..6, delay <- delays(state, List.duplicate(attempt, 50)) do
        assert delay in 0..min(100 * 2 ** (attempt - 1), 1_000)
      end
    end

    test "with :equal jitter, returns a delay from half the exponential one to it" do
      state = Exponential.init(@opts ++ [jitter: :equal])

      for attempt <- 1..6, delay <- delays(state, List.duplicate(attempt, 50)) do
        backoff = min(100 * 2 ** (attempt - 1), 1_000)
        assert delay in div(backoff, 2)..backoff
      end
    end
  end
end
