defmodule Rexsilient.Decorator do
  @moduledoc """
  Runs a function through a [circuit breaker](`Rexsilient.CircuitBreaker`)
  by annotating it.

  Instead of wrapping every call in `Rexsilient.CircuitBreaker.run/3`, a
  function can be marked with `@circuit_breaker` so that all its calls go
  through the breaker:

      defmodule MyApp.Payments do
        use Rexsilient.Decorator

        @circuit_breaker :payments
        def charge(order) do
          PaymentsClient.charge(order)
        end
      end

  `MyApp.Payments.charge(order)` now behaves like:

      Rexsilient.CircuitBreaker.run(:payments, fn -> PaymentsClient.charge(order) end)

  The breaker must be declared with `Rexsilient` and registered as usual; see
  `Rexsilient.CircuitBreaker` for its results and how failures are counted.

  ## Options

  To pass options to `Rexsilient.CircuitBreaker.run/3`, give a keyword list
  with the breaker name under `:name`:

      @circuit_breaker name: :prices, fallback: &Cache.last_price/0
      def fetch_price(sku) do
        PricesClient.fetch(sku)
      end

  Anonymous functions cannot be stored in module attributes, so pass
  `:fallback` as a function capture.

  ## Rules

    * The attribute goes right before the function's first clause and applies
      to every clause of that name and arity.

    * Only public functions (`def`) can be decorated. Using it on `defp` or a
      macro fails compilation, and so does an attribute that is not followed
      by a function.

    * Recursive calls from inside the function go through the breaker too.

  """

  @decorators [
    circuit_breaker: {Rexsilient.CircuitBreaker, :wrap_run}
  ]

  @doc false
  defmacro __using__(_opts) do
    registrations =
      for {name, _} <- @decorators do
        quote do: Module.register_attribute(__MODULE__, unquote(name), [])
      end

    quote do
      unquote_splicing(registrations)
      Module.register_attribute(__MODULE__, :__decorated__, accumulate: true)
      @on_definition Rexsilient.Decorator
      @before_compile Rexsilient.Decorator
    end
  end

  @doc false
  def __on_definition__(env, kind, name, args, _guards, _body) do
    pending =
      for {attr, {mod, func}} <- @decorators,
        value = Module.get_attribute(env.module, attr),
        value not in [nil, false] do
      Module.delete_attribute(env.module, attr)
      {attr, {mod, func, normalize_opts!(env, attr, value, name)}}
      end
    cond do
      pending == [] ->
        :ok
      kind != :def ->
        compile_error!(
          env,
          "Decorators are only supported on def, got #{kind} #{name}"
        )
      true ->
        arity = length(args)

        for {_attr, decorator} <- pending do
          Module.put_attribute(env.module, :__decorated__, {name, arity, decorator})
        end
        :ok
      end
  end

  @doc false
  defmacro __before_compile__(env) do
    decorators_have_func?(env)

    env.module
    |> Module.get_attribute(:__decorated__)
    |> Enum.reverse()
    |> Enum.group_by(fn {name, arity, _} -> {name, arity} end, fn {_, _, dec} -> dec end)
    |> Enum.map(fn {{name, arity}, decorators} ->
      define_wrapper(env.module, name, arity, decorators)
    end)
  end

  defp define_wrapper(mod, name, arity, decorators) do
    args = Macro.generate_arguments(arity, mod)

    context =
      quote do
        {__MODULE__, unquote(name), [unquote_splicing(args)]}
      end

    body =
      decorators
      |> Enum.reverse()
      |> Enum.reduce(quote(do: super(unquote_splicing(args))), fn {mod, func, opts}, inner ->
        quote do
          unquote(mod).unquote(func)(
            fn -> unquote(inner) end,
            unquote(context),
            unquote(Macro.escape(opts))
          )
        end
      end)

      quote do
        defoverridable [{unquote(name), unquote(arity)}]

        def unquote(name)(unquote_splicing(args)) do
          unquote(body)
        end
      end
  end

  defp normalize_opts!(_env, _attr, value, _name) when is_atom(value),
    do: [name: value]
  defp normalize_opts!(env, attr, value, name) do
    if Keyword.keyword?(value) do
      value
    else
      compile_error!(
        env,
        "@#{attr} on #{name} must be atom or a keyword list, got: #{inspect(value)}"
      )
    end
  end

  defp decorators_have_func?(env) do
    for {decorator_name, _decorator} <- @decorators,
      Module.get_attribute(env.module, decorator_name) not in [nil, false] do
      compile_error!(
        env,
        "@#{decorator_name} is not followed by a function definition"
      )
    end
  end

  defp compile_error!(env, description) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description: description
  end
end
