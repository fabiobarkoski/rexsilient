defmodule Rexsilient.CircuitBreaker.Strategy do
  @moduledoc """
  Decides when a closed breaker opens.

  A strategy is set with `strategy` when a breaker is declared:

      strategy Rexsilient.CircuitBreaker.Strategy.Count, threshold: 5

  `init/1` receives the options and returns the state, which is passed
  unchanged to `record/3` and `reset/1` for the life of the breaker.

  Unlike `Rexsilient.CircuitBreaker.Recover`, these callbacks run in the
  processes making the calls, concurrently, so the state cannot be replaced.
  Keep what changes in shared mutable storage created by `init/1`, such as
  `:atomics` or `:counters`.

  Built-in strategies: `Rexsilient.CircuitBreaker.Strategy.Count` and
  `Rexsilient.CircuitBreaker.Strategy.SlidingWindow`.
  """

  @typedoc "The value returned by `init/1`."
  @type state :: term()

  @doc """
  Validates `opts` and returns the strategy's state.

  Called when the breaker is registered. Raise `ArgumentError` for invalid
  options; the error is raised again with the breaker's name.
  """
  @callback init(opts :: keyword()) :: state()

  @doc """
  Records the result of a call.

  Called for every call made while the breaker is closed, successes
  included; probes are not recorded. Return `:trip` to open the breaker,
  `:ok` otherwise.

  `duration` is how long the call took, in `:native` time units, or `nil`
  when it was released with `Rexsilient.CircuitBreaker.release/4` directly.
  To compare it with an option given in milliseconds, convert the option
  once in `init/1` with `System.convert_time_unit(value, :millisecond, :native)`
  instead of converting every duration.
  """
  @callback record(
              state :: state(),
              result :: Rexsilient.Classify.result(),
              duration :: non_neg_integer() | nil
            ) :: :ok | :trip

  @doc """
  Forgets the results recorded so far.

  Called when the breaker closes.
  """
  @callback reset(state :: state()) :: :ok
end
