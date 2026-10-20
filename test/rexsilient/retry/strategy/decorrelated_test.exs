defmodule Rexsilient.Retry.Strategy.DecorrelatedTest do
  use ExUnit.Case, async: true

  alias Rexsilient.Retry.Strategy.Decorrelated

  @opts [base_delay: 100, max_delay: 1_000]

  defp context(attempt), do: %{attempt: attempt, outcome: {:value, :error}}

  describe "init/1" do
    test "requires a base_delay" do
      assert_raise ArgumentError, "base_delay is required", fn ->
        Decorrelated.init(max_delay: 1_000)
      end
    end

    test "requires a positive base_delay" do
      assert_raise ArgumentError, ~r/base_delay must be a positive integer/, fn ->
        Decorrelated.init(base_delay: 0, max_delay: 1_000)
      end
    end

    test "rejects a max_delay less than base_delay" do
      assert_raise ArgumentError, "max_delay must not be less than base_delay", fn ->
        Decorrelated.init(base_delay: 100, max_delay: 50)
      end
    end
  end

  describe "delay/2" do
    test "the first delay is from base_delay to three times it" do
      state = Decorrelated.init(@opts)

      for _ <- 1..50 do
        {:retry, delay, _state} = Decorrelated.delay(context(1), state)
        assert delay in 100..300
      end
    end

    test "each delay is from base_delay to three times the previous one, up to max_delay" do
      Enum.reduce(1..50, Decorrelated.init(@opts), fn attempt, state ->
        {:retry, delay, next} = Decorrelated.delay(context(attempt), state)

        assert delay in 100..min(state.previous * 3, 1_000)
        assert next.previous == delay
        next
      end)
    end
  end
end
