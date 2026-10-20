defmodule Rexsilient.Retry do
  @moduledoc """
  Calls a function again when it fails.

  A retry is declared in a module that uses `Rexsilient`:

      defmodule MyApp.Resilience do
        use Rexsilient

        alias Rexsilient.Retry.Strategy

        retry :payments do
          attempts 4
          strategy Strategy.Exponential, base_delay: 100, max_delay: 5_000, jitter: :full
        end
      end

  and used with `run/2`, or with `@retry :payments` from
  `Rexsilient.Decorator`:

      Rexsilient.Retry.run(:payments, fn -> Payments.charge(order) end)

  ## Settings

    * `attempts` - the total number of calls, the first one included. A
      positive integer, or `:infinity` to leave the limit to the strategy.
      Required.

    * `strategy` - the module that decides how long to wait before the next
      attempt, or to stop, and its options. Required. See
      `Rexsilient.Retry.Strategy`.

    * `classify_with` - the name of the functions, in the declaring module,
      that decide which outcomes are failures and so are retried. Defaults to
      `classify`; see `Rexsilient.Classify`.

  ## Behaviour

  The function is called. If its outcome is a success, it is returned. If it
  is a failure and attempts remain, the strategy is asked for a delay, the
  caller sleeps for it, and the function is called again.

  When no attempts remain, or the strategy stops, the last outcome is
  returned unchanged: the value the function returned, or what it raised,
  threw or exited with, re-raised with its original stacktrace.

  `{:error, :circuit_open}` is never retried: a circuit breaker just said the
  dependency is down, and retrying would only wait for the same answer.

  The delay runs in the calling process, with `Process.sleep/1`.

  > #### What is retried by default {: .warning}
  >
  > The default `classify` counts every `{:error, _}` and every raise, throw
  > and exit as a failure, so all of them are retried. That includes bugs,
  > such as a `FunctionClauseError`, which then crash only after every
  > attempt and its delay. It also includes calls that are not idempotent
  > and may have taken effect before failing. Use `classify_with` to retry
  > only the failures that are safe and worth retrying.
  """

  @typedoc "The name a retry is declared with."
  @type name :: atom()

  @doc """
  Calls `func` through the retry `name`.

  Returns the outcome of the last attempt; see [Behaviour](#module-behaviour).

  Raises `ArgumentError` if no retry is registered under `name`.

  ## Examples

      Rexsilient.Retry.run(:payments, fn -> Payments.charge(order) end)

  """
  @spec run(name(), func :: (-> term())) :: term()
  def run(name, func) do
    %{strategy: {_strategy, state}} = config = fetch_config!(name)
    attempt(config, func, 1, state)
  end

  @doc false
  def wrap_run(func, {_mod, _name, _args}, opts) do
    run(Keyword.fetch!(opts, :name), func)
  end

  defp attempt(config, func, attempt, state) do
    %{attempts: attempts, strategy: {strategy, _}, classify: classify} = config

    case call(func, classify) do
      {:failure, outcome, stacktrace} when attempt != attempts ->
        case strategy.delay(%{attempt: attempt, outcome: outcome}, state) do
          {:retry, delay, state} ->
            Process.sleep(delay)
            attempt(config, func, attempt + 1, state)

          :stop ->
            finish(outcome, stacktrace)
        end

      {_result, outcome, stacktrace} ->
        finish(outcome, stacktrace)
    end
  end

  defp call(func, {classify_value, classify_exception}) do
    try do
      func.()
    catch
      kind, reason -> {classify_exception.(kind, reason), {kind, reason}, __STACKTRACE__}
    else
      {:error, :circuit_open} = value -> {:success, {:value, value}, nil}
      value -> {classify_value.(value), {:value, value}, nil}
    end
  end

  defp finish({:value, value}, _stacktrace), do: value
  defp finish({kind, reason}, stacktrace), do: :erlang.raise(kind, reason, stacktrace)

  @doc false
  def __install__(modules) do
    retries =
      for mod <- modules,
          config <- mod.__rexsilient__(:retries),
          reduce: %{} do
        acc ->
          name = Keyword.fetch!(config, :name)

          if Map.has_key?(acc, name),
            do: raise(ArgumentError, "retry #{inspect(name)} already exists")

          Map.put(acc, name, build(name, mod, config))
      end

    for {name, config} <- retries do
      :persistent_term.put({__MODULE__, name}, config)
    end

    :ok
  end

  defp build(name, module, opts) do
    {strategy, strategy_opts} = Keyword.fetch!(opts, :strategy)
    classify = Keyword.get(opts, :classify_with, :classify)

    :ok = Rexsilient.Options.implements!(strategy, __MODULE__.Strategy, "retry #{inspect(name)}")

    %{
      attempts: Keyword.fetch!(opts, :attempts),
      strategy: {strategy, init_strategy!(name, strategy, strategy_opts)},
      classify: Rexsilient.Classify.__resolve__(module, classify)
    }
  end

  defp init_strategy!(name, module, opts) do
    module.init(opts)
  rescue
    error in ArgumentError ->
      reraise ArgumentError,
              "retry #{inspect(name)}: invalid strategy options for " <>
                "#{inspect(module)}: #{Exception.message(error)}",
              __STACKTRACE__
  end

  defp fetch_config!(name) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> raise ArgumentError, "unknown retry #{inspect(name)}"
      config -> config
    end
  end
end
