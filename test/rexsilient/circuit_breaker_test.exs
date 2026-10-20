defmodule Rexsilient.CircuitBreakerTest.Breakers do
  use Rexsilient
  alias Rexsilient.CircuitBreaker

  circuit_breaker :cb_test do
    strategy(CircuitBreaker.Strategy.Count, threshold: 3)
    recover(CircuitBreaker.Recover.BasicTimeout, reset_timeout: 50, probing_timeout: 5_000)
  end
end

defmodule Rexsilient.CircuitBreakerTest.CustomFailureBreakers do
  use Rexsilient
  alias Rexsilient.CircuitBreaker

  circuit_breaker :cb_custom_failure do
    strategy(CircuitBreaker.Strategy.Count, threshold: 3)
    recover(CircuitBreaker.Recover.BasicTimeout, reset_timeout: 50, probing_timeout: 5_000)
  end

  def classify(:boom), do: :failure
  def classify(_), do: :success
end

defmodule Rexsilient.CircuitBreakerTest.CustomExceptionBreakers do
  use Rexsilient
  alias Rexsilient.CircuitBreaker

  circuit_breaker :cb_custom_exception do
    strategy(CircuitBreaker.Strategy.Count, threshold: 3)
    recover(CircuitBreaker.Recover.BasicTimeout, reset_timeout: 50, probing_timeout: 5_000)
  end

  def classify(:throw, :ignored), do: :success
  def classify(kind, reason), do: super(kind, reason)
end

# Redeclares :cb_test with other settings, to restart the manager with them.
defmodule Rexsilient.CircuitBreakerTest.ReconfiguredBreakers do
  use Rexsilient
  alias Rexsilient.CircuitBreaker

  circuit_breaker :cb_test do
    strategy(CircuitBreaker.Strategy.Count, threshold: 5)
    recover(CircuitBreaker.Recover.BasicTimeout, reset_timeout: 50, probing_timeout: 5_000)
  end

  def classify(:boom), do: :failure
  def classify(_), do: :success
end

defmodule Rexsilient.CircuitBreakerTest.SlidingWindowBreakers do
  use Rexsilient
  alias Rexsilient.CircuitBreaker

  circuit_breaker :cb_test do
    strategy(CircuitBreaker.Strategy.SlidingWindow, threshold: 2, window: 1_000)
    recover(CircuitBreaker.Recover.BasicTimeout, reset_timeout: 50, probing_timeout: 5_000)
  end
end

# Redeclares :cb_test with a short probing timeout. Threshold 1, so a single
# failure that is not ignored would open the breaker.
defmodule Rexsilient.CircuitBreakerTest.ShortProbingBreakers do
  use Rexsilient
  alias Rexsilient.CircuitBreaker

  circuit_breaker :cb_test do
    strategy(CircuitBreaker.Strategy.Count, threshold: 1)
    recover(CircuitBreaker.Recover.BasicTimeout, reset_timeout: 50, probing_timeout: 150)
  end
end

defmodule Rexsilient.CircuitBreakerTest.InvalidOptionsBreakers do
  use Rexsilient
  alias Rexsilient.CircuitBreaker

  circuit_breaker :cb_invalid do
    strategy(CircuitBreaker.Strategy.Count, threshold: 0)
    recover(CircuitBreaker.Recover.BasicTimeout, reset_timeout: 50, probing_timeout: 50)
  end
end

defmodule Rexsilient.CircuitBreakerTest.WrongStrategyBreakers do
  use Rexsilient
  alias Rexsilient.CircuitBreaker

  # A retry strategy: init/1 accepts the options, but record/3 and reset/1
  # are missing.
  circuit_breaker :cb_wrong_strategy do
    strategy(Rexsilient.Retry.Strategy.Constant, delay: 0)
    recover(CircuitBreaker.Recover.BasicTimeout, reset_timeout: 50, probing_timeout: 50)
  end
end

defmodule Rexsilient.CircuitBreakerTest.UnavailableRecoverBreakers do
  use Rexsilient
  alias Rexsilient.CircuitBreaker

  circuit_breaker :cb_unavailable_recover do
    strategy(CircuitBreaker.Strategy.Count, threshold: 1)
    recover(Rexsilient.CircuitBreakerTest.Nope, [])
  end
end

defmodule Rexsilient.CircuitBreakerTest do
  # The manager is a named singleton and breakers live in :persistent_term, so
  # these tests cannot run concurrently with each other.
  use ExUnit.Case, async: false

  import Bitwise

  alias Rexsilient.CircuitBreaker, as: CB

  alias Rexsilient.CircuitBreakerTest.{
    Breakers,
    CustomExceptionBreakers,
    CustomFailureBreakers,
    ReconfiguredBreakers,
    ShortProbingBreakers,
    SlidingWindowBreakers
  }

  @name :cb_test
  @timeout 50
  @threshold 3

  # Every start reinstalls the breaker, and install resets an existing one to
  # closed, so each test starts from a fresh closed breaker.
  setup do
    start_supervised!({CB, modules: [Breakers, CustomFailureBreakers, CustomExceptionBreakers]})
    :ok
  end

  defp restart(modules) do
    :ok = stop_supervised(CB)
    start_supervised!({CB, modules: modules})
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
    %{ref: ref} = :persistent_term.get({CB, @name})
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

      assert CB.run(@name, fn -> :ok end, on_open: {:error, :unavailable}) ==
               {:error, :unavailable}
    end

    test "an unknown breaker raises" do
      for fun <- [
            fn -> CB.run(:nope, fn -> :ok end) end,
            fn -> CB.acquire(:nope) end,
            fn -> CB.release(:nope, :success, 0) end,
            fn -> CB.status(:nope) end
          ] do
        assert_raise ArgumentError, "unknown circuit breaker :nope", fun
      end
    end
  end

  describe "registration" do
    # Calls init/1 directly: under start_supervised the error would be wrapped
    # in the start failure.
    test "invalid options name the breaker and the module" do
      assert_raise ArgumentError,
                   "circuit breaker :cb_invalid: invalid strategy options for " <>
                     "Rexsilient.CircuitBreaker.Strategy.Count: " <>
                     "threshold must be a positive integer, got: 0",
                   fn ->
                     CB.init(modules: [Rexsilient.CircuitBreakerTest.InvalidOptionsBreakers])
                   end
    end

    test "a module of another behaviour names the breaker and the missing callbacks" do
      err =
        assert_raise ArgumentError, fn ->
          CB.init(modules: [Rexsilient.CircuitBreakerTest.WrongStrategyBreakers])
        end

      message = Exception.message(err)

      assert message =~
               "circuit breaker :cb_wrong_strategy: Rexsilient.Retry.Strategy.Constant " <>
                 "does not implement Rexsilient.CircuitBreaker.Strategy"

      assert message =~ "record/3"
      assert message =~ "reset/1"
    end

    test "a module that is not available names the breaker" do
      assert_raise ArgumentError,
                   "circuit breaker :cb_unavailable_recover: " <>
                     "module Rexsilient.CircuitBreakerTest.Nope is not available",
                   fn ->
                     CB.init(modules: [Rexsilient.CircuitBreakerTest.UnavailableRecoverBreakers])
                   end
    end

    test "a duplicated name raises" do
      assert_raise ArgumentError, "circuit breaker :cb_test already exists", fn ->
        CB.init(modules: [Breakers, ReconfiguredBreakers])
      end
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

    test "an overridden classify/1 decides what counts as a failure" do
      for value <- [:error, {:error, :a}, {:error, :b}, :ok] do
        CB.run(:cb_custom_failure, fn -> value end)
      end

      sync()
      assert CB.status(:cb_custom_failure) == :closed

      for _ <- 1..@threshold, do: CB.run(:cb_custom_failure, fn -> :boom end)
      sync()
      assert CB.status(:cb_custom_failure) == :open
    end

    test "overriding classify/1 keeps the default classify/2" do
      for _ <- 1..@threshold do
        assert_raise RuntimeError, fn -> CB.run(:cb_custom_failure, fn -> raise "boom" end) end
      end

      sync()
      assert CB.status(:cb_custom_failure) == :open
    end

    test "an overridden classify/2 decides how exceptions count, and they are still re-raised" do
      for _ <- 1..@threshold do
        assert catch_throw(CB.run(:cb_custom_exception, fn -> throw(:ignored) end)) == :ignored
      end

      sync()
      assert CB.status(:cb_custom_exception) == :closed

      for _ <- 1..@threshold do
        assert catch_throw(CB.run(:cb_custom_exception, fn -> throw(:other) end)) == :other
      end

      sync()
      assert CB.status(:cb_custom_exception) == :open
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

  describe "probing timeout" do
    @probing_timeout 150

    setup do
      restart([ShortProbingBreakers])
      :ok
    end

    test "a probe running past probing_timeout makes the breaker half-open again" do
      trip!()
      wait_for(:half_open)
      {task, runner} = start_blocking_call(:ok)

      # Still probing after reset_timeout: the probing timer uses probing_timeout.
      Process.sleep(@timeout * 2)
      assert CB.status(@name) == :probing

      wait_for(:half_open)
      assert CB.run(@name, fn -> :ok end) == :ok
      sync()
      assert CB.status(@name) == :closed

      send(runner, :go)
      assert Task.await(task) == :ok
    end

    test "a late failure from a timed-out probe is ignored" do
      trip!()
      wait_for(:half_open)
      {task, runner} = start_blocking_call({:error, :late})

      wait_for(:half_open)
      assert CB.run(@name, fn -> :ok end) == :ok
      sync()

      send(runner, :go)
      assert Task.await(task) == {:error, :late}
      sync()
      assert CB.status(@name) == :closed
    end

    test "a late success from a timed-out probe does not close a re-opened breaker" do
      trip!()
      wait_for(:half_open)
      {task, runner} = start_blocking_call(:ok)

      wait_for(:half_open)
      CB.run(@name, fn -> {:error, :still_down} end)
      sync()
      assert CB.status(@name) == :open

      send(runner, :go)
      assert Task.await(task) == :ok
      sync()
      # May already be half-open again after reset_timeout; it must not be closed.
      refute CB.status(@name) == :closed
    end

    test "a probe that finishes in time leaves its timer with nothing to do" do
      trip!()
      wait_for(:half_open)

      assert CB.run(@name, fn -> :ok end) == :ok
      sync()
      assert CB.status(@name) == :closed

      Process.sleep(@probing_timeout * 2)
      assert CB.status(@name) == :closed
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
      :ok = CB.force_close(@name)

      for _ <- 1..@threshold, do: CB.release(@name, :failure, old_counter)
      sync()
      assert CB.status(@name) == :closed
    end

    test "a half-open timer armed before a close is ignored" do
      trip!()
      :ok = CB.force_close(@name)

      Process.sleep(@timeout * 2)
      assert CB.status(@name) == :closed
    end
  end

  describe "admin" do
    test "force_open/1 opens the breaker with no timer" do
      :ok = CB.force_open(@name)

      Process.sleep(@timeout * 2)
      assert CB.status(@name) == :open
    end

    test "force_close/1 closes an open breaker" do
      trip!()
      :ok = CB.force_close(@name)
      assert CB.status(@name) == :closed
    end

    test "force_close/1 closes a breaker forced open" do
      :ok = CB.force_open(@name)
      :ok = CB.force_close(@name)
      assert CB.status(@name) == :closed
    end

    test "an unknown name raises and does not crash the manager" do
      pid = Process.whereis(CB)

      assert_raise ArgumentError, "unknown circuit breaker :nope", fn -> CB.force_open(:nope) end
      assert_raise ArgumentError, "unknown circuit breaker :nope", fn -> CB.force_close(:nope) end
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

    test "new strategy options are used after a restart" do
      restart([ReconfiguredBreakers])

      for _ <- 1..@threshold, do: CB.run(@name, fn -> :boom end)
      sync()
      assert CB.status(@name) == :closed

      for _ <- 1..2, do: CB.run(@name, fn -> :boom end)
      sync()
      assert CB.status(@name) == :open
    end

    test "the new module's classify/1 is used after a restart" do
      restart([ReconfiguredBreakers])

      for _ <- 1..5, do: CB.run(@name, fn -> {:error, :boom} end)
      sync()
      assert CB.status(@name) == :closed
    end

    test "the strategy module can change across a restart" do
      restart([SlidingWindowBreakers])

      for _ <- 1..2, do: CB.run(@name, fn -> :error end)
      sync()
      assert CB.status(@name) == :open
    end

    test "releases acquired before a restart are ignored" do
      {:ok, old_counter} = CB.acquire(@name)
      restart([Breakers, CustomFailureBreakers])

      for _ <- 1..@threshold, do: CB.release(@name, :failure, old_counter)
      sync()
      assert CB.status(@name) == :closed
    end
  end

  describe "state counter wraparound" do
    # Reaches into the atomics layout (slot 1, status in the low 2 bits) to start
    # the breaker at the largest counter; there is no public way to get there.
    @max_counter (1 <<< 61) - 1

    test "the counter goes back to 0 after the largest value" do
      %{ref: ref} = :persistent_term.get({CB, @name})
      :ok = :atomics.put(ref, 1, @max_counter <<< 2)
      assert {:ok, @max_counter} = CB.acquire(@name)

      :ok = CB.force_close(@name)
      assert counter() == 0
      assert {:ok, 0} = CB.acquire(@name)
    end

    test "a trip at the largest counter wraps it to 0" do
      %{ref: ref} = :persistent_term.get({CB, @name})
      :ok = :atomics.put(ref, 1, @max_counter <<< 2)

      trip!()
      assert counter() == 0
    end

    test "a full cycle across the wrap works, and stale releases are still ignored" do
      %{ref: ref} = :persistent_term.get({CB, @name})
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
      %{ref: ref} = :persistent_term.get({CB, @name})
      :ok = :atomics.put(ref, 1, @max_counter <<< 2 ||| 2)
      assert CB.status(@name) == :half_open

      assert CB.run(@name, fn -> :ok end) == :ok
      sync()
      assert CB.status(@name) == :closed
    end
  end
end
