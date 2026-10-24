defmodule Rexsilient.NotifierTest.Recorder do
  # Runs in a task, so it sends to the test process by its registered name.
  @behaviour Rexsilient.Notifier

  @impl true
  def notify(moment, kind, state),
    do: send(Rexsilient.NotifierTest, {:notify, moment, kind, state})
end

defmodule Rexsilient.NotifierTest.Raiser do
  @behaviour Rexsilient.Notifier

  @impl true
  def notify(_moment, _kind, _state), do: raise("notifier boom")
end

defmodule Rexsilient.NotifierTest.Stopper do
  @behaviour Rexsilient.Retry.Strategy

  @impl true
  def init(_opts), do: nil

  @impl true
  def delay(_context, _state), do: :stop
end

defmodule Rexsilient.NotifierTest.Resilience do
  use Rexsilient

  alias Rexsilient.CircuitBreaker

  circuit_breaker :nt_breaker do
    strategy(CircuitBreaker.Strategy.Count, threshold: 1)
    recover(CircuitBreaker.Recover.BasicTimeout, reset_timeout: 50, probing_timeout: 5_000)
  end

  retry :nt_retry do
    attempts(3)
    strategy(Rexsilient.Retry.Strategy.Constant, delay: 0)
  end

  retry :nt_stop do
    attempts(3)
    strategy(Rexsilient.NotifierTest.Stopper, [])
  end

  fallback :nt_fallback do
    function(:cached)
  end

  def cached(_sku), do: :cached
end

defmodule Rexsilient.NotifierTest do
  # Notifiers live in :persistent_term, and the processes are registered by name.
  use ExUnit.Case, async: false

  alias Rexsilient.{CircuitBreaker, Fallback, Notifier, Retry}
  alias Rexsilient.Notifier.TelemetryNotifier
  alias Rexsilient.NotifierTest.{Raiser, Recorder, Resilience}

  defp start!(notifiers) do
    start_supervised!({Rexsilient, modules: [Resilience], notifiers: notifiers})
  end

  defp moments(kind, count) do
    for _ <- 1..count do
      assert_receive {:notify, moment, ^kind, _state}
      moment
    end
  end

  def handle_event(event, measurements, metadata, test_pid),
    do: send(test_pid, {:telemetry, event, measurements, metadata, self()})

  defp attach!(events) do
    id = make_ref()
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "notifiers" do
    setup do
      Process.register(self(), __MODULE__)
      :ok
    end

    test "retry notifies every attempt, its delay, and the stop" do
      start!([Recorder])

      assert {:error, :down} = Retry.run(:nt_retry, fn -> {:error, :down} end)

      assert moments(:retry, 9) ==
               [:before, :after, :delay, :before, :after, :delay, :before, :after, :stop]

      refute_receive {:notify, _, :retry, _}
    end

    test "retry states carry the attempt, result, outcome and timings" do
      start!([Recorder])

      Retry.run(:nt_retry, fn -> {:error, :down} end)

      assert_receive {:notify, :before, :retry,
                      %{name: :nt_retry, attempt: 1, monotonic_time: _, system_time: _}}

      assert_receive {:notify, :after, :retry,
                      %{
                        name: :nt_retry,
                        attempt: 1,
                        result: :failure,
                        outcome: {:value, {:error, :down}},
                        duration: duration
                      }}

      assert duration >= 0
      assert_receive {:notify, :delay, :retry, %{attempt: 1, delay: 0}}

      assert_receive {:notify, :stop, :retry,
                      %{attempt: 3, reason: :attempts, outcome: {:value, {:error, :down}}}}
    end

    test "retry stop says when the strategy stopped" do
      start!([Recorder])

      Retry.run(:nt_stop, fn -> {:error, :down} end)

      assert_receive {:notify, :stop, :retry, %{name: :nt_stop, attempt: 1, reason: :strategy}}
      refute_receive {:notify, :delay, :retry, _}
    end

    test "a successful retry sends no stop" do
      start!([Recorder])

      assert :ok = Retry.run(:nt_retry, fn -> :ok end)

      assert_receive {:notify, :before, :retry, %{attempt: 1}}
      assert_receive {:notify, :after, :retry, %{result: :success, outcome: {:value, :ok}}}
      refute_receive {:notify, _, :retry, _}
    end

    test "fallback notifies around the fallback function" do
      start!([Recorder])

      assert :cached = Fallback.run(:nt_fallback, fn _sku -> {:error, :down} end, :sku)

      assert_receive {:notify, :before, :fallback,
                      %{name: :nt_fallback, outcome: {:value, {:error, :down}}}}

      assert_receive {:notify, :after, :fallback,
                      %{name: :nt_fallback, outcome: {:value, :cached}, duration: _}}
    end

    test "fallback sends nothing when the call succeeds" do
      start!([Recorder])

      assert :ok = Fallback.run(:nt_fallback, fn _sku -> :ok end, :sku)

      refute_receive {:notify, _, :fallback, _}
    end

    test "circuit breaker notifies calls and every state change" do
      start!([Recorder])

      assert {:error, :down} = CircuitBreaker.run(:nt_breaker, fn -> {:error, :down} end)

      assert_receive {:notify, :before, :circuit_breaker,
                      %{name: :nt_breaker, monotonic_time: _, system_time: _}}

      assert_receive {:notify, :after, :circuit_breaker,
                      %{result: :failure, outcome: {:value, {:error, :down}}, duration: _}}

      assert_receive {:notify, :open, :circuit_breaker,
                      %{
                        name: :nt_breaker,
                        from: :closed,
                        timeout: 50,
                        outcome: {:value, {:error, :down}},
                        system_time: _
                      } = opened}

      refute Map.has_key?(opened, :forced)

      assert {:error, :circuit_open} = CircuitBreaker.run(:nt_breaker, fn -> :ok end)
      assert_receive {:notify, :rejected, :circuit_breaker, %{name: :nt_breaker, system_time: _}}

      assert_receive {:notify, :half_open, :circuit_breaker, %{from: :open}}, 500

      assert :ok = CircuitBreaker.run(:nt_breaker, fn -> :ok end)
      assert_receive {:notify, :probing, :circuit_breaker, %{from: :half_open, timeout: 5_000}}
      assert_receive {:notify, :after, :circuit_breaker, %{result: :success}}
      assert_receive {:notify, :closed, :circuit_breaker, %{from: :probing}}
    end

    test "forcing the breaker notifies the change" do
      start!([Recorder])

      CircuitBreaker.force_open(:nt_breaker)

      assert_receive {:notify, :open, :circuit_breaker,
                      %{from: :closed, timeout: :infinity, outcome: nil, forced: true}}

      CircuitBreaker.force_close(:nt_breaker)
      assert_receive {:notify, :closed, :circuit_breaker, %{from: :open, forced: true}}
    end

    @tag :capture_log
    test "a raising notifier does not stop the others" do
      start!([Raiser, Recorder])

      Retry.run(:nt_retry, fn -> :ok end)

      assert moments(:retry, 2) == [:before, :after]
      assert Process.alive?(Process.whereis(Notifier))
    end

    test "a module that is not a notifier is rejected" do
      assert_raise ArgumentError,
                   "notifier: String does not implement Rexsilient.Notifier (missing notify/3)",
                   fn -> Notifier.init(notifiers: [String]) end

      assert_raise ArgumentError,
                   "notifier: module Rexsilient.NotifierTest.Missing is not available",
                   fn -> Notifier.init(notifiers: [Rexsilient.NotifierTest.Missing]) end
    end
  end

  describe "telemetry" do
    test "is the default notifier" do
      start_supervised!({Rexsilient, modules: [Resilience]})
      attach!([[:rexsilient, :retry, :start]])

      Retry.run(:nt_retry, fn -> :ok end)

      assert_receive {:telemetry, [:rexsilient, :retry, :start], _, _, _}
    end

    test "emits span events in the calling process" do
      start!([TelemetryNotifier])
      test_pid = self()

      attach!([
        [:rexsilient, :retry, :start],
        [:rexsilient, :retry, :stop],
        [:rexsilient, :retry, :delay],
        [:rexsilient, :retry, :give_up]
      ])

      Retry.run(:nt_retry, fn -> {:error, :down} end)

      assert_receive {:telemetry, [:rexsilient, :retry, :start],
                      %{monotonic_time: _, system_time: _} = measurements,
                      %{name: :nt_retry, attempt: 1} = metadata, ^test_pid}

      assert map_size(measurements) == 2
      refute Map.has_key?(metadata, :monotonic_time)

      assert_receive {:telemetry, [:rexsilient, :retry, :stop], %{duration: _},
                      %{attempt: 1, result: :failure, outcome: {:value, {:error, :down}}},
                      ^test_pid}

      assert_receive {:telemetry, [:rexsilient, :retry, :delay], %{delay: 0}, %{attempt: 1},
                      ^test_pid}

      assert_receive {:telemetry, [:rexsilient, :retry, :give_up], %{duration: _},
                      %{attempt: 3, reason: :attempts}, ^test_pid}
    end

    test "state changes from the manager are emitted outside it" do
      start!([TelemetryNotifier])
      attach!([[:rexsilient, :circuit_breaker, :open]])

      CircuitBreaker.run(:nt_breaker, fn -> {:error, :down} end)

      assert_receive {:telemetry, [:rexsilient, :circuit_breaker, :open],
                      %{timeout: 50, system_time: _}, %{name: :nt_breaker, from: :closed},
                      handler_pid}

      refute handler_pid == self()
      refute handler_pid == Process.whereis(CircuitBreaker)
    end

    test "a forced open keeps :infinity in the metadata" do
      start!([TelemetryNotifier])
      attach!([[:rexsilient, :circuit_breaker, :open]])

      CircuitBreaker.force_open(:nt_breaker)

      assert_receive {:telemetry, [:rexsilient, :circuit_breaker, :open], measurements,
                      %{timeout: :infinity, forced: true}, _}

      refute Map.has_key?(measurements, :timeout)
      CircuitBreaker.force_close(:nt_breaker)
    end

    test "is not emitted without it in the notifiers" do
      start!([])
      attach!([[:rexsilient, :retry, :start]])

      Retry.run(:nt_retry, fn -> :ok end)

      refute_receive {:telemetry, _, _, _, _}
    end
  end
end
