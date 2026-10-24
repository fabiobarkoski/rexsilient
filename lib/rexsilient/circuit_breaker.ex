defmodule Rexsilient.CircuitBreaker do
  @moduledoc """
  Circuit breakers stop calls to a dependency that keeps failing.

  When a dependency fails repeatedly, calling it again usually fails too: it
  wastes the caller's time and adds load to a service that is already
  struggling. A circuit breaker watches the calls made to the dependency and,
  after too many failures, rejects them immediately until the dependency has
  had time to recover.

  Breakers are declared with `Rexsilient` and called with `run/3`:

      case Rexsilient.CircuitBreaker.run(:payments, fn -> Payments.charge(order) end) do
        {:ok, receipt} -> {:ok, receipt}
        {:error, :circuit_open} -> {:error, :payments_unavailable}
        {:error, reason} -> {:error, reason}
      end

  ## States

  A breaker is always in one of four states, returned by `status/1`:

    * `:closed` - calls go through. Their results are passed to the
      breaker's `strategy`, which decides when it opens.

    * `:open` - calls are rejected without reaching the dependency. After the
      time set by its `recover` module, the breaker becomes half-open.

    * `:half_open` - the next call is let through as a *probe*, to test
      whether the dependency has recovered.

    * `:probing` - the probe is running. Every other call is rejected. If the
      probe succeeds, the breaker closes and its strategy is reset. If it
      fails, the breaker opens again. If it runs longer than the time set by
      the `recover` module, the breaker becomes half-open again and the slow
      probe's result is ignored.

  Exactly one caller becomes the probe, even when many arrive at once.

  ## Failures

  Whether a call counts as a failure is decided by the `classify/1` and
  `classify/2` functions of the module that declares the breaker, or by the
  functions named with `classify_with` in the breaker's declaration. By
  default, a call fails when the function returns `:error` or `{:error, _}`,
  or when it raises, throws or exits; every other return value counts as a
  success. See `Rexsilient.Classify` to change it.

  ## Starting

  Breakers are registered by a single manager process, started by `Rexsilient`
  in your supervision tree with the modules that declare them:

      children = [
        {Rexsilient, modules: [MyApp.Breakers]}
      ]

  Checking a breaker does not involve the manager: it is a single atomic read
  in the calling process, so it scales with the number of schedulers. The
  manager only handles state changes and timers. If it crashes, every breaker
  restarts closed, so a failure of the breaker itself never blocks traffic.
  """

  import Bitwise
  use GenServer

  @state 1

  @closed 0
  @open 1
  @half_open 2
  @probing 3

  @state_mask (1 <<< 61) - 1

  @typedoc "The state of a breaker; see [States](#module-states)."
  @type status :: :closed | :open | :half_open | :probing

  @typedoc "The name a breaker is declared with."
  @type name :: atom()

  @typedoc """
  Identifies the state a call was allowed in. Returned by `acquire/1` and
  passed unchanged to `release/4`.
  """
  @type state_counter :: non_neg_integer()

  @doc """
  Starts the breaker manager and registers the declared breakers.

  Usually started by `Rexsilient`, as shown in the module documentation.
  Only one manager runs per node; it is registered under this module's name.

  ## Options

    * `:modules` - the modules that declare breakers with `Rexsilient`.
      Required. The manager fails to start, with an `ArgumentError` as the
      reason, if two breakers share a name or a breaker's options are
      invalid.

  """
  @spec start_link(opts :: [modules: [module()]]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current state of the breaker `name`.

  Meant for inspection and debugging; see [States](#module-states) for what
  each state means. Raises `ArgumentError` if no breaker is registered under
  `name`.

  ## Examples

      Rexsilient.CircuitBreaker.status(:payments)
      #=> :closed

  """
  @spec status(name()) :: status()
  def status(name) do
    %{ref: ref} = fetch_config!(name)

    {_, status} = unpack(:atomics.get(ref, @state))
    get_status(status)
  end

  @doc """
  Records the result of a call allowed by `acquire/1`.

  `result` is `:success` or `:failure`, as decided by the caller, and
  `state_counter` is the value returned by `acquire/1`; pass it unchanged.
  Results recorded with a counter from a previous state are ignored, so a slow
  call cannot affect a breaker that has since changed state.

  `outcome` is what the call produced, `{:value, value}` or `{kind, reason}`.
  When the failure opens the breaker, it is passed to the `recover` module, so
  it can decide how long to stay open from the error itself, for example from
  a `Retry-After` header. It is optional; without it, the `recover` module
  gets `nil`.

  Call it exactly once for every successful `acquire/1`, including when the
  call raises. If the call was a probe and is not released in time, the
  breaker stays in `:probing`, rejecting calls, until the probing timeout set
  by its `recover` module makes it half-open again. See `acquire/1` for an
  example.

  The result is recorded in the calling process, so a call that opens or
  closes the breaker is reflected by `status/1` as soon as `release/4`
  returns. Only the timers that make a breaker half-open run in the manager.
  """
  @spec release(
          name(),
          Rexsilient.Classify.result(),
          state_counter(),
          Rexsilient.Classify.outcome() | nil
        ) :: :ok
  def release(name, result, state_counter, outcome \\ nil),
    do: release(name, result, state_counter, outcome, nil)

  defp release(name, result, state_counter, outcome, duration) do
    %{ref: ref, strategy: {strategy, strategy_state}} = fetch_config!(name)
    state_value = :atomics.get(ref, @state)

    case {unpack(state_value), result} do
      {{^state_counter, @probing}, :success} ->
        if :atomics.compare_exchange(ref, @state, state_value, pack(state_counter + 1, @closed)) ==
             :ok do
          strategy.reset(strategy_state)

          Rexsilient.Notifier.notify(:closed, :circuit_breaker, %{
            name: name,
            from: :probing,
            system_time: System.system_time()
          })
        end

      {{^state_counter, @probing}, :failure} ->
        if :atomics.compare_exchange(ref, @state, state_value, pack(state_counter + 1, @open)) ==
             :ok,
           do: cast_transition(name, {:probing, :open}, state_counter + 1, outcome)

      {{^state_counter, @closed}, _} ->
        if strategy.record(strategy_state, result, duration) == :trip and
             :atomics.compare_exchange(ref, @state, state_value, pack(state_counter + 1, @open)) ==
               :ok,
           do: cast_transition(name, {:closed, :open}, state_counter + 1, outcome)

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Forces the breaker `name` open.

  Calls are rejected until `force_close/1` is called: unlike a trip, no timer
  makes the breaker half-open, and no probe is let through. Meant for
  operators, for example to stop traffic to a dependency under maintenance.

  Calls already allowed, and probes already running, finish normally, but
  their results are ignored.

  Raises `ArgumentError` if no breaker is registered under `name`.

  ## Examples

      Rexsilient.CircuitBreaker.force_open(:payments)
      Rexsilient.CircuitBreaker.status(:payments)
      #=> :open

  """
  @spec force_open(name()) :: :ok
  def force_open(name), do: manager_call(name, :open)

  @doc """
  Forces the breaker `name` closed, and resets its strategy.

  Works from any state, including after `force_open/1`. Timers armed before
  it are ignored, and so are the results of calls allowed before it.

  Raises `ArgumentError` if no breaker is registered under `name`.

  ## Examples

      Rexsilient.CircuitBreaker.force_close(:payments)
      Rexsilient.CircuitBreaker.status(:payments)
      #=> :closed

  """
  @spec force_close(name()) :: :ok
  def force_close(name), do: manager_call(name, :close)

  defp manager_call(name, action) do
    case GenServer.call(__MODULE__, {action, name}) do
      :ok ->
        :ok

      {:error, :unknown_breaker} ->
        raise ArgumentError, "unknown circuit breaker #{inspect(name)}"
    end
  end

  @doc """
  Asks the breaker `name` whether a call may go through.

  Returns `{:ok, state_counter}` if the call is allowed, or
  `{:error, :circuit_open}` if it is rejected. When the breaker is half-open,
  the caller that gets `{:ok, _}` becomes the probe.

  Together with `release/4`, it is the building block of `run/3`. Use them
  directly when `run/3` does not fit, for example when what counts as a
  failure depends on the call site rather than on the breaker's `classify/1`.
  After an allowed call, pass its result, `state_counter` and outcome to
  `release/4`.

  They are only the breaker's state machine, without anything `run/3` adds
  around it: no `classify`, no catching of raises, throws and exits, no
  `:on_open`, and no `:before`, `:after` or `:rejected` notifications. Only
  the state changes caused by `release/4` are notified.

  Raises `ArgumentError` if no breaker is registered under `name`.

  ## Examples

  Counting only server errors as failures:

      case Rexsilient.CircuitBreaker.acquire(:payments) do
        {:ok, state_counter} ->
          try do
            PaymentsClient.charge(order)
          catch
            kind, reason ->
              Rexsilient.CircuitBreaker.release(:payments, :failure, state_counter, {kind, reason})
              :erlang.raise(kind, reason, __STACKTRACE__)
          else
            %{status: status} = response when status >= 500 ->
              Rexsilient.CircuitBreaker.release(:payments, :failure, state_counter, {:value, response})
              response

            response ->
              Rexsilient.CircuitBreaker.release(:payments, :success, state_counter, {:value, response})
              response
          end

        {:error, :circuit_open} ->
          {:error, :payments_unavailable}
      end

  """
  @spec acquire(name()) :: {:ok, state_counter()} | {:error, :circuit_open}
  def acquire(name) do
    %{ref: ref} = fetch_config!(name)
    state_value = :atomics.get(ref, @state)
    {state_counter, status} = unpack(state_value)

    case status do
      @closed ->
        {:ok, state_counter &&& @state_mask}

      @half_open ->
        case :atomics.compare_exchange(
               ref,
               @state,
               state_value,
               pack(state_counter + 1, @probing)
             ) do
          :ok ->
            cast_transition(name, {:half_open, :probing}, state_counter + 1, nil)

            {:ok, state_counter + 1 &&& @state_mask}

          _ ->
            {:error, :circuit_open}
        end

      _ ->
        {:error, :circuit_open}
    end
  end

  @doc """
  Calls `func` through the breaker `name`.

  If the breaker allows the call, `func` is invoked and its result is returned
  unchanged. The result is then recorded as a success or a failure (see
  [Failures](#module-failures)). If `func` raises, throws or exits, the
  outcome is recorded the same way and the error is re-raised unchanged.

  If the breaker rejects the call, `func` is not invoked and
  `{:error, :circuit_open}` is returned, unless `:on_open` says otherwise. To
  compute another result instead, wrap the call in a `Rexsilient.Fallback`,
  which always replaces `{:error, :circuit_open}`.

  Raises `ArgumentError` if no breaker is registered under `name`.

  ## Options

    * `:on_open` - the value returned when the call is rejected, instead of
      `{:error, :circuit_open}`.

  ## Examples

      Rexsilient.CircuitBreaker.run(:payments, fn -> Payments.charge(order) end)

      Rexsilient.CircuitBreaker.run(:payments, fn -> Payments.charge(order) end,
        on_open: {:error, :unavailable}
      )

  """
  @spec run(name(), func :: (-> term()), opts :: [on_open: term()]) :: term()
  def run(name, func, opts \\ []) do
    case acquire(name) do
      {:ok, state_counter} ->
        %{classify: {classify_value, classify_exception}} = fetch_config!(name)
        start = Rexsilient.Notifier.notify_start(:circuit_breaker, %{name: name})

        try do
          func.()
        catch
          kind, reason ->
            finish(name, classify_exception.(kind, reason), state_counter, {kind, reason}, start)
            :erlang.raise(kind, reason, __STACKTRACE__)
        else
          result ->
            finish(name, classify_value.(result), state_counter, {:value, result}, start)
            result
        end

      {:error, :circuit_open} ->
        Rexsilient.Notifier.notify(:rejected, :circuit_breaker, %{
          name: name,
          system_time: System.system_time()
        })

        Keyword.get(opts, :on_open, {:error, :circuit_open})
    end
  end

  defp finish(name, result, state_counter, outcome, start) do
    release(name, result, state_counter, outcome, System.monotonic_time() - start)

    Rexsilient.Notifier.notify_stop(:circuit_breaker, start, %{
      name: name,
      result: result,
      outcome: outcome
    })
  end

  defp cast_transition(name, transition, state_counter, outcome) do
    GenServer.cast(
      __MODULE__,
      {:transition, name, transition, state_counter, outcome, System.system_time()}
    )
  end

  defp notify_transition(name, from, to, info \\ %{}) do
    state =
      info
      |> Map.merge(%{name: name, from: from})
      |> Map.put_new_lazy(:system_time, &System.system_time/0)

    Rexsilient.Notifier.notify_from_manager(to, :circuit_breaker, state)
  end

  @doc false
  def wrap_run(func, {_mod, _name, _args}, opts) do
    {breaker_name, breaker_opts} = Keyword.pop!(opts, :name)
    run(breaker_name, func, breaker_opts)
  end

  @impl true
  def init(opts) do
    breakers =
      for mod <- Keyword.fetch!(opts, :modules),
          config <- mod.__rexsilient__(:circuit_breakers),
          reduce: %{} do
        acc ->
          name = Keyword.fetch!(config, :name)

          if Map.has_key?(acc, name),
            do: raise(ArgumentError, "circuit breaker #{inspect(name)} already exists")

          Map.put(acc, name, install(name, mod, config))
      end

    {:ok, breakers}
  end

  @impl true
  def handle_call({:open, name}, _from, state) do
    case Map.fetch(state, name) do
      {:ok, %{ref: ref}} ->
        {state_counter, status} = unpack(:atomics.get(ref, @state))
        :ok = :atomics.put(ref, @state, pack(state_counter + 1, @open))
        notify_transition(name, get_status(status), :open, %{
          timeout: :infinity,
          outcome: nil,
          forced: true
        })
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :unknown_breaker}, state}
    end
  end

  @impl true
  def handle_call({:close, name}, _from, state) do
    case Map.fetch(state, name) do
      {:ok, %{ref: ref, strategy: {strategy, strategy_state}}} ->
        {state_counter, status} = unpack(:atomics.get(ref, @state))
        :ok = :atomics.put(ref, @state, pack(state_counter + 1, @closed))
        :ok = strategy.reset(strategy_state)
        notify_transition(name, get_status(status), :closed, %{forced: true})
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :unknown_breaker}, state}
    end
  end

  @impl true
  def handle_info({:half_open, name, status, state_counter}, state) do
    %{ref: ref} = Map.fetch!(state, name)

    expected =
      case status do
        :probing -> pack(state_counter, @probing)
        :open -> pack(state_counter, @open)
      end

    if :atomics.compare_exchange(ref, @state, expected, pack(state_counter + 1, @half_open)) ==
         :ok,
       do: notify_transition(name, status, :half_open)

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:transition, name, {from, to} = transition, state_counter, outcome, system_time},
        state
      ) do
    %{recover: {recover, recover_state}} = config = Map.fetch!(state, name)

    {timeout, recover_state} =
      recover.timeout(%{transition: transition, outcome: outcome}, recover_state)

    Process.send_after(self(), {:half_open, name, to, state_counter}, timeout)
    notify_transition(name, from, to, %{
      timeout: timeout,
      outcome: outcome,
      system_time: system_time
    })

    {:noreply, Map.put(state, name, %{config | recover: {recover, recover_state}})}
  end

  defp install(name, module, opts) do
    key = {__MODULE__, name}

    {strategy, strategy_opts} = opts[:strategy]
    {recover, recover_opts} = opts[:recover]

    classify = Keyword.get(opts, :classify_with, :classify)

    owner = "circuit breaker #{inspect(name)}"
    :ok = Rexsilient.Utils.implements!(strategy, __MODULE__.Strategy, owner)
    :ok = Rexsilient.Utils.implements!(recover, __MODULE__.Recover, owner)

    config = %{
      module: module,
      strategy: {strategy, init_setting!(name, :strategy, strategy, strategy_opts)},
      recover: {recover, init_setting!(name, :recover, recover, recover_opts)},
      classify: Rexsilient.Classify.__resolve__(module, classify)
    }

    case :persistent_term.get(key, nil) do
      nil ->
        ref = :atomics.new(1, [])
        :ok = :atomics.put(ref, @state, pack(0, @closed))
        config = Map.put(config, :ref, ref)
        :persistent_term.put(key, config)
        config

      %{ref: ref} ->
        config = Map.put(config, :ref, ref)
        :persistent_term.put(key, config)
        {state_counter, status} = unpack(:atomics.get(ref, @state))
        :ok = :atomics.put(ref, @state, pack(state_counter + 1, @closed))

        if status != @closed,
          do: notify_transition(name, get_status(status), :closed, %{restart: true})

        config
    end
  end

  defp init_setting!(name, setting, module, opts) do
    module.init(opts)
  rescue
    error in ArgumentError ->
      reraise ArgumentError,
              "circuit breaker #{inspect(name)}: invalid #{setting} options for " <>
                "#{inspect(module)}: #{Exception.message(error)}",
              __STACKTRACE__
  end

  defp fetch_config!(name) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> raise ArgumentError, "unknown circuit breaker #{inspect(name)}"
      config -> config
    end
  end

  defp pack(state_counter, status) do
    (state_counter &&& @state_mask) <<< 2 ||| status
  end

  defp unpack(value) do
    {value >>> 2, value &&& 0b11}
  end

  defp get_status(@closed), do: :closed
  defp get_status(@open), do: :open
  defp get_status(@half_open), do: :half_open
  defp get_status(@probing), do: :probing
end
