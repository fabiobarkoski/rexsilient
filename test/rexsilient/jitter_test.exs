defmodule Rexsilient.JitterTest do
  use ExUnit.Case, async: true

  alias Rexsilient.Jitter

  # Enough draws that every value of a small range shows up; the fixed seed
  # keeps failures reproducible.
  @samples 1_000

  setup do
    :rand.seed(:exsss, {1, 2, 3})
    :ok
  end

  defp sample(fun), do: for(_ <- 1..@samples, do: fun.())

  describe "full/3" do
    test "stays between 0 and the backoff for each attempt" do
      for attempt <- 0..6 do
        backoff = 10 * 2 ** attempt

        for delay <- sample(fn -> Jitter.full(10, 10_000, attempt) end) do
          assert is_integer(delay)
          assert delay in 0..backoff
        end
      end
    end

    test "covers the whole range, including 0 and the backoff" do
      delays = sample(fn -> Jitter.full(1, 100, 2) end)
      assert delays |> Enum.uniq() |> Enum.sort() == [0, 1, 2, 3, 4]
    end

    test "is capped at max_delay" do
      delays = sample(fn -> Jitter.full(100, 500, 10) end)
      assert Enum.max(delays) == 500
    end

    test "does not overflow on large attempts" do
      assert Jitter.full(100, 10_000, 1_000) in 0..10_000
    end
  end

  describe "equal/3" do
    test "stays between half the backoff and the backoff for each attempt" do
      for attempt <- 0..6 do
        backoff = 10 * 2 ** attempt

        for delay <- sample(fn -> Jitter.equal(10, 10_000, attempt) end) do
          assert is_integer(delay)
          assert delay in div(backoff, 2)..backoff
        end
      end
    end

    test "covers the whole range, including both ends" do
      delays = sample(fn -> Jitter.equal(1, 100, 3) end)
      assert delays |> Enum.uniq() |> Enum.sort() == [4, 5, 6, 7, 8]
    end

    test "never goes above the backoff when it is odd" do
      delays = sample(fn -> Jitter.equal(5, 5, 0) end)
      assert delays |> Enum.uniq() |> Enum.sort() == [2, 3, 4, 5]
    end

    test "is capped at max_delay" do
      for delay <- sample(fn -> Jitter.equal(100, 500, 10) end) do
        assert delay in 250..500
      end
    end
  end

  describe "decorrelated/3" do
    test "the first retry stays between base_delay and three times it" do
      delays = sample(fn -> Jitter.decorrelated(100, 10_000, 100) end)

      for delay <- delays do
        assert is_integer(delay)
        assert delay in 100..300
      end

      assert Enum.min(delays) == 100
      assert Enum.max(delays) == 300
    end

    test "stays between base_delay and three times previous_delay" do
      for delay <- sample(fn -> Jitter.decorrelated(100, 10_000, 1_000) end) do
        assert delay in 100..3_000
      end
    end

    test "is capped at max_delay" do
      delays = sample(fn -> Jitter.decorrelated(100, 500, 1_000) end)
      assert Enum.max(delays) == 500
    end

    test "chained delays stay between base_delay and max_delay" do
      Enum.reduce(1..@samples, 100, fn _, previous ->
        delay = Jitter.decorrelated(100, 5_000, previous)
        assert delay in 100..5_000
        delay
      end)
    end
  end
end
