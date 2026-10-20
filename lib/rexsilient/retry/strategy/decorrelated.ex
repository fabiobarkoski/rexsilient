defmodule Rexsilient.Retry.Strategy.Decorrelated do
  @moduledoc """
  Waits a random time based on the previous wait, up to a maximum.

  Each wait is a random value from `base_delay` to three times the previous
  wait, capped at `max_delay`; see `Rexsilient.Jitter.decorrelated/3`. Waits
  grow on average, like `Rexsilient.Retry.Strategy.Exponential`, but each
  caller's waits drift apart.

  ## Options

    * `:base_delay` - the shortest wait, in milliseconds, and the base of the
      first one. Required.

    * `:max_delay` - the longest wait, in milliseconds. Required.

  ## Examples

      strategy Rexsilient.Retry.Strategy.Decorrelated,
        base_delay: 100,
        max_delay: 5_000

  """
  @behaviour Rexsilient.Retry.Strategy

  alias Rexsilient.Jitter

  @impl true
  def init(opts) do
    state =
      Rexsilient.Options.validate!(opts, base_delay: :pos_integer, max_delay: :pos_integer)

    if state.max_delay < state.base_delay,
      do: raise(ArgumentError, "max_delay must not be less than base_delay")

    Map.put(state, :previous, state.base_delay)
  end

  @impl true
  def delay(_context, state) do
    %{base_delay: base, max_delay: max, previous: previous} = state
    delay = Jitter.decorrelated(base, max, previous)
    {:retry, delay, %{state | previous: delay}}
  end
end
