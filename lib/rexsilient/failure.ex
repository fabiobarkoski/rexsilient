defmodule Rexsilient.Failure do
  @moduledoc """
  Decides whether the result of a call counts as a failure.

  Every module that uses `Rexsilient` implements this behaviour, with a
  default that counts `:error` and `{:error, _}` as failures and everything
  else as a success. Override `failure?/1` to change it for all the breakers
  the module declares:

      defmodule MyApp.Breakers do
        use Rexsilient

        circuit_breaker :payments do
          # ...
        end

        @impl true
        def failure?({:error, %{status: status}}) when status >= 500, do: :failure
        def failure?(_), do: :success
      end

  Only results returned by the function are passed to it. A raise, throw or
  exit always counts as a failure.
  """

  @typedoc "Whether a call succeeded or failed."
  @type result :: :success | :failure

  @doc """
  Returns `:failure` if `result` counts as a failure, `:success` otherwise.
  """
  @callback failure?(result :: term()) :: result()
end
