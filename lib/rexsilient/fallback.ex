defmodule Rexsilient.Fallback do
  @moduledoc """
  Replaces the outcome of a failed call with the result of another function.

  A fallback is declared in a module that uses `Rexsilient`, with the function
  to call instead:

      defmodule MyApp.Resilience do
        use Rexsilient

        fallback :prices do
          function :cached_price
        end

        def cached_price(sku), do: Cache.last_price(sku)
      end

  and used with `@fallback :prices` from `Rexsilient.Decorator`, which calls
  the fallback function with the decorated function's arguments:

      defmodule MyApp.Prices do
        use Rexsilient.Decorator

        @fallback :prices
        def fetch(sku) do
          PricesClient.fetch(sku)
        end
      end

  or, without a decorator, with `run/3`:

      Rexsilient.Fallback.run(:prices, fn sku -> PricesClient.fetch(sku) end, sku)

  ## Settings

    * `function` - the function called on failure: a name, for a function in
      the declaring module, or `{module, name}` for one in another module.
      Required.

    * `classify_with` - the name of the functions, in the declaring module,
      that decide which outcomes are failures and so are replaced. Defaults
      to `classify`; see `Rexsilient.Classify`.

  ## Behaviour

  The call is made. If its outcome is a success, it is returned unchanged.
  If it is a failure, the fallback function is called with the same
  arguments, and its result is returned instead; a raise, throw or exit
  counted as a failure is not re-raised.

  `{:error, :circuit_open}` is always replaced, without asking the classifier:
  a circuit breaker rejected the call, so there is no result to keep. This
  lets a fallback declared around a breaker answer while the breaker is open.

  An error raised by the fallback function itself propagates to the caller.
  """

  @typedoc "The name a fallback is declared with."
  @type name :: atom()

  @doc """
  Calls `func` with `args` through the fallback `name`.

  `args` is passed to `func` as its only argument, and to the fallback
  function in the same way, so both take one argument. Use a list or a tuple
  to pass several values. Returns `func`'s result, or the fallback's on
  failure; see [Behaviour](#module-behaviour).

  Raises `ArgumentError` if no fallback is registered under `name`.

  ## Examples

      Rexsilient.Fallback.run(:prices, fn sku -> Prices.fetch(sku) end, sku)

  """
  @spec run(name(), func :: (term() -> term()), args :: term()) :: term()
  def run(name, func, args \\ []) do
    call(fetch_config!(name), fn -> func.(args) end, [args])
  end

  @doc false
  def wrap_run(func, {_mod, _name, args}, opts) do
    {:ok, fallback_name} = Keyword.fetch(opts, :name)
    call(fetch_config!(fallback_name), func, args)
  end

  defp call(config, func, args) do
    %{classify: {classify_value, classify_exception}} = config

    try do
      func.()
    catch
      kind, reason ->
        case classify_exception.(kind, reason) do
          :failure -> use_fallback(config, args, {kind, reason})
          :success -> :erlang.raise(kind, reason, __STACKTRACE__)
        end
    else
      {:error, :circuit_open} = result ->
        use_fallback(config, args, {:value, result})

      result ->
        case classify_value.(result) do
          :failure -> use_fallback(config, args, {:value, result})
          :success -> result
        end
    end
  end

  defp use_fallback(%{name: name, function: {func_mod, func_name}}, args, outcome) do
    start = Rexsilient.Notifier.notify_start(:fallback, %{name: name, outcome: outcome})
    value = apply(func_mod, func_name, args)
    Rexsilient.Notifier.notify_stop(:fallback, start, %{name: name, outcome: {:value, value}})
    value
  end

  @doc false
  def __install__(modules) do
    fallbacks =
      for mod <- modules,
          config <- mod.__rexsilient__(:fallbacks),
          reduce: %{} do
        acc ->
          name = Keyword.fetch!(config, :name)

          if Map.has_key?(acc, name),
            do: raise(ArgumentError, "fallback #{inspect(name)} already exists")

          Map.put(acc, name, build(mod, config))
      end

    for {name, config} <- fallbacks do
      :persistent_term.put({__MODULE__, name}, config)
    end

    :ok
  end

  defp build(module, opts) do
    classify = Keyword.get(opts, :classify_with, :classify)

    %{
      name: Keyword.fetch!(opts, :name),
      module: module,
      function: Keyword.fetch!(opts, :function),
      classify: Rexsilient.Classify.__resolve__(module, classify)
    }
  end

  defp fetch_config!(name) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> raise ArgumentError, "unknown fallback #{inspect(name)}"
      config -> config
    end
  end
end
