defmodule Rexsilient.CircuitBreaker.Strategy.Count do
  @moduledoc """
  Opens the breaker after a number of failures.

  Failures are counted from the moment the breaker was last closed; successes
  do not reset the count.

  ## Options

    * `:threshold` - the number of failures that opens the breaker. Required.

  ## Examples

      strategy Rexsilient.CircuitBreaker.Strategy.Count, threshold: 5

  """
  @behaviour Rexsilient.CircuitBreaker.Strategy

  @impl true
  def init(opts) do
    %{threshold: threshold} = Rexsilient.Options.validate!(opts, threshold: :pos_integer)
    ref = :atomics.new(1, [])
    :ok = :atomics.put(ref, 1, 0)

    %{ref: ref, threshold: threshold}
  end

  @impl true
  def record(%{ref: ref, threshold: threshold}, result, _duration) do
    if result == :failure and :atomics.add_get(ref, 1, 1) >= threshold do
      :trip
    else
      :ok
    end
  end

  @impl true
  def reset(%{ref: ref}) do
    :ok = :atomics.put(ref, 1, 0)
  end
end
