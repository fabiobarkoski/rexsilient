defmodule Rexsilient.CircuitBreaker.Strategy.SlidingWindow do
  @moduledoc """
  Opens the breaker after a number of failures within a time window.

  Only failures are tracked: the breaker opens when `threshold` failures
  happen within `window` milliseconds of each other. Successes do not affect
  it, and failures older than the window stop counting.

  ## Options

    * `:threshold` - the number of failures that opens the breaker. Required.

      With `1`, the first failure opens the breaker and `:window` has no
      effect, like `Rexsilient.CircuitBreaker.Strategy.Count` with the same
      threshold.

      The breaker keeps the time of the last `threshold - 1` failures, 8 bytes
      each, so memory grows with the threshold.

    * `:window` - the time, in milliseconds, those failures must fit in.
      Required.

  ## Examples

      strategy Rexsilient.CircuitBreaker.Strategy.SlidingWindow,
        threshold: 5,
        window: :timer.seconds(10)

  """
  @behaviour Rexsilient.CircuitBreaker.Strategy

  @impl true
  def init(opts) do
    %{threshold: threshold, window: window} =
      Rexsilient.Utils.validate!(opts, threshold: :pos_integer, window: :pos_integer)

    slots = threshold - 1

    %{
      ref_window: if(slots > 0, do: :atomics.new(slots, [])),
      ref_counter: :atomics.new(1, []),
      slots: slots,
      window: window,
      base_time: System.monotonic_time(:millisecond)
    }
  end

  @impl true
  def record(_state, :success, _duration), do: :ok
  def record(%{slots: 0}, :failure, _duration), do: :trip

  def record(state, :failure, _duration) do
    %{
      ref_window: ref_window,
      base_time: base_time,
      window: window
    } = state

    value = System.monotonic_time(:millisecond) - base_time + 1
    position = get_position(state)
    old_value = :atomics.exchange(ref_window, position, value)

    if value - old_value <= window and old_value != 0 do
      :trip
    else
      :ok
    end
  end

  @impl true
  def reset(%{slots: 0}), do: :ok

  def reset(state) do
    %{
      ref_window: ref,
      ref_counter: ref_counter,
      slots: slots
    } = state

    for idx <- 1..slots do
      :ok = :atomics.put(ref, idx, 0)
    end

    :ok = :atomics.put(ref_counter, 1, 0)
  end

  @spec get_position(state :: term()) :: pos_integer()
  defp get_position(%{ref_counter: ref, slots: slots}) do
    current_position = :atomics.add_get(ref, 1, 1)
    rem(current_position - 1, slots) + 1
  end
end
