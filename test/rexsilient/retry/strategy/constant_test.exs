defmodule Rexsilient.Retry.Strategy.ConstantTest do
  use ExUnit.Case, async: true

  alias Rexsilient.Retry.Strategy.Constant

  defp context(attempt), do: %{attempt: attempt, outcome: {:value, :error}}

  describe "init/1" do
    test "requires a delay" do
      assert_raise ArgumentError, "delay is required", fn -> Constant.init([]) end
    end

    test "rejects a negative delay" do
      assert_raise ArgumentError, ~r/delay must be a non-negative integer/, fn ->
        Constant.init(delay: -1)
      end
    end

    test "rejects unknown options" do
      assert_raise ArgumentError, ~r/unknown keys \[:other\]/, fn ->
        Constant.init(delay: 100, other: 1)
      end
    end
  end

  describe "delay/2" do
    test "returns the same delay for every attempt" do
      state = Constant.init(delay: 100)

      for attempt <- 1..5 do
        assert Constant.delay(context(attempt), state) == {:retry, 100, state}
      end
    end
  end
end
