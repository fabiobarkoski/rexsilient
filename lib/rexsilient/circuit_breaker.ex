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

    * `:closed` - calls go through. Failures are passed to the breaker's
      `strategy`, which decides when it opens.

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
  `classify/2` functions of the module that declares the breaker. By default,
  a call fails when the function returns `:error` or `{:error, _}`, or when it
  raises, throws or exits; every other return value counts as a success. See
  `Rexsilient.Classify` to change it.

  ## Starting

  Breakers are registered by a single manager process, which must be added to
  your supervision tree with the modules that declare them:

      children = [
        {Rexsilient.CircuitBreaker, modules: [MyApp.Breakers]}
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
  passed unchanged to `release/3`.
  """
  @type state_counter :: non_neg_integer()

  @doc """
  Starts the breaker manager and registers the declared breakers.

  Usually started through a supervisor, as shown in the module documentation.
  Only one manager runs per node; it is registered under this module's name.

  ## Options

    * `:modules` - the modules that declare breakers with `Rexsilient`.
      Required. Raises `ArgumentError` if two breakers share a name.

  """
  @spec start_link(opts :: [modules: [module()]]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current state of the breaker `name`.

  Meant for inspection and debugging; see [States](#module-states) for what
  each state means. Raises `ArgumentError` if no
  breaker is registered under `name`.

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

  Call it exactly once for every successful `acquire/1`, including when the
  call raises. If the call was a probe and is not released in time, the
  breaker stays in `:probing`, rejecting calls, until the probing timeout set
  by its `recover` module makes it half-open again. See `acquire/1` for an
  example.

  The result is recorded in the calling process, so a call that opens or
  closes the breaker is reflected by `status/1` as soon as `release/3`
  returns. Only the timers that make a breaker half-open run in the manager.
  """
  @spec release(
          name(),
          Rexsilient.Classify.result(),
          state_counter()
        ) :: :ok
  def release(name, result, state_counter) do
    %{ref: ref, strategy: {strategy, strategy_state}} = fetch_config!(name)
    state_value = :atomics.get(ref, @state)

    case {unpack(state_value), result} do
      {{^state_counter, @probing}, :success} ->
        if strategy.record(strategy_state, result, 0) == :ok and
             :atomics.compare_exchange(ref, @state, state_value, pack(state_counter + 1, @closed)) ==
               :ok,
           do: strategy.reset(strategy_state)

      {{^state_counter, @probing}, :failure} ->
        if :atomics.compare_exchange(ref, @state, state_value, pack(state_counter + 1, @open)) ==
             :ok,
           do: GenServer.cast(__MODULE__, {:release, name, {:probing, :open}, state_counter + 1})

      {{^state_counter, @closed}, :failure} ->
        if strategy.record(strategy_state, result, 0) == :trip and
             :atomics.compare_exchange(ref, @state, state_value, pack(state_counter + 1, @open)) ==
               :ok,
           do: GenServer.cast(__MODULE__, {:release, name, {:closed, :open}, state_counter + 1})

      _ ->
        :ok
    end
  end

  @doc """
  Asks the breaker `name` whether a call may go through.

  Returns `{:ok, state_counter}` if the call is allowed, or
  `{:error, :circuit_open}` if it is rejected. When the breaker is half-open,
  the caller that gets `{:ok, _}` becomes the probe.

  Together with `release/3`, it is the building block of `run/3`. Use them
  directly when `run/3` does not fit, for example when what counts as a
  failure depends on the call site rather than on the breaker's `classify/1`.
  After an allowed call, pass its result and `state_counter` to `release/3`.

  Raises `ArgumentError` if no breaker is registered under `name`.

  ## Examples

  Counting only server errors as failures:

      case Rexsilient.CircuitBreaker.acquire(:payments) do
        {:ok, state_counter} ->
          try do
            PaymentsClient.charge(order)
          catch
            kind, reason ->
              Rexsilient.CircuitBreaker.release(:payments, :failure, state_counter)
              :erlang.raise(kind, reason, __STACKTRACE__)
          else
            %{status: status} = response when status >= 500 ->
              Rexsilient.CircuitBreaker.release(:payments, :failure, state_counter)
              response

            response ->
              Rexsilient.CircuitBreaker.release(:payments, :success, state_counter)
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
            GenServer.cast(__MODULE__, {:release, name, {:half_open, :probing}, state_counter + 1})
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
  `{:error, :circuit_open}` is returned, unless one of the options below says
  otherwise.

  Raises `ArgumentError` if no breaker is registered under `name`.

  ## Options

    * `:on_open` - the value returned when the call is rejected, instead of
      `{:error, :circuit_open}`.

    * `:fallback` - a zero-arity function called when the call is rejected;
      its result is returned. Takes precedence over `:on_open`.

  ## Examples

      Rexsilient.CircuitBreaker.run(:payments, fn -> Payments.charge(order) end)

      Rexsilient.CircuitBreaker.run(:payments, fn -> Payments.charge(order) end,
        on_open: {:error, :unavailable}
      )

      Rexsilient.CircuitBreaker.run(:prices, fn -> Prices.fetch(sku) end,
        fallback: fn -> Cache.last_price(sku) end
      )

  """
  @spec run(
          name(),
          func :: (-> term()),
          opts :: [on_open: term(), fallback: (-> term())]
        ) :: term()
  def run(name, func, opts \\ []) do
    case acquire(name) do
      {:ok, state_counter} ->
        %{classify: {classify_value, classify_exception}} = fetch_config!(name)

        try do
          func.()
        catch
          kind, reason ->
            release(name, classify_exception.(kind, reason), state_counter)
            :erlang.raise(kind, reason, __STACKTRACE__)
        else
          result ->
            release(name, classify_value.(result), state_counter)
            result
        end

      {:error, :circuit_open} ->
        rejected(opts)
    end
  end

  @doc false
  def wrap_run(func, {_mod, _name, _args}, opts) do
    {breaker_name, breaker_opts} = Keyword.pop!(opts, :name)
    run(breaker_name, func, breaker_opts)
  end

  defp rejected(opts) do
    case Keyword.fetch(opts, :fallback) do
      {:ok, fallback} when is_function(fallback, 0) -> fallback.()
      :error -> Keyword.get(opts, :on_open, {:error, :circuit_open})
    end
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
        {state_counter, _status} = unpack(:atomics.get(ref, @state))
        :ok = :atomics.put(ref, @state, pack(state_counter + 1, @open))
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :unknown_breaker}, state}
    end
  end

  @impl true
  def handle_call({:close, name}, _from, state) do
    case Map.fetch(state, name) do
      {:ok, %{ref: ref, strategy: {strategy, strategy_state}}} ->
        {state_counter, _status} = unpack(:atomics.get(ref, @state))
        :ok = :atomics.put(ref, @state, pack(state_counter + 1, @closed))
        :ok = strategy.reset(strategy_state)
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :unknown_breaker}, state}
    end
  end

  @impl true
  def handle_info({:half_open, name, status, state_counter}, state) do
    %{ref: ref} = Map.fetch!(state, name)

    case status do
      :probing ->
        :atomics.compare_exchange(
          ref,
          @state,
          pack(state_counter, @probing),
          pack(state_counter + 1, @half_open)
        )

      :open ->
        :atomics.compare_exchange(
          ref,
          @state,
          pack(state_counter, @open),
          pack(state_counter + 1, @half_open)
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:release, name, {_from, to} = transition, state_counter}, state) do
    %{recover: {recover, recover_state}} = config = Map.fetch!(state, name)
    {timeout, recover_state} = recover.timeout(transition, recover_state)

    Process.send_after(self(), {:half_open, name, to, state_counter}, timeout)

    {:noreply, Map.put(state, name, %{config | recover: {recover, recover_state}})}
  end

  defp install(name, module, opts) do
    key = {__MODULE__, name}

    {strategy, strategy_opts} = opts[:strategy]
    {recover, recover_opts} = opts[:recover]

    classify = Keyword.get(opts, :classify_with, :classify)

    config = %{
      module: module,
      strategy: {strategy, init_setting!(name, :strategy, strategy, strategy_opts)},
      recover: {recover, init_setting!(name, :recover, recover, recover_opts)},
      classify: {
        Rexsilient.Options.classifier(module, classify, 1),
        Rexsilient.Options.classifier(module, classify, 2)
      }
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
        {state_counter, _} = unpack(:atomics.get(ref, @state))
        :ok = :atomics.put(ref, @state, pack(state_counter + 1, @closed))
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
