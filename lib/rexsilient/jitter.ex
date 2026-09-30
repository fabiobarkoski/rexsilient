defmodule Rexsilient.Jitter do
  @moduledoc """
  Randomized delays for retrying failed calls.

  When many callers fail at the same moment and all retry after the same
  delay, they hit the dependency again at the same moment too. Adding
  randomness to the delay, called *jitter*, spreads the retries out so the
  dependency is not flooded when it comes back.

  Each function implements one strategy. They grow the delay exponentially
  with each attempt, starting from `base_delay` and never going above
  `max_delay`. Delays are in whatever unit `base_delay` and `max_delay` use,
  usually milliseconds.
  """

  @doc """
  Returns a random delay between `0` and the exponential backoff for
  `attempt`.

  The backoff is `base_delay * 2 ** attempt`, capped at `max_delay`, and
  `attempt` starts at `0`. This spreads retries the most, but a delay may be
  very short.

  ## Examples

      Rexsilient.Jitter.full(100, 10_000, 3)
      # a random integer from 0 to 800

  """
  def full(base_delay, max_delay, attempt) do
    backoff = min(base_delay * (2 ** attempt), max_delay)
    Enum.random(0..backoff)
  end

  @doc """
  Returns half of the exponential backoff for `attempt`, plus a random amount
  up to the other half.

  The backoff is computed as in `full/3`. Every delay is at least half of it,
  so retries are spread out while never following each other too closely.

  ## Examples

      Rexsilient.Jitter.equal(100, 10_000, 3)
      # a random value from 400 to 800

  """
  def equal(base_delay, max_delay, attempt) do
    backoff = min(base_delay * (2 ** attempt), max_delay)
    div(backoff, 2) + Enum.random(0..round(backoff / 2))
  end

  @doc """
  Returns a random delay between `base_delay` and three times
  `previous_delay`, capped at `max_delay`.

  Unlike `full/3` and `equal/3`, it does not use the attempt number: each
  delay is based on the previous one. Pass `base_delay` as `previous_delay` on
  the first retry.

  ## Examples

      delay = Rexsilient.Jitter.decorrelated(100, 10_000, 100)
      # a random integer from 100 to 300

      Rexsilient.Jitter.decorrelated(100, 10_000, delay)

  """
  def decorrelated(base_delay, max_delay, previous_delay) do
    min(Enum.random(base_delay..(previous_delay*3)), max_delay)
  end
end
