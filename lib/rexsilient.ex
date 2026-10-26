defmodule Rexsilient do
  @moduledoc """
  Rexsilient is a resilience toolkit for Elixir. Its patterns protect the calls
  an application makes to its dependencies:

    * `Rexsilient.CircuitBreaker` - stops calling a dependency that keeps
      failing.

    * `Rexsilient.Retry` - calls a function again when it fails, with backoff.

    * `Rexsilient.Fallback` - replaces the outcome of a failed call with the
      result of another function.

  ## Declaring patterns

  Patterns are declared in any module that uses `Rexsilient`. A module may
  declare as many as needed, of any kind:

      defmodule MyApp.Resilience do
        use Rexsilient

        alias Rexsilient.CircuitBreaker.{Recover, Strategy}

        circuit_breaker :payments do
          strategy Strategy.Count, threshold: 5
          recover Recover.BasicTimeout,
            reset_timeout: :timer.seconds(30),
            probing_timeout: :timer.seconds(10)
        end

        retry :payments do
          attempts 4
          strategy Rexsilient.Retry.Strategy.Exponential, base_delay: 100, max_delay: 5_000
        end

        fallback :prices do
          function :cached_price
        end

        def cached_price(sku), do: Cache.last_price(sku)
      end

  Declarations are checked at compile time: a missing required setting, a
  setting used outside the block it belongs to, or one set twice fails
  compilation with an error that points at the offending line. The options of
  each setting are checked when the declaration is registered.

  The module is then passed to `Rexsilient` in your supervision tree, which
  registers its declarations when it starts:

      children = [
        {Rexsilient, modules: [MyApp.Resilience]},
        MyAppWeb.Endpoint
      ]

  List it before the processes that use the declarations, so they exist when
  they are first used. See `child_spec/1` for the options.

  ## Settings

    * `circuit_breaker/2` - `strategy/2` and `recover/2`, required, and
      `classify_with/1`.

    * `retry/2` - `attempts/1` and `strategy/2`, required, and
      `classify_with/1`.

    * `fallback/2` - `function/1`, required, and `classify_with/1`.

    * `policy/2` - at least one of `fallback/1`, `retry/1` and
      `circuit_breaker/1`.

  Modules and options are evaluated at compile time, so aliases and
  expressions such as `:timer.seconds(30)` are allowed.

  ## Using patterns

  The easiest way is to annotate the functions that call the dependency, with
  `Rexsilient.Decorator`:

      defmodule MyApp.Payments do
        use Rexsilient.Decorator

        @retry :payments
        @circuit_breaker :payments
        def charge(order) do
          PaymentsClient.charge(order)
        end
      end

  Without a decorator, calls go through `Rexsilient.CircuitBreaker.run/3`,
  `Rexsilient.Retry.run/2` and `Rexsilient.Fallback.run/3`.

  ## Classifying failures

  `use Rexsilient` defines `classify/1` and `classify/2`, which decide which
  outcomes count as failures for every pattern declared in the module: by
  default, `:error`, `{:error, _}` and any raise, throw or exit. Override them,
  or name other functions with `classify_with/1`; see `Rexsilient.Classify`.
  """

  @dialyzer {:no_return, function_error!: 2}

  @doc """
  Returns a child specification that registers the declarations of the given
  modules and starts the processes they need.

  ## Options

    * `:modules` - the modules that declare with `Rexsilient`. Required.
      Raises `ArgumentError` if two declarations of the same kind share a
      name.

    * `:notifiers` - the modules told what the patterns are doing; see
      `Rexsilient.Notifier`. Defaults to
      `[Rexsilient.Notifier.TelemetryNotifier]`; `[]` sends nothing.

  ## Examples

      children = [
        {Rexsilient, modules: [MyApp.Resilience], notifiers: [MyApp.Notifier]}
      ]

  """
  @spec child_spec(opts :: [modules: [module()], notifiers: [module()]]) ::
          Supervisor.child_spec()
  def child_spec(opts), do: Rexsilient.Supervisor.child_spec(opts)

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Rexsilient,
        only: [
          circuit_breaker: 2,
          strategy: 2,
          recover: 2,
          fallback: 2,
          function: 1,
          classify_with: 1,
          retry: 2,
          attempts: 1,
          policy: 2,
          circuit_breaker: 1,
          fallback: 1,
          retry: 1
        ]

      Module.register_attribute(__MODULE__, :circuit_breakers, accumulate: true)
      Module.register_attribute(__MODULE__, :fallbacks, accumulate: true)
      Module.register_attribute(__MODULE__, :retries, accumulate: true)
      Module.register_attribute(__MODULE__, :policies, accumulate: true)
      @before_compile Rexsilient
      @behaviour Rexsilient.Classify

      def classify(:error), do: :failure
      def classify({:error, _}), do: :failure
      def classify(_), do: :success

      def classify(_kind, _reason), do: :failure

      defoverridable Rexsilient.Classify
    end
  end

  defp invalid_name?(value), do: not is_atom(value) or value in [nil, true, false]

  defp check_name!(name, location) do
    if invalid_name?(name) do
      compile_error!(location, "name must be an atom, got: #{inspect(name)}")
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
    declare(
      {:current_breaker, :circuit_breakers, [:strategy, :recover, :classify_with]},
      name,
      block,
      [:strategy, :recover],
      __CALLER__
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
  defmacro recover(module, opts), do: setting(:recover, {module, opts}, __CALLER__)

  @doc """
  Declares a fallback called `name`.

  `name` must be an atom, unique among all fallbacks registered on the node.
  The block sets the fallback's settings; see `Rexsilient.Fallback`.

  ## Examples

      fallback :prices do
        function :cached_price
      end

  """
  defmacro fallback(name, do: block) do
    declare(
      {:current_fallback, :fallbacks, [:function, :classify_with]},
      name,
      block,
      [:function],
      __CALLER__
    )
  end

  @doc """
  Sets the function a fallback calls when the call fails: a name, for a
  function in the declaring module, or `{module, name}` for one in another
  module. It is called with the same arguments as the failed call.

  Can only be used inside `fallback/2`.

  ## Examples

      function :cached_price

      function {MyApp.Cache, :last_price}

  """
  defmacro function(func), do: setting(:function, func, __CALLER__)

  @doc """
  Declares a retry called `name`.

  `name` must be an atom, unique among all retries registered on the node.
  The block sets the retry's settings; see `Rexsilient.Retry`.

  ## Examples

      retry :payments do
        attempts 4
        strategy Rexsilient.Retry.Strategy.Exponential, base_delay: 100, max_delay: 5_000
      end

  """
  defmacro retry(name, do: block) do
    declare(
      {:current_retry, :retries, [:strategy, :attempts, :classify_with]},
      name,
      block,
      [:attempts, :strategy],
      __CALLER__
    )
  end

  @doc """
  Sets the total number of calls a retry makes, the first one included: a
  positive integer, or `:infinity` to leave the limit to the strategy.

  Can only be used inside `retry/2`.

  ## Examples

      attempts 4

  """
  defmacro attempts(number), do: setting(:attempts, number, __CALLER__)

  @doc """
  Sets the strategy of a breaker or a retry.

  Inside `circuit_breaker/2`, it decides when the breaker opens; see
  `Rexsilient.CircuitBreaker.Strategy`. Inside `retry/2`, it decides how long
  to wait before the next attempt, or whether to stop; see
  `Rexsilient.Retry.Strategy`.

  `opts` are passed to `module` and only read by it. Can only be used inside
  `circuit_breaker/2` or `retry/2`.

  ## Examples

      strategy Rexsilient.CircuitBreaker.Strategy.Count, threshold: 5

      strategy Rexsilient.Retry.Strategy.Exponential, base_delay: 100, max_delay: 5_000

  """
  defmacro strategy(module, opts), do: setting(:strategy, {module, opts}, __CALLER__)

  @doc """
  Declares a policy called `name`: a fallback, a retry and a circuit breaker,
  each referenced by the name it is declared with, used together with
  `@policy name` from `Rexsilient.Decorator`.

  The block lists the declarations with `fallback/1`, `retry/1` and
  `circuit_breaker/1`. Each one is optional, but at least one is required.
  They always nest in the same order, whatever the order they are written in:

      fallback( retry( circuit_breaker( call ) ) )

  The referenced declarations may live in any module registered with
  `Rexsilient`. A name that is not declared raises `ArgumentError` when the
  policy is registered.

  ## Examples

      policy :prices do
        fallback :prices
        retry :prices
        circuit_breaker :prices
      end

  """
  defmacro policy(name, do: block) do
    declare(
      {:current_policy, :policies, [:fallback, :retry, :circuit_breaker]},
      name,
      block,
      [],
      __CALLER__
    )
  end

  @doc """
  References the circuit breaker `name` in a policy. Can only be used inside
  `policy/2`.
  """
  defmacro circuit_breaker(name), do: setting(:circuit_breaker, name, __CALLER__)

  @doc """
  References the fallback `name` in a policy. Can only be used inside
  `policy/2`.
  """
  defmacro fallback(name), do: setting(:fallback, name, __CALLER__)

  @doc """
  References the retry `name` in a policy. Can only be used inside
  `policy/2`.
  """
  defmacro retry(name), do: setting(:retry, name, __CALLER__)

  @doc """
  Sets the name of the functions, in the declaring module, that decide which
  outcomes are failures, instead of `classify/1` and `classify/2`. A missing
  `func_name/1` or `func_name/2` falls back to the `classify` one of the same
  arity; see `Rexsilient.Classify`.

  Can only be used inside `circuit_breaker/2`, `fallback/2` or `retry/2`.

  ## Examples

      classify_with :classify_payments

  """
  defmacro classify_with(func_name), do: setting(:classify_with, func_name, __CALLER__)

  defp declare(current_block, name, block, required_macros, caller) do
    location = location(caller)

    quote do
      Rexsilient.__init__(
        __MODULE__,
        unquote(Macro.escape(current_block)),
        unquote(name),
        unquote(location)
      )

      unquote(block)
      Rexsilient.__save__(__MODULE__, unquote(location), unquote(required_macros))
    end
  end

  defp setting(key, value, caller) do
    quote do:
            Rexsilient.__create__(
              __MODULE__,
              unquote(key),
              unquote(value),
              unquote(location(caller))
            )
  end

  @doc false
  defmacro __before_compile__(env) do
    {breakers, fallbacks, retries, policies} = get_declarations(env)

    classifiers = Module.get_attribute(env.module, :classifiers, [])
    Module.delete_attribute(env.module, :classifiers)

    for {func_name, declaration, location} <- Enum.reverse(classifiers),
        not Module.defines?(env.module, {func_name, 1}, :def),
        not Module.defines?(env.module, {func_name, 2}, :def) do
      compile_error!(
        location,
        "#{declaration}: classify_with #{inspect(func_name)} needs " <>
          "#{func_name}/1 or #{func_name}/2 defined with def in #{inspect(env.module)}"
      )
    end

    quote do
      def __rexsilient__(:circuit_breakers), do: unquote(Macro.escape(breakers))
      def __rexsilient__(:fallbacks), do: unquote(Macro.escape(fallbacks))
      def __rexsilient__(:retries), do: unquote(Macro.escape(retries))
      def __rexsilient__(:policies), do: unquote(Macro.escape(policies))
    end
  end

  @doc false
  def __init__(mod, {current_attr, _, _} = current_block, name, location) do
    check_name!(name, location)
    Module.put_attribute(mod, :current_block, current_block)
    Module.put_attribute(mod, current_attr, name: name)
  end

  @doc false
  def __create__(mod, key, value, location) do
    with {current_attr, _, allowed_macros} <- Module.get_attribute(mod, :current_block),
         attr_value when attr_value != nil <- Module.get_attribute(mod, current_attr) do
      cond do
        key not in allowed_macros ->
          allowed = Enum.map_join(allowed_macros, ", ", &setting_name/1)

          compile_error!(
            location,
            "#{setting_name(key)} is not allowed inside #{block_name(current_attr)}; " <>
              "allowed: #{allowed}"
          )

        Keyword.has_key?(attr_value, key) ->
          compile_error!(
            location,
            "#{setting_name(key)} is set twice in #{declaration(current_attr, attr_value)}"
          )

        true ->
          value = cast!(key, value, mod, location)
          Module.put_attribute(mod, current_attr, Keyword.put(attr_value, key, value))
      end
    else
      _ -> compile_error!(location, "#{setting_name(key)} outside the block")
    end
  end

  defp cast!(:function, {func_mod, func_name} = func, _mod, location) do
    if invalid_name?(func_mod) or invalid_name?(func_name), do: function_error!(func, location)
    func
  end

  defp cast!(:function, func_name, mod, location) do
    if invalid_name?(func_name), do: function_error!(func_name, location)
    {mod, func_name}
  end

  defp cast!(:classify_with, func_name, _mod, location) do
    if invalid_name?(func_name) do
      compile_error!(
        location,
        "classify_with/1 must be a function name, got: #{inspect(func_name)}"
      )
    end

    func_name
  end

  defp cast!(:attempts, number, _mod, location) do
    if number != :infinity and not (is_integer(number) and number > 0) do
      compile_error!(
        location,
        "attempts must be a positive integer or :infinity, got: #{inspect(number)}"
      )
    end

    number
  end

  defp cast!(key, {module, _opts} = value, _mod, location) when key in [:strategy, :recover] do
    if invalid_name?(module) do
      compile_error!(location, "#{setting_name(key)} needs a module, got: #{inspect(module)}")
    end

    value
  end

  defp cast!(key, name, _mod, location) when key in [:fallback, :retry, :circuit_breaker] do
    check_name!(name, location)
    name
  end

  defp cast!(_key, value, _mod, _location), do: value

  defp function_error!(value, location) do
    compile_error!(
      location,
      "function/1 must be a function name or {module, name}, got: #{inspect(value)}"
    )
  end

  defp setting_name(key), do: "#{key}/#{setting_arity(key)}"

  defp setting_arity(key) when key in [:strategy, :recover], do: 2
  defp setting_arity(_key), do: 1

  defp block_kind(:current_breaker), do: "circuit_breaker"
  defp block_kind(:current_fallback), do: "fallback"
  defp block_kind(:current_retry), do: "retry"
  defp block_kind(:current_policy), do: "policy"

  defp block_name(current_attr), do: "#{block_kind(current_attr)}/2"

  defp declaration(current_attr, attr_value),
    do: "#{block_kind(current_attr)} #{inspect(attr_value[:name])}"

  defp get_declarations(env) do
    breakers =
      env.module
      |> Module.get_attribute(:circuit_breakers)
      |> Enum.reverse()

    fallbacks =
      env.module
      |> Module.get_attribute(:fallbacks)
      |> Enum.reverse()

    retries =
      env.module
      |> Module.get_attribute(:retries)
      |> Enum.reverse()

    policies =
      env.module
      |> Module.get_attribute(:policies)
      |> Enum.reverse()

    if breakers == [] and fallbacks == [] and retries == [] and policies == [] do
      IO.warn("#{inspect(env.module)} uses Rexsilient but declares nothing", env)
    end

    {breakers, fallbacks, retries, policies}
  end

  @doc false
  def __save__(mod, location, required_macros) do
    {current_attr, final_attr, allowed_macros} = Module.get_attribute(mod, :current_block)
    attr_value = Module.get_attribute(mod, current_attr)
    declaration = declaration(current_attr, attr_value)

    if Enum.any?(Module.get_attribute(mod, final_attr), &(&1[:name] == attr_value[:name])) do
      compile_error!(location, "#{declaration} is already declared in #{inspect(mod)}")
    end

    for key <- required_macros,
        not Keyword.has_key?(attr_value, key),
        do: compile_error!(location, "#{declaration} is missing #{setting_name(key)}")

    if current_attr == :current_policy and Keyword.keys(attr_value) == [:name] do
      allowed = Enum.map_join(allowed_macros, ", ", &setting_name/1)
      compile_error!(location, "#{declaration} needs at least one of #{allowed}")
    end

    if classify = attr_value[:classify_with] do
      classifiers = Module.get_attribute(mod, :classifiers, [])
      Module.put_attribute(mod, :classifiers, [{classify, declaration, location} | classifiers])
    end

    Module.put_attribute(mod, final_attr, attr_value)
    Module.delete_attribute(mod, current_attr)
  end

  defp location(caller), do: [file: caller.file, line: caller.line]

  defp compile_error!(location, description) do
    raise CompileError, Keyword.put(location, :description, description)
  end
end
