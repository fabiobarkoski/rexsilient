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

    * `:closed` - calls go through. Failures are counted, and the breaker
      opens when they reach its `threshold`.

    * `:open` - calls are rejected without reaching the dependency. After
      `timeout` milliseconds the breaker becomes half-open.

    * `:half_open` - the next call is let through as a *probe*, to test
      whether the dependency has recovered.

    * `:probing` - the probe is running. Every other call is rejected. If the
      probe succeeds, the breaker closes and its failure count is reset. If it
      fails, the breaker opens again for another `timeout`.

  Exactly one caller becomes the probe, even when many arrive at once.

  ## Failures

  A call counts as a failure when the function returns `:error` or
  `{:error, _}`, or when it raises, throws or exits. Every other return value
  counts as a success.

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
  @failures 2

  @closed 0
  @open 1
  @half_open 2
  @probing 3

  @state_mask (1 <<< 61) - 1

  @doc """
  Starts the breaker manager and registers the declared breakers.

  Usually started through a supervisor, as shown in the module documentation.
  Only one manager runs per node; it is registered under this module's name.

  ## Options

    * `:modules` - the modules that declare breakers with `Rexsilient`.
      Required. Raises `ArgumentError` if two breakers share a name.

  """
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
  def status(name) do
    ref = :persistent_term.get({__MODULE__, name})
    case unpack(:atomics.get(ref, @state)) do
      {_, @closed} -> :closed
      {_, @open} -> :open
      {_, @half_open} -> :half_open
      {_, @probing} -> :probing
    end
  end

  @doc false
  def release(name, result, state_counter) do
    GenServer.cast(__MODULE__, {:release, name, result, state_counter})
  end

  @doc false
  def acquire(name) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> raise ArgumentError, "Unknow circuit breaker #{inspect(name)}"
      ref when is_reference(ref) ->
        state_value = :atomics.get(ref, @state)
        {state_counter, status} = unpack(state_value)

        case status do
          @closed ->
            {:ok, state_counter &&& @state_mask}

          @half_open ->
            case :atomics.compare_exchange(ref, @state, state_value, pack(state_counter + 1, @probing)) do
              :ok -> {:ok, (state_counter + 1) &&& @state_mask}
              _ -> {:error, :circuit_open}
            end
          _ ->
            {:error, :circuit_open}
        end
    end
  end

  @doc """
  Calls `func` through the breaker `name`.

  If the breaker allows the call, `func` is invoked and its result is returned
  unchanged. The result is then recorded as a success or a failure (see
  [Failures](#module-failures)). If `func` raises, throws
  or exits, the failure is recorded and the error is re-raised unchanged.

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
  def run(name, func, opts \\ []) do
    case acquire(name) do
      {:ok, state_counter} ->
        try do
          func.()
        catch
          kind, reason ->
            release(name, :failure, state_counter)
            :erlang.raise(kind, reason, __STACKTRACE__)
        else
          result ->
            release(name, func_result(result), state_counter)
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

  defp func_result(:error), do: :failure
  defp func_result({:error, _}), do: :failure
  defp func_result(_), do: :success

  @impl true
  def init(opts) do
    breakers =
      for mod <- Keyword.fetch!(opts, :modules),
          config <- mod.__rexsilient__(:circuit_breakers),
          reduce: %{} do
        acc ->
          name = Keyword.fetch!(config, :name)

          if Map.has_key?(acc, name),
            do: raise(ArgumentError, "Circuit breaker #{inspect(name)} already exist")

          Map.put(acc, name, %{ref: install(config), config: config})
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
      :error -> {:reply, {:error, :unknown_breaker}, state}
    end
  end

  @impl true
  def handle_call({:close, name}, _from, state) do
    case Map.fetch(state, name) do
      {:ok, %{ref: ref}} ->
        {state_counter, _status} = unpack(:atomics.get(ref, @state))
        :ok = :atomics.put(ref, @state, pack(state_counter + 1, @closed))
        :ok = :atomics.put(ref, @failures, 0)
        {:reply, :ok, state}
      :error -> {:reply, {:error, :unknown_breaker}, state}
    end
  end

  @impl true
  def handle_info({:half_open, name, state_counter}, state) do
    %{ref: ref} = Map.fetch!(state, name)
    :atomics.compare_exchange(ref, @state, pack(state_counter, @open), pack(state_counter + 1, @half_open))

    {:noreply, state}
  end

  @impl true
  def handle_cast({:release, name, result, state_counter}, state) do
    %{ref: ref, config: config} = Map.fetch!(state, name)
    state_value = :atomics.get(ref, @state)

    case {unpack(state_value), result} do
      {{^state_counter, @probing}, :success} ->
        if :atomics.compare_exchange(ref, @state, state_value, pack(state_counter + 1, @closed)) == :ok,
          do: :atomics.put(ref, @failures, 0)
      {{^state_counter, @probing}, :failure} ->
        if :atomics.compare_exchange(ref, @state, state_value, pack(state_counter + 1, @open)) == :ok,
          do: Process.send_after(self(), {:half_open, name, state_counter + 1}, config[:timeout])
      {{^state_counter, @closed}, :failure} ->
        if :atomics.add_get(ref, @failures, 1) >= config[:threshold] and
             :atomics.compare_exchange(ref, @state, state_value, pack(state_counter + 1, @open)) == :ok,
          do:
          Process.send_after(self(), {:half_open, name, state_counter + 1}, config[:timeout])
      _ -> :ok
    end

    {:noreply, state}
  end

  defp install(config) do
    key = {__MODULE__, config[:name]}

    case :persistent_term.get(key, nil) do
      nil ->
        ref = :atomics.new(2, [])
        :ok = :atomics.put(ref, @state, pack(0, @closed))
        :ok = :atomics.put(ref, @failures, 0)
        :persistent_term.put(key, ref)
        ref

      ref ->
        {state_counter, _} = unpack(:atomics.get(ref, @state))
        :ok = :atomics.put(ref, @state, pack(state_counter + 1, @closed))
        :ok = :atomics.put(ref, @failures, 0)
        ref
    end
  end

  defp pack(state_counter, status) do
    (state_counter &&& @state_mask) <<< 2 ||| status
  end

  defp unpack(value) do
    {value >>> 2, value &&& 0b11}
  end
end
