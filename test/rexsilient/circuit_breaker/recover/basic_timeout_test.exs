defmodule Rexsilient.CircuitBreaker.Recover.BasicTimeoutTest do
  use ExUnit.Case, async: true

  alias Rexsilient.CircuitBreaker.Recover.BasicTimeout

  @opts [reset_timeout: 5_000, probing_timeout: 1_000]

  defp new(opts), do: BasicTimeout.init(opts)

  defp context(transition), do: %{transition: transition, outcome: nil}

  describe "init/1" do
    test "requires a reset_timeout" do
      assert_raise ArgumentError, ~r/reset_timeout/, fn ->
        BasicTimeout.init(probing_timeout: 1_000)
      end
    end

    test "rejects a negative timeout" do
      assert_raise ArgumentError, ~r/reset_timeout must be a non-negative integer/, fn ->
        BasicTimeout.init(reset_timeout: -1, probing_timeout: 1_000)
      end
    end

    test "requires a probing_timeout" do
      assert_raise ArgumentError, ~r/probing_timeout/, fn ->
        BasicTimeout.init(reset_timeout: 5_000)
      end
    end

    test "rejects a probing_timeout that is not positive" do
      for value <- [0, -1] do
        assert_raise ArgumentError, ~r/probing_timeout must be a positive integer/, fn ->
          BasicTimeout.init(reset_timeout: 5_000, probing_timeout: value)
        end
      end
    end

    test "accepts a reset_timeout of 0" do
      assert %{reset_timeout: 0} = BasicTimeout.init(reset_timeout: 0, probing_timeout: 1_000)
    end
  end

  describe "timeout/2" do
    test "returns reset_timeout when the breaker opens" do
      state = new(@opts)
      assert BasicTimeout.timeout(context({:closed, :open}), state) == {5_000, state}
      assert BasicTimeout.timeout(context({:probing, :open}), state) == {5_000, state}
    end

    test "returns probing_timeout when a probe starts" do
      state = new(@opts)
      assert BasicTimeout.timeout(context({:half_open, :probing}), state) == {1_000, state}
    end

    test "returns the same value every time" do
      results =
        Enum.map_reduce(1..5, new(@opts), fn _, state ->
          BasicTimeout.timeout(context({:closed, :open}), state)
        end)

      assert elem(results, 0) == List.duplicate(5_000, 5)
    end
  end
end
