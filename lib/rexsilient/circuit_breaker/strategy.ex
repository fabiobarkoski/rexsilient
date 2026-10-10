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

  Called while the breaker is closed, and for a successful probe. Return
  `:trip` to open the breaker, `:ok` otherwise. `duration` is reserved and is
  currently always `0`.
  """
  @callback record(
              state :: state(),
              result :: Rexsilient.Failure.result(),
              duration :: non_neg_integer()
            ) :: :ok | :trip

  @doc """
  Forgets the results recorded so far.

  Called when the breaker closes.
  """
  @callback reset(state :: state()) :: :ok
end
