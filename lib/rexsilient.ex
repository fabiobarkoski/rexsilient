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

        alias Rexsilient.CircuitBreaker.{Recover, Strategy}

        circuit_breaker :payments do
          strategy Strategy.Count, threshold: 5
          recover Recover.BasicTimeout,
            reset_timeout: :timer.seconds(30),
            probing_timeout: :timer.seconds(10)
        end

        circuit_breaker :search do
          strategy Strategy.Count, threshold: 10
          recover Recover.BasicTimeout,
            reset_timeout: :timer.seconds(5),
            probing_timeout: :timer.seconds(2)
        end
      end

  Declarations are checked at compile time: a missing setting, or a setting
  used outside `circuit_breaker/2`, fails compilation with an error that points
  at the offending line. The options of each setting are checked when the
  breaker is registered.

  The module is then passed to `Rexsilient.CircuitBreaker` in your supervision
  tree, which registers its breakers when it starts:

      children = [
        {Rexsilient.CircuitBreaker, modules: [MyApp.Breakers]},
        MyAppWeb.Endpoint
      ]

  List it before the processes that call the breakers, so the breakers exist
  when they are first used.

  ## Settings

    * `strategy` - the module that decides when the breaker opens, and its
      options. Required. See `strategy/2`.

    * `recover` - the module that decides how long the breaker stays open
      before it lets a probe call through, and how long a probe may run before
      another one is let through, and its options. Required. See `recover/2`.

  Modules and options are evaluated at compile time, so aliases and
  expressions such as `:timer.seconds(30)` are allowed.
  """

  @macros [
    :strategy,
    :recover
  ]

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Rexsilient, only: [circuit_breaker: 2, strategy: 2, recover: 2]
      Module.register_attribute(__MODULE__, :circuit_breakers, accumulate: true)
      @before_compile Rexsilient
      @behaviour Rexsilient.Failure

      def failure?(:error), do: :failure
      def failure?({:error, _}), do: :failure
      def failure?(_), do: :success

      defoverridable Rexsilient.Failure
    end
  end

  @doc """
  Declares a circuit breaker called `name`.

  `name` must be an atom, unique among all breakers registered on the node.
  The block sets the breaker's settings; see [Settings](#module-settings).

  ## Examples

      circuit_breaker :payments do
        strategy Rexsilient.CircuitBreaker.Strategy.Count, threshold: 5
        recover Rexsilient.CircuitBreaker.Recover.BasicTimeout,
          reset_timeout: :timer.seconds(30),
          probing_timeout: :timer.seconds(10)
      end

  """
  defmacro circuit_breaker(name, do: block) do
    if !is_atom(name) do
      compile_error!(location(__CALLER__), "Name #{inspect(name)} is not a valid atom")
    end

    quote do
      @current_cb [name: unquote(name)]
      unquote(block)
      Rexsilient.__save__(__MODULE__, unquote(location(__CALLER__)))
    end
  end

  @doc """
  Sets the strategy that decides when the breaker opens.

  `opts` are passed to `module` and only read by it. Can only be used inside
  `circuit_breaker/2`.

  ## Examples

      strategy Rexsilient.CircuitBreaker.Strategy.Count, threshold: 5

  """
  defmacro strategy(module, opts) do
    quote do:
            Rexsilient.__create__(
              __MODULE__,
              :strategy,
              unquote({module, opts}),
              unquote(location(__CALLER__))
            )
  end

  @doc """
  Sets how long the breaker stays open before it lets a probe call through,
  and how long a probe may run before the breaker lets another one through.

  `opts` are passed to `module` and only read by it. Can only be used inside
  `circuit_breaker/2`.

  ## Examples

      recover Rexsilient.CircuitBreaker.Recover.BasicTimeout,
        reset_timeout: :timer.seconds(30),
        probing_timeout: :timer.seconds(10)

  """
  defmacro recover(module, opts) do
    quote do:
            Rexsilient.__create__(
              __MODULE__,
              :recover,
              unquote({module, opts}),
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
        compile_error!(location, "#{key}/2 outside the circuit_breaker")

    Module.put_attribute(mod, :current_cb, Keyword.put(current_cb, key, value))
  end

  @doc false
  def __save__(mod, location) do
    current_cb = Module.get_attribute(mod, :current_cb)

    for key <- @macros,
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
