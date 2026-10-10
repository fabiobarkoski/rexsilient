defmodule Rexsilient.CircuitBreaker.Recover.BasicTimeout do
  @moduledoc """
  Keeps the breaker open, and gives a probe, a fixed time.

  ## Options

    * `:reset_timeout` - how long, in milliseconds, the breaker stays open
      before it lets a probe call through. Required.

    * `:probing_timeout` - how long, in milliseconds, a probe may run before
      the breaker becomes half-open again and lets another probe through.
      Required.

  ## Examples

      recover Rexsilient.CircuitBreaker.Recover.BasicTimeout,
        reset_timeout: :timer.seconds(30),
        probing_timeout: :timer.seconds(10)

  """
  @behaviour Rexsilient.CircuitBreaker.Recover

  @impl true
  def init(opts) do
    Rexsilient.Options.validate!(opts,
      reset_timeout: :non_neg_integer,
      probing_timeout: :non_neg_integer
    )
  end

  @impl true
  def timeout({_from, :probing}, %{probing_timeout: timeout} = state), do: {timeout, state}
  def timeout({_from, :open}, %{reset_timeout: timeout} = state), do: {timeout, state}
end
