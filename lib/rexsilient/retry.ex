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

  and used with `@retry :payments` from `Rexsilient.Decorator`:

      defmodule MyApp.Payments do
        use Rexsilient.Decorator

        @retry :payments
        def charge(order) do
          PaymentsClient.charge(order)
        end
      end

  or, without a decorator, with `run/2`:

      Rexsilient.Retry.run(:payments, fn -> PaymentsClient.charge(order) end)

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
  dependency is down, and retrying would only wait for the same answer. It is
  a failure whatever `classify` says, and it ends the run at once.

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
    attempt(config, func, 1, state, System.monotonic_time())
  end

  @doc false
  def wrap_run(func, {_mod, _name, _args}, opts) do
    run(Keyword.fetch!(opts, :name), func)
  end

  defp attempt(config, func, attempt, state, run_start) do
    %{name: name, attempts: attempts, strategy: {strategy, _}, classify: classify} = config

    start = Rexsilient.Notifier.notify_start(:retry, %{name: name, attempt: attempt})
    {result, outcome, stacktrace} = call(func, classify)
    info = %{name: name, attempt: attempt, outcome: outcome}
    Rexsilient.Notifier.notify_stop(:retry, start, Map.put(info, :result, result))

    case result do
      :failure when outcome == {:value, {:error, :circuit_open}} ->
        give_up(info, :circuit_open, run_start)
        finish(outcome, stacktrace)

      :failure when attempt != attempts ->
        case strategy.delay(%{attempt: attempt, outcome: outcome}, state) do
          {:retry, delay, state} ->
            Rexsilient.Notifier.notify(:delay, :retry, Map.put(info, :delay, delay))
            Process.sleep(delay)
            attempt(config, func, attempt + 1, state, run_start)

          :stop ->
            give_up(info, :strategy, run_start)
            finish(outcome, stacktrace)
        end

      :failure ->
        give_up(info, :attempts, run_start)
        finish(outcome, stacktrace)

      :success ->
        finish(outcome, stacktrace)
    end
  end

  defp give_up(info, reason, run_start) do
    info = Map.merge(info, %{reason: reason, duration: System.monotonic_time() - run_start})
    Rexsilient.Notifier.notify(:stop, :retry, info)
  end

  defp call(func, {classify_value, classify_exception}) do
    func.()
  catch
    kind, reason -> {classify_exception.(kind, reason), {kind, reason}, __STACKTRACE__}
  else
    {:error, :circuit_open} = value -> {:failure, {:value, value}, nil}
    value -> {classify_value.(value), {:value, value}, nil}
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

    :ok = Rexsilient.Utils.implements!(strategy, __MODULE__.Strategy, "retry #{inspect(name)}")

    %{
      name: name,
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
