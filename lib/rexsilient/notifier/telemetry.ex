defmodule Rexsilient.Notifier.TelemetryNotifier do
  @moduledoc ~S"""
  The default notifier: emits every notification as a `:telemetry` event.

  The event name is `[:rexsilient, kind, moment]`, following the
  `:telemetry.span/3` conventions: `:before` is emitted as `:start` and
  `:after` as `:stop`. The retry `:stop` moment is emitted as `:give_up`, so
  it does not clash with the `:stop` event of each attempt.

  The numeric keys of the notification's state, `:monotonic_time`,
  `:system_time`, `:duration`, `:delay` and `:timeout`, are the measurements;
  every other key is metadata. A `:timeout` of `:infinity` stays in the
  metadata. See `Rexsilient.Notifier` for what each moment means.

  ## Events

  `[:rexsilient, :circuit_breaker, event]`:

  | Event | Measurements | Metadata |
  |:------|:-------------|:---------|
  | `:start` | `monotonic_time`, `system_time` | `name` |
  | `:stop` | `monotonic_time`, `duration` | `name`, `result`, `outcome` |
  | `:rejected` | `system_time` | `name` |
  | `:open` | `system_time`, `timeout` | `name`, `from`, `outcome`, `forced`¹ |
  | `:half_open` | `system_time` | `name`, `from` |
  | `:probing` | `system_time`, `timeout` | `name`, `from`, `outcome` |
  | `:closed` | `system_time` | `name`, `from`, `forced`¹, `restart`¹ |

  ¹ Only present when the change was forced with
  `Rexsilient.CircuitBreaker.force_open/1` or
  `Rexsilient.CircuitBreaker.force_close/1`, or caused by a manager restart.
  A forced `:open` has `timeout: :infinity`, in the metadata.

  `[:rexsilient, :retry, event]`:

  | Event | Measurements | Metadata |
  |:------|:-------------|:---------|
  | `:start` | `monotonic_time`, `system_time` | `name`, `attempt` |
  | `:stop` | `monotonic_time`, `duration` | `name`, `attempt`, `result`, `outcome` |
  | `:delay` | `delay` | `name`, `attempt`, `outcome` |
  | `:give_up` | `duration` | `name`, `attempt`, `outcome`, `reason` |

  `[:rexsilient, :fallback, event]`:

  | Event | Measurements | Metadata |
  |:------|:-------------|:---------|
  | `:start` | `monotonic_time`, `system_time` | `name`, `outcome` (the one replaced) |
  | `:stop` | `monotonic_time`, `duration` | `name`, `outcome` |

  Times and `duration` are in native time units, `delay` and `timeout` in
  milliseconds. `result` is `:success` or `:failure`, and `outcome` is a
  `t:Rexsilient.Classify.outcome/0`.

  ## Example

      :telemetry.attach(
        "log-open-breakers",
        [:rexsilient, :circuit_breaker, :open],
        fn _event, _measurements, %{name: name, from: from}, _config ->
          Logger.warning("breaker #{inspect(name)} opened from #{from}")
        end,
        nil
      )

  > #### Handlers run in the calling process {: .info}
  >
  > Unlike other notifiers, it runs in the calling process, so handlers must be
  > fast; see [Process](`m:Rexsilient.Notifier#module-process`).
  """

  @behaviour Rexsilient.Notifier

  @measurements [:monotonic_time, :system_time, :duration, :delay, :timeout]

  @impl true
  def notify(moment, kind, state) do
    {measurements, metadata} =
      Map.split_with(state, fn {key, value} -> key in @measurements and is_number(value) end)

    :telemetry.execute([:rexsilient, kind, event(kind, moment)], measurements, metadata)
  end

  defp event(_kind, :before), do: :start
  defp event(_kind, :after), do: :stop
  defp event(:retry, :stop), do: :give_up
  defp event(_kind, moment), do: moment
end
