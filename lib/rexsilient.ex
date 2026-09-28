defmodule Rexsilient do
  @moduledoc """
  Rexsilient is a resilience toolkit for Elixir.

  It provides patterns that let an application handle failing dependencies
  gracefully. The circuit breaker is the first one; see
  `Rexsilient.CircuitBreaker` for how breakers behave and how to call them.

  ## Declaring breakers

  Breakers are declared in any module that uses `Rexsilient`. A module may
  declare as many as needed, typically one per dependency:

      defmodule MyApp.Breakers do
        use Rexsilient

        circuit_breaker :payments do
          threshold 5
          timeout :timer.seconds(30)
        end

        circuit_breaker :search do
          threshold 10
          timeout :timer.seconds(5)
        end
      end

  Declarations are validated at compile time. A missing or invalid setting
  fails compilation with an error that points at the offending line.

  The module is then passed to `Rexsilient.CircuitBreaker` in your supervision
  tree, which registers its breakers when it starts:

      children = [
        {Rexsilient.CircuitBreaker, modules: [MyApp.Breakers]},
        MyAppWeb.Endpoint
      ]

  List it before the processes that call the breakers, so the breakers exist
  when they are first used.

  ## Settings

    * `threshold` - the number of failures that opens the breaker. Failures
      are counted from the moment the breaker was last closed. Required.

    * `timeout` - how long, in milliseconds, the breaker stays open before it
      lets a probe call through. Required.

  Both must be positive integers. Values are evaluated at compile time, so
  expressions such as `:timer.seconds(30)` are allowed.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Rexsilient, only: [circuit_breaker: 2, timeout: 1, threshold: 1]
      Module.register_attribute(__MODULE__, :circuit_breakers, accumulate: true)
      @before_compile Rexsilient
    end
  end

  @doc """
  Declares a circuit breaker called `name`.

  `name` must be an atom, unique among all breakers registered on the node.
  The block sets the breaker's settings; see [Settings](#module-settings).

  ## Examples

      circuit_breaker :payments do
        threshold 5
        timeout :timer.seconds(30)
      end

  """
  defmacro circuit_breaker(name, do: block) do
    if !is_atom(name) do
      compile_error!(location(__CALLER__), "Name #{inspect(name)} is not valid a atom")
    end

    quote do
      @current_cb [name: unquote(name)]
      unquote(block)
      Rexsilient.__save__(__MODULE__, unquote(location(__CALLER__)))
    end
  end

  @doc """
  Sets how long, in milliseconds, the breaker stays open before it lets a
  probe call through.

  Must be a positive integer and can only be used inside `circuit_breaker/2`.

  ## Examples

      timeout 5_000
      timeout :timer.seconds(5)

  """
  defmacro timeout(value) do
    quote do:
            Rexsilient.__create__(
              __MODULE__,
              :timeout,
              unquote(value),
              unquote(location(__CALLER__))
            )
  end

  @doc """
  Sets the number of failures that opens the breaker.

  Failures are counted from the moment the breaker was last closed. Must be a
  positive integer and can only be used inside `circuit_breaker/2`.

  ## Examples

      threshold 5

  """
  defmacro threshold(value) do
    quote do:
            Rexsilient.__create__(
              __MODULE__,
              :threshold,
              unquote(value),
              unquote(location(__CALLER__))
            )
  end

  @doc false
  defmacro __before_compile__(env) do
    circuits =
      env.module
      |> Module.get_attribute(:circuit_breakers)
      |> Enum.reverse()

    if circuits == [] do
      IO.warn("#{inspect(env.module)} uses Rexsilient but declares no circuit breakers", env)
    end

    quote do
      def __rexsilient__(:circuit_breakers), do: unquote(Macro.escape(circuits))
    end
  end

  @doc false
  def __create__(mod, key, value, location) do
    current_cb =
      Module.get_attribute(mod, :current_cb) ||
        compile_error!(location, "#{key}/1 outside the circuit_breaker")

    if not is_integer(value) or value <= 0,
      do: compile_error!(location, "#{key}/1 must be a positive integer")

    Module.put_attribute(mod, :current_cb, Keyword.put(current_cb, key, value))
  end

  @doc false
  def __save__(mod, location) do
    current_cb = Module.get_attribute(mod, :current_cb)

    for key <- [:timeout, :threshold],
        not Keyword.has_key?(current_cb, key),
        do: compile_error!(location, "Missing #{key}")

    Module.put_attribute(mod, :circuit_breakers, current_cb)
    Module.delete_attribute(mod, :current_cb)
  end

  defp location(caller), do: [file: caller.file, line: caller.line]

  defp compile_error!(location, description) do
    raise CompileError, Keyword.put(location, :description, description)
  end
end
