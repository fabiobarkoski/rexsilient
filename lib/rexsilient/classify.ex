defmodule Rexsilient.Classify do
  @moduledoc """
  Decides whether the outcome of a call counts as a failure.

  Every module that uses `Rexsilient` implements this behaviour, and the
  circuit breakers, retries and fallbacks it declares use it. The defaults
  count `:error` and `{:error, _}` returns, and every raise, throw or exit, as
  failures; any other return counts as a success.

  Override `classify/1` to change how returned values are classified:

      defmodule MyApp.Resilience do
        use Rexsilient

        circuit_breaker :payments do
          # ...
        end

        @impl true
        def classify({:error, %{status: status}}) when status >= 500, do: :failure
        def classify(_), do: :success
      end

  Override `classify/2` to change how raises, throws and exits are classified.
  The two are independent: overriding `classify/1` keeps the default
  `classify/2`, so a catch-all clause on returns never turns an exception into
  a success.

      @impl true
      def classify(:error, %Mint.TransportError{}), do: :failure
      def classify(_kind, _reason), do: :success

  Circuit breakers and retries re-raise the exception unchanged either way;
  only how it is counted changes. A fallback replaces it when it counts as a
  failure, and re-raises it otherwise.

  To classify one declaration differently from the others in the same module,
  name other functions with `Rexsilient.classify_with/1`.
  """

  @typedoc "Whether a call succeeded or failed."
  @type result :: :success | :failure

  @typedoc """
  What a call produced: `{:value, value}` for a value it returned, or
  `{kind, reason}` for a raise, throw or exit, as given to `catch`.
  """
  @type outcome ::
          {:value, value :: term()}
          | {kind :: :error | :throw | :exit, reason :: term()}

  @doc """
  Classifies a value returned by the call.
  """
  @callback classify(value :: term()) :: result()

  @doc """
  Classifies a call that raised, threw or exited.

  `kind` and `reason` are the ones given to `catch`: for a raise, `kind` is
  `:error` and `reason` the exception.
  """
  @callback classify(kind :: :error | :throw | :exit, reason :: term()) :: result()

  @doc false
  def __resolve__(module, func_name) do
    Code.ensure_loaded!(module)
    {capture(module, func_name, 1), capture(module, func_name, 2)}
  end

  defp capture(module, func_name, arity) do
    if function_exported?(module, func_name, arity),
      do: Function.capture(module, func_name, arity),
      else: Function.capture(module, :classify, arity)
  end
end
