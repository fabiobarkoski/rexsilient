defmodule Rexsilient.Retry.Strategy do
  @moduledoc """
  Decides how long a retry waits before the next attempt, or whether it
  stops.

  A strategy is set with `strategy` when a retry is declared:

      strategy Rexsilient.Retry.Strategy.Constant, delay: 500

  `init/1` receives the options and returns the state. Each `run` starts from
  that state: the first `delay/2` call gets it, and returns the delay and the
  new state, which is passed to the next call of the same run. A run happens
  entirely in one process, so the state can be a plain value.

  `delay/2` is only called after a failed attempt that is not the last one:
  `attempts` is enforced by the core, so a strategy does not need to count
  them. Return `:stop` to give up earlier, for example after a time budget or
  on a specific error.

  Built-in strategies: `Rexsilient.Retry.Strategy.Constant`,
  `Rexsilient.Retry.Strategy.Exponential` and
  `Rexsilient.Retry.Strategy.Decorrelated`.

  ## Example

      defmodule MyStrategy do
        @behaviour Rexsilient.Retry.Strategy

        @impl true
        def init(_opts), do: 100

        @impl true
        def delay(_context, delay), do: {:retry, delay, delay * 2}
      end

  Within a run, it waits 100, 200, 400, and so on. Every run starts again from
  the `100` returned by `init/1`.
  """
  alias Rexsilient.Classify

  @typedoc "The value returned by `init/1`, then by each `delay/2`."
  @type state :: term()

  @typedoc """
  What `delay/2` knows about the attempt that just failed:

    * `:attempt` - its number, starting at `1`.

    * `:outcome` - what it returned, raised, threw or exited with.

  More keys may be added, so match only on the ones needed.
  """
  @type context :: %{
          attempt: pos_integer(),
          outcome: Classify.outcome()
        }

  @doc """
  Validates `opts` and returns the initial state.

  Called when the retry is registered. Raise `ArgumentError` for invalid
  options, as `Rexsilient.Options.validate!/2` does; the error is raised
  again with the retry's name.
  """
  @callback init(opts :: keyword()) :: state()

  @doc """
  Returns `{:retry, delay, state}` to wait `delay` milliseconds and try
  again, or `:stop` to give up and return the last outcome.
  """
  @callback delay(context :: context(), state :: state()) ::
              {:retry, delay :: non_neg_integer(), state :: state()} | :stop
end
