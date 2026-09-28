defmodule Rexsilient.CircuitBreakerTest.Breakers do
  use Rexsilient

  circuit_breaker :cb_test do
    timeout 50
    threshold 3
  end
end

defmodule Rexsilient.CircuitBreakerTest do
  # The manager is a named singleton and breakers live in :persistent_term, so
  # these tests cannot run concurrently with each other.
  use ExUnit.Case, async: false

  import Bitwise

  alias Rexsilient.CircuitBreaker, as: CB

  @name :cb_test
  @timeout 50
  @threshold 3

  # Every start reinstalls the breaker, and install resets an existing one to
  # closed, so each test starts from a fresh closed breaker.
  setup do
    start_supervised!({CB, modules: [Rexsilient.CircuitBreakerTest.Breakers]})
    :ok
  end

  # Releases are casts; a call from this process is handled after them.
  defp sync, do: :sys.get_state(CB)

  defp trip! do
    for _ <- 1..@threshold, do: CB.run(@name, fn -> {:error, :boom} end)
    sync()
    assert CB.status(@name) == :open
  end

  defp wait_until(fun, timeout \\ 1_000) do
    cond do
      fun.() -> :ok
      timeout <= 0 -> flunk("condition not met in time")
      true -> Process.sleep(5) && wait_until(fun, timeout - 5)
    end
  end

  defp wait_for(status), do: wait_until(fn -> CB.status(@name) == status end)

  # The state counter, read from the packed state word (slot 1, above the 2
  # status bits). Only the wraparound tests need it.
  defp counter do
    ref = :persistent_term.get({CB, @name})
    :atomics.get(ref, 1) >>> 2
  end

  # Runs a probe that blocks until told to finish, so tests can act while the
  # breaker is probing. Returns the task and the pid to send :go to.
  defp start_blocking_call(result) do
    test = self()

    task =
      Task.async(fn ->
        CB.run(@name, fn ->
          send(test, {:running, self()})
          receive do: (:go -> result)
        end)
      end)

    assert_receive {:running, runner}
    {task, runner}
  end

  describe "run/3 results" do
    test "returns the function's result unchanged" do
      for value <- [{:ok, 1}, :ok, 42, %{a: 1}, {:error, :boom}, :error] do
        assert CB.run(@name, fn -> value end) == value
      end
    end

    test "a rejected call returns {:error, :circuit_open} and never runs the function" do
      trip!()
      assert CB.run(@name, fn -> send(self(), :called) end) == {:error, :circuit_open}
      refute_received :called
    end

    test "on_open: replaces the rejection value" do
      trip!()
      assert CB.run(@name, fn -> :ok end, on_open: {:error, :unavailable}) == {:error, :unavailable}
    end

    test "fallback: is called on rejection" do
      trip!()
      assert CB.run(@name, fn -> :ok end, fallback: fn -> :cached end) == :cached
    end

    test "an unknown breaker raises" do
      assert_raise ArgumentError, ~r/:nope/, fn -> CB.run(:nope, fn -> :ok end) end
    end
  end

  describe "tripping" do
    test "stays closed below the threshold" do
      for _ <- 1..(@threshold - 1), do: CB.run(@name, fn -> {:error, :boom} end)
      sync()
      assert CB.status(@name) == :closed
    end

    test "opens at the threshold" do
      trip!()
    end

    test "only :error and {:error, _} count as failures" do
      for value <- [:ok, {:ok, 1}, :whatever, {:error, :a}, {:error, :b}] do
        CB.run(@name, fn -> value end)
      end

      sync()
      assert CB.status(@name) == :closed

      CB.run(@name, fn -> :error end)
      sync()
      assert CB.status(@name) == :open
    end

    test "raise, throw and exit are re-raised unchanged and count as failures" do
      assert_raise RuntimeError, "boom", fn -> CB.run(@name, fn -> raise "boom" end) end
      assert catch_throw(CB.run(@name, fn -> throw(:ball) end)) == :ball
      assert catch_exit(CB.run(@name, fn -> exit(:bye) end)) == :bye

      sync()
      assert CB.status(@name) == :open
    end
  end

  describe "recovery" do
    test "goes half-open after the timeout" do
      trip!()
      wait_for(:half_open)
    end

    test "a successful probe closes the breaker and resets the failure count" do
      trip!()
      wait_for(:half_open)

      assert CB.run(@name, fn -> :ok end) == :ok
      sync()
      assert CB.status(@name) == :closed

      for _ <- 1..(@threshold - 1), do: CB.run(@name, fn -> {:error, :boom} end)
      sync()
      assert CB.status(@name) == :closed
    end

    test "a failed probe re-opens the breaker and it half-opens again" do
      trip!()
      wait_for(:half_open)

      CB.run(@name, fn -> {:error, :still_down} end)
      sync()
      assert CB.status(@name) == :open

      wait_for(:half_open)
    end

    test "other callers are rejected while the probe runs" do
      trip!()
      wait_for(:half_open)

      {task, runner} = start_blocking_call(:ok)
      assert CB.status(@name) == :probing
      assert CB.run(@name, fn -> :ok end) == {:error, :circuit_open}

      send(runner, :go)
      assert Task.await(task) == :ok
      sync()
      assert CB.status(@name) == :closed
    end

    test "exactly one of many concurrent callers wins the probe" do
      trip!()
      wait_for(:half_open)

      results =
        1..200
        |> Task.async_stream(fn _ -> CB.acquire(@name) end, max_concurrency: 200)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert CB.status(@name) == :probing
    end
  end

  describe "stale releases and timers" do
    test "a success from before the trip does not close a probing breaker" do
      {:ok, old_counter} = CB.acquire(@name)

      trip!()
      wait_for(:half_open)
      {:ok, _probe} = CB.acquire(@name)

      CB.release(@name, :success, old_counter)
      sync()
      assert CB.status(@name) == :probing
    end

    test "failures from before a close do not count afterwards" do
      {:ok, old_counter} = CB.acquire(@name)
      :ok = GenServer.call(CB, {:close, @name})

      for _ <- 1..@threshold, do: CB.release(@name, :failure, old_counter)
      sync()
      assert CB.status(@name) == :closed
    end

    test "a half-open timer armed before a close is ignored" do
      trip!()
      :ok = GenServer.call(CB, {:close, @name})

      Process.sleep(@timeout * 2)
      assert CB.status(@name) == :closed
    end
  end

  describe "admin" do
    test "open forces the breaker open with no timer" do
      :ok = GenServer.call(CB, {:open, @name})

      Process.sleep(@timeout * 2)
      assert CB.status(@name) == :open
    end

    test "close closes an open breaker" do
      trip!()
      :ok = GenServer.call(CB, {:close, @name})
      assert CB.status(@name) == :closed
    end

    test "an unknown name returns an error and does not crash the manager" do
      pid = Process.whereis(CB)

      assert GenServer.call(CB, {:open, :nope}) == {:error, :unknown_breaker}
      assert GenServer.call(CB, {:close, :nope}) == {:error, :unknown_breaker}
      assert Process.whereis(CB) == pid
    end
  end

  describe "manager restart" do
    test "an open breaker comes back closed (fail open)" do
      trip!()
      pid = Process.whereis(CB)
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      wait_until(fn -> Process.whereis(CB) not in [nil, pid] end)
      assert CB.status(@name) == :closed
    end
  end

  describe "state counter wraparound" do
    # Reaches into the atomics layout (slot 1, status in the low 2 bits) to start
    # the breaker at the largest counter; there is no public way to get there.
    @max_counter (1 <<< 61) - 1

    test "the counter goes back to 0 after the largest value" do
      ref = :persistent_term.get({CB, @name})
      :ok = :atomics.put(ref, 1, @max_counter <<< 2)
      assert {:ok, @max_counter} = CB.acquire(@name)

      :ok = GenServer.call(CB, {:close, @name})
      assert counter() == 0
      assert {:ok, 0} = CB.acquire(@name)
    end

    test "a trip at the largest counter wraps it to 0" do
      ref = :persistent_term.get({CB, @name})
      :ok = :atomics.put(ref, 1, @max_counter <<< 2)

      trip!()
      assert counter() == 0
    end

    test "a full cycle across the wrap works, and stale releases are still ignored" do
      ref = :persistent_term.get({CB, @name})
      :ok = :atomics.put(ref, 1, @max_counter <<< 2)

      {:ok, old_counter} = CB.acquire(@name)
      assert old_counter == @max_counter

      trip!()
      wait_for(:half_open)
      {task, runner} = start_blocking_call(:ok)

      CB.release(@name, :success, old_counter)
      sync()
      assert CB.status(@name) == :probing

      send(runner, :go)
      assert Task.await(task) == :ok
      sync()
      assert CB.status(@name) == :closed
    end

    test "a probe claimed at the largest counter can still close the breaker" do
      ref = :persistent_term.get({CB, @name})
      :ok = :atomics.put(ref, 1, @max_counter <<< 2 ||| 2)
      assert CB.status(@name) == :half_open

      assert CB.run(@name, fn -> :ok end) == :ok
      sync()
      assert CB.status(@name) == :closed
    end
  end
end
