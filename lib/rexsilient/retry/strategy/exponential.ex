defmodule Rexsilient.Retry.Strategy.Exponential do
  @moduledoc """
  Doubles the wait after every attempt, up to a maximum.

  The wait after attempt `n` is `base_delay * 2 ** (n - 1)`, capped at
  `max_delay`: with a `base_delay` of `100`, it waits 100, 200, 400, ...

  ## Options

    * `:base_delay` - the wait, in milliseconds, after the first attempt.
      Required.

    * `:max_delay` - the longest wait, in milliseconds. Required.

    * `:jitter` - how the wait is randomized, so that callers failing at the
      same time do not retry at the same time. `:none` (the default) uses
      the exact wait, `:full` a random one from `0` to it (see
      `Rexsilient.Jitter.full/3`), and `:equal` a random one from half of it
      to it (see `Rexsilient.Jitter.equal/3`).

  ## Examples

      strategy Rexsilient.Retry.Strategy.Exponential,
        base_delay: 100,
        max_delay: 5_000,
        jitter: :full

  """
  @behaviour Rexsilient.Retry.Strategy

  alias Rexsilient.Jitter

  @jitters [:none, :full, :equal]

  @impl true
  def init(opts) do
    {jitter, opts} =
      if Keyword.keyword?(opts), do: Keyword.pop(opts, :jitter, :none), else: {:none, opts}

    state =
      Rexsilient.Utils.validate!(opts,
        base_delay: :non_neg_integer,
        max_delay: :non_neg_integer
      )

    if jitter not in @jitters,
      do:
        raise(
          ArgumentError,
          "jitter must be one of #{inspect(@jitters)}, got: #{inspect(jitter)}"
        )

    if state.max_delay < state.base_delay,
      do: raise(ArgumentError, "max_delay must not be less than base_delay")

    Map.put(state, :jitter, jitter)
  end

  @impl true
  def delay(%{attempt: attempt}, state) do
    %{base_delay: base, max_delay: max, jitter: jitter} = state

    delay =
      case jitter do
        :none -> min(base * 2 ** (attempt - 1), max)
        :full -> Jitter.full(base, max, attempt - 1)
        :equal -> Jitter.equal(base, max, attempt - 1)
      end

    {:retry, delay, state}
  end
end
