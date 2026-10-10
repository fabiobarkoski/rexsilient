defmodule Rexsilient.CircuitBreaker.Recover do
  @moduledoc """
  Decides how long a breaker waits before it lets a probe call through.

  `timeout/2` is called by the manager with the transition that starts a
  timer:

    * `{:closed, :open}` - the breaker tripped. Returns how long it stays open.

    * `{:probing, :open}` - the probe failed. Returns how long it stays open.

    * `{:half_open, :probing}` - a probe started. Returns how long it may run
      before the breaker becomes half-open again and lets another probe
      through.

  A successful probe closes the breaker without calling `timeout/2`, so the
  next `{:closed, :open}` is the first call after a recovery.

  `init/1` receives the options given to `recover` and returns the state. The
  first `timeout/2` call gets that state; it returns the timeout and the new
  state, which the manager passes to the next call. It is only called from the
  manager, so the state can be a plain value. The state is not kept across
  manager restarts: `init/1` is called again.

  The state can also hold what the transition alone does not tell. For
  example, a `{:half_open, :probing}` right after another one means the
  previous probe timed out.

  Built-in: `Rexsilient.CircuitBreaker.Recover.BasicTimeout`.
  """
  alias Rexsilient.CircuitBreaker

  @typedoc "The value returned by `init/1`, then by each `timeout/2`."
  @type state :: term()

  @typedoc """
  The `{from, to}` change of state that starts a timer; see the module
  documentation for the ones passed.
  """
  @type transition :: {CircuitBreaker.status(), CircuitBreaker.status()}

  @doc """
  Validates `opts` and returns the initial state.

  Called when the breaker is registered, and again when the manager
  restarts. Raise `ArgumentError` for invalid options; the error is raised
  again with the breaker's name.
  """
  @callback init(opts :: keyword()) :: state()

  @doc """
  Returns how long, in milliseconds, to wait after `transition`, and the new
  state.
  """
  @callback timeout(transition :: transition(), state :: state()) ::
              {timeout :: non_neg_integer(), state :: state()}
end
