defmodule Rexsilient.Retry.Strategy.Constant do
  @moduledoc """
  Waits the same time before every attempt.

  ## Options

    * `:delay` - how long, in milliseconds, to wait before each attempt.
      Required.

  ## Examples

      strategy Rexsilient.Retry.Strategy.Constant, delay: 500

  """
  @behaviour Rexsilient.Retry.Strategy

  @impl true
  def init(opts) do
    Rexsilient.Utils.validate!(opts, delay: :non_neg_integer)
  end

  @impl true
  def delay(_context, %{delay: delay} = state), do: {:retry, delay, state}
end
