defmodule Rexsilient.Notifier.TelemetryNotifier do
  @moduledoc ~S"""
  The default notifier: emits every notification as a `:telemetry` event.

  The event name is `[:rexsilient, kind, moment]`, following the
  `:telemetry.span/3` conventions: `:before` is emitted as `:start` and
  `:after` as `:stop`. The retry `:stop` moment is emitted as `:give_up`, so
  it does not clash with the retry's `:stop`.

  The numeric keys of the notification's state, `:monotonic_time`,
  `:system_time`, `:duration`, `:delay` and `:timeout`, are the measurements;
  every other key is metadata. A `:timeout` of `:infinity` stays in the
  metadata. See `Rexsilient.Notifier` for the keys of each moment.

      :telemetry.attach(
        "log-open-breakers",
        [:rexsilient, :circuit_breaker, :open],
        fn _event, _measurements, %{name: name, from: from}, _config ->
          Logger.warning("breaker #{inspect(name)} opened from #{from}")
        end,
        nil
      )

  Unlike other notifiers, it runs in the calling process, so handlers must be
  fast; see [Process](`m:Rexsilient.Notifier#module-process`).
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
