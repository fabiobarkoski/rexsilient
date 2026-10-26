defmodule Rexsilient.CircuitBreaker.Strategy do
  @moduledoc """
  Decides when a closed breaker opens.

  A strategy is set with `strategy` when a breaker is declared:

      strategy Rexsilient.CircuitBreaker.Strategy.Count, threshold: 5

  `init/1` receives the options and returns the state, which is passed
  unchanged to `record/3` and `reset/1` for the life of the breaker.

  > #### Callbacks run concurrently {: .warning}
  >
  > Unlike `Rexsilient.CircuitBreaker.Recover`, these callbacks run in the
  > processes making the calls, concurrently, so the state cannot be replaced.
  > Keep what changes in shared mutable storage created by `init/1`, `:atomics` or `:counters`,
  > for example.

  Built-in strategies: `Rexsilient.CircuitBreaker.Strategy.Count` and
  `Rexsilient.CircuitBreaker.Strategy.SlidingWindow`.

  ## Example

      defmodule MyStrategy do
        @behaviour Rexsilient.CircuitBreaker.Strategy

        @impl true
        def init(_opts), do: :counters.new(1, [])

        @impl true
        def record(counter, :failure, _duration) do
          :counters.add(counter, 1, 1)
          if :counters.get(counter, 1) >= 3, do: :trip, else: :ok
        end

        def record(_counter, :success, _duration), do: :ok

        @impl true
        def reset(counter), do: :counters.put(counter, 1, 0)
      end

  Every callback gets the same counter returned by `init/1`; only its value
  changes.
  """

  @typedoc "The value returned by `init/1`."
  @type state :: term()

  @doc """
  Validates `opts` and returns the strategy's state.

  Called when the circuit breaker is registered. Raise `ArgumentError` for
  invalid options, as `Rexsilient.Options.validate!/2` does; the error is
  raised again with the circuit breaker's name.
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

  Called just before the breaker closes.
  """
  @callback reset(state :: state()) :: :ok
end
