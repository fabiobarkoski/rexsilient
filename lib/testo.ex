defmodule Testo do
  use Rexsilient
  alias Rexsilient.CircuitBreaker

  circuit_breaker :test do
    strategy(CircuitBreaker.Strategy.SlidingWindow, threshold: 3, window: :timer.seconds(5))
    recover(CircuitBreaker.Recover.BasicTimeout, reset_timeout: :timer.seconds(5), probing_timeout: :timer.seconds(5))
  end

  @impl true
  def failure?(404), do: :failure
  def failure?(result), do: super(result)
end
