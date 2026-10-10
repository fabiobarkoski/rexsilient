defmodule Rexsilient.CircuitBreaker.Recover.BasicTimeoutTest do
  use ExUnit.Case, async: true

  alias Rexsilient.CircuitBreaker.Recover.BasicTimeout

  @opts [reset_timeout: 5_000, probing_timeout: 1_000]

  defp new(opts), do: BasicTimeout.init(opts)

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
  end

  describe "timeout/2" do
    test "returns reset_timeout when the breaker opens" do
      state = new(@opts)
      assert BasicTimeout.timeout({:closed, :open}, state) == {5_000, state}
      assert BasicTimeout.timeout({:probing, :open}, state) == {5_000, state}
    end

    test "returns probing_timeout when a probe starts" do
      state = new(@opts)
      assert BasicTimeout.timeout({:half_open, :probing}, state) == {1_000, state}
    end

    test "returns the same value every time" do
      results =
        Enum.map_reduce(1..5, new(@opts), fn _, state ->
          BasicTimeout.timeout({:closed, :open}, state)
        end)

      assert elem(results, 0) == List.duplicate(5_000, 5)
    end
  end
end
