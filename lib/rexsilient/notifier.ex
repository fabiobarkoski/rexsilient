defmodule Rexsilient.Notifier do
  @moduledoc ~S"""
  Tells notifiers what the patterns are doing.

  A notifier is a module that implements this behaviour, listed in the
  `:notifiers` option of `Rexsilient`:

      defmodule MyApp.Notifier do
        @behaviour Rexsilient.Notifier

        require Logger

        @impl true
        def notify(:after, :retry, %{result: :failure} = state) do
          Logger.warning("retry #{inspect(state.name)}: attempt #{state.attempt} failed")
        end

        def notify(_moment, _kind, _state), do: :ok
      end

      children = [
        {Rexsilient, modules: [MyApp.Resilience], notifiers: [MyApp.Notifier]}
      ]

  Every notifier gets every notification; match on `kind` and the `:name` in
  `state` to keep only the ones needed. Without notifiers, nothing is sent.

  ## Moments

  `kind` is the pattern, and `state` a map that always has its `:name`.

  Every `:before` also has `:monotonic_time` and `:system_time`, and every
  `:after` has `:monotonic_time` and the `:duration` since its `:before`, all
  in native time units, measured in the calling process.

  `:circuit_breaker`, around calls made with `Rexsilient.CircuitBreaker.run/3`:

    * `:before` - an allowed call is about to run.

    * `:after` - it finished, with its `:result` and `:outcome`.

    * `:rejected` - the breaker rejected the call, with its `:system_time`.

  `:circuit_breaker`, when the breaker changes state, with the state it was
  in as `:from`, and the `:system_time` at which the change was notified:

    * `:open` - it opened, with the `:timeout` before it becomes half-open,
      and the `:outcome` that opened it. When forced with
      `Rexsilient.CircuitBreaker.force_open/1`, `:timeout` is `:infinity`
      and `:outcome` is `nil`.

    * `:half_open` - it lets the next call through as a probe.

    * `:probing` - a probe started, with the `:timeout` before another one
      is let through.

    * `:closed` - a probe succeeded, or it was forced closed.

  A change made with `Rexsilient.CircuitBreaker.force_open/1` or
  `Rexsilient.CircuitBreaker.force_close/1` also has `forced: true`.

  `:retry`:

    * `:before` - an attempt is about to run, with its `:attempt` number.

    * `:after` - it finished, with its `:attempt`, `:result` and `:outcome`.

    * `:delay` - it failed and the next attempt waits `:delay` milliseconds,
      with its `:attempt` and `:outcome`.

    * `:stop` - it failed and no attempt follows, with its `:attempt`,
      `:outcome`, the `:duration` of the whole run, and the `:reason`:
      `:attempts` when none remain, `:strategy` when the strategy stopped.

  `:fallback`, only when the fallback function is called:

    * `:before` - it is about to run, with the `:outcome` it replaces.

    * `:after` - it returned, with its `:outcome`.

  `:result` is `:success` or `:failure`, as classified, and `:outcome` is a
  `t:Rexsilient.Classify.outcome/0`. More moments and keys may be added, so
  end with a catch-all clause.

  State changes are notified from both the calling processes and the breaker
  manager, so they may arrive out of order; use `:system_time` to order them.

  ## Process

  Notifications are sent to a single notifier process, started by
  `Rexsilient`. The call being notified does not wait for it, so `:before`
  is handled after the call has started.

  For each notification, every notifier is called in its own task, and the
  next notification waits for all of them, so each notifier sees them in the
  order the notifier process received them. A notifier that raises or exits
  only crashes its own task, which logs the error; one that takes longer than
  5 seconds is killed. Either way it is skipped for that notification, and
  the others are not affected.

  `Rexsilient.Notifier.TelemetryNotifier`, the default, is the exception: it
  is called in the calling process, like any `:telemetry` event, so its
  handlers see the caller's context. Notifications sent by the breaker
  manager still go through the notifier process, so the manager never runs
  handlers.
  """

  use GenServer

  alias Rexsilient.Notifier.TelemetryNotifier

  @timeout 5_000

  @typedoc "When the notification is sent; see [Moments](#module-moments)."
  @type moment ::
          :before
          | :after
          | :rejected
          | :open
          | :half_open
          | :probing
          | :closed
          | :delay
          | :stop

  @typedoc "The pattern that sends it."
  @type kind :: :circuit_breaker | :fallback | :retry

  @doc """
  Called, in a task, for every notification; see [Process](#module-process).

  The return value is ignored.
  """
  @callback notify(moment(), kind(), state :: map()) :: term()

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  def notify(moment, kind, state) do
    notifiers = fetch_notifiers()
    if TelemetryNotifier in notifiers, do: TelemetryNotifier.notify(moment, kind, state)
    cast(List.delete(notifiers, TelemetryNotifier), moment, kind, state)
  end

  @doc false
  def notify_from_manager(moment, kind, state) do
    cast(fetch_notifiers(), moment, kind, state)
  end

  @doc false
  def notify_start(kind, state) do
    start = System.monotonic_time()

    notify(
      :before,
      kind,
      Map.merge(state, %{monotonic_time: start, system_time: System.system_time()})
    )

    start
  end

  @doc false
  def notify_stop(kind, start, state) do
    stop = System.monotonic_time()
    notify(:after, kind, Map.merge(state, %{monotonic_time: stop, duration: stop - start}))
  end

  defp fetch_notifiers, do: :persistent_term.get({__MODULE__, :notifiers}, [])

  defp cast([], _moment, _kind, _state), do: :ok

  defp cast(notifiers, moment, kind, state) do
    GenServer.cast(__MODULE__, {:notify, notifiers, moment, kind, state})
  end

  @impl true
  def init(opts) do
    notifiers = Keyword.fetch!(opts, :notifiers)

    for notifier <- notifiers do
      :ok = Rexsilient.Options.implements!(notifier, __MODULE__, "notifier")
    end

    :persistent_term.put({__MODULE__, :notifiers}, notifiers)
    {:ok, nil}
  end

  @impl true
  def handle_cast({:notify, notifiers, moment, kind, state}, server_state) do
    __MODULE__.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      notifiers,
      & &1.notify(moment, kind, state),
      timeout: @timeout,
      on_timeout: :kill_task
    )
    |> Stream.run()

    {:noreply, server_state}
  end
end
