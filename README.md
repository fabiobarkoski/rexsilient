# Rexsilient

Rexsilient is a resilience toolkit for Elixir, inspired by
[Polly](https://thepollyproject.org/about.html) and
[Hystrix](https://github.com/Netflix/Hystrix/wiki). Like them, it gives
applications the patterns to stay up when the services they depend on fail
or slow down.

OTP supervisors take care of your processes when they crash. Rexsilient
complements them for the calls to dependencies outside your supervision
tree, such as databases, APIs and other services.

| Pattern | Purpose | Status |
|:--------|:--------|:-------|
| Circuit breaker | Stop calling a dependency that keeps failing | Available |
| Retry | Retry transient failures, with backoff | Available |
| Fallback | Provide an alternative result when a call fails | Available |
| Timeout | Give up on calls that take too long | Planned |
| Bulkhead | Limit concurrent calls to a dependency | Planned |

Read the [full documentation](https://rexsilient.hexdocs.pm/readme.html) on hexdocs.pm.

## Installation

Add `:rexsilient` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rexsilient, "~> 1.0"}
  ]
end
```

## Getting started

Patterns are declared in a module that uses `Rexsilient`. A module may
declare as many as needed, of any kind:

```elixir
defmodule MyApp.Resilience do
  use Rexsilient

  alias Rexsilient.CircuitBreaker.{Recover, Strategy}

  circuit_breaker :payments do
    strategy Strategy.Count, threshold: 5
    recover Recover.BasicTimeout,
      reset_timeout: :timer.seconds(30),
      probing_timeout: :timer.seconds(10)
  end
end
```

`Rexsilient` is added to your supervision tree with every module that declares
patterns, before the processes that use them:

```elixir
children = [
  {Rexsilient, modules: [MyApp.Resilience]},
  MyAppWeb.Endpoint
]
```

Functions that call the dependency are then annotated with the circuit
breaker:

```elixir
defmodule MyApp.Payments do
  use Rexsilient.Decorator

  @circuit_breaker :payments
  def charge(order) do
    PaymentsClient.charge(order)
  end
end
```

Every call to `MyApp.Payments.charge/1` now goes through the circuit breaker.
While it is open, it returns `{:error, :circuit_open}` without calling the
dependency.

## Usage

### Circuit breaker

A circuit breaker watches the calls made to a dependency. When its `strategy`
decides there were too many failures, it *opens*: calls are rejected
immediately, without reaching the dependency. After the wait set by its
`recover` module, it lets a single call through as a *probe*. If the probe
succeeds, the circuit breaker closes and traffic resumes. If it fails, the
circuit breaker opens again. If it takes too long, also set by the `recover`
module, another call is let through as the probe and the slow one's result is
ignored.

Built-in strategies and recovery modules:

| Setting | Module | Behaviour |
|:--------|:-------|:----------|
| `strategy` | `Strategy.Count` | Opens after `threshold` failures since the circuit breaker last closed |
| `strategy` | `Strategy.SlidingWindow` | Opens after `threshold` failures within `window` milliseconds |
| `recover` | `Recover.BasicTimeout` | Stays open for `reset_timeout` milliseconds; gives a probe `probing_timeout` milliseconds |

The easiest way to use it is the `@circuit_breaker` decorator, as in
[Getting started](#getting-started). Without a decorator, a call goes through
the circuit breaker with `run/3`:

```elixir
alias Rexsilient.CircuitBreaker

case CircuitBreaker.run(:payments, fn -> PaymentsClient.charge(order) end) do
  {:ok, receipt} -> {:ok, receipt}
  {:error, :circuit_open} -> {:error, :payments_unavailable}
  {:error, reason} -> {:error, reason}
end
```

`run/3` returns the function's result unchanged, and re-raises its exceptions
unchanged after recording them, so the circuit breaker is transparent to the
caller. When the circuit breaker is open, it returns `{:error, :circuit_open}`
and the function is not called. The rejection value can be changed:

```elixir
CircuitBreaker.run(:payments, fun, on_open: {:error, :unavailable})
```

To compute another result instead, such as a cached value, wrap the call in a
fallback, which always replaces `{:error, :circuit_open}`.

What counts as a failure is set by the module that declares the circuit
breaker; see [Classifying failures](#classifying-failures).

The circuit breaker's state can be inspected with `status/1`:

```elixir
CircuitBreaker.status(:payments)
#=> :closed | :open | :half_open | :probing
```

Operators can force a circuit breaker open, for example while the dependency
is under maintenance, and close it again:

```elixir
CircuitBreaker.force_open(:payments)
CircuitBreaker.force_close(:payments)
```

A forced-open circuit breaker rejects every call until `force_close/1`; no
probe is let through.

Checking a circuit breaker is a single atomic read in the calling process,
with no message to any process, so it scales with the number of schedulers.
A single manager process owns timers and state changes for every circuit
breaker. If it crashes, it restarts every circuit breaker closed, so a failure
of the circuit breaker itself never blocks traffic.

### Retry

A retry calls a function again when it fails, waiting between attempts as its
`strategy` decides:

```elixir
retry :payments do
  attempts 4
  strategy Rexsilient.Retry.Strategy.Exponential,
    base_delay: 100,
    max_delay: 5_000,
    jitter: :full
end
```

The easiest way to use it is the `@retry` decorator:

```elixir
defmodule MyApp.Payments do
  use Rexsilient.Decorator

  @retry :payments
  def charge(order) do
    PaymentsClient.charge(order)
  end
end
```

Without a decorator, a call is retried with `run/2`:

```elixir
Rexsilient.Retry.run(:payments, fn -> PaymentsClient.charge(order) end)
```

`attempts` is the total number of calls, the first one included, or
`:infinity` to leave the limit to the strategy. A retry runs entirely in the
calling process, which sleeps between attempts. When no attempts remain, or the strategy stops, the last outcome is
returned unchanged: the value the function returned, or what it raised, threw
or exited with, re-raised with its original stacktrace.

Built-in strategies:

| Module | Behaviour |
|:-------|:----------|
| `Strategy.Constant` | Waits `delay` milliseconds before every attempt |
| `Strategy.Exponential` | Doubles the wait from `base_delay` up to `max_delay`; `jitter: :full` or `:equal` randomizes it |
| `Strategy.Decorrelated` | Waits a random time from `base_delay` to three times the previous wait, up to `max_delay` |

`{:error, :circuit_open}` is never retried: a circuit breaker just said the
dependency is down, and retrying would only wait for the same answer.

### Fallback

A fallback replaces the outcome of a failed call with the result of another
function:

```elixir
fallback :prices do
  function :cached_price
end

def cached_price(sku), do: Cache.last_price(sku)
```

The easiest way to use it is the `@fallback` decorator. The fallback function
is called with the decorated function's arguments:

```elixir
defmodule MyApp.Prices do
  use Rexsilient.Decorator

  @fallback :prices
  def fetch(sku) do
    PricesClient.fetch(sku)
  end
end
```

Without a decorator, a call goes through the fallback with `run/3`, whose
third argument is passed to both functions; use a list or a tuple to pass
several values:

```elixir
Rexsilient.Fallback.run(:prices, fn sku -> PricesClient.fetch(sku) end, sku)
```

`function` names a function of the declaring module, or `{module, name}` for
one in another module. A raise, throw or exit counted as a failure is
replaced too, not re-raised.

`{:error, :circuit_open}` is always replaced, so a fallback around a circuit
breaker answers while the circuit breaker is open. An error raised by the
fallback function itself propagates to the caller. A fallback runs entirely
in the calling process.

### Decorators

`@circuit_breaker`, `@retry` and `@fallback` are available in any module that
has `use Rexsilient.Decorator`. Options for `CircuitBreaker.run/3` go in a
keyword list with the name under `:name`:

```elixir
@circuit_breaker name: :payments, on_open: {:error, :unavailable}
```

Only public functions can be decorated, and the attribute applies to every
clause of that name and arity. See `Rexsilient.Decorator` for the details.

### Classifying failures

By default, a call fails when the function returns `:error` or `{:error, _}`,
or when it raises, throws or exits. Every other return value counts as a
success. This applies to circuit breakers, retries and fallbacks alike.

To change it, override `classify/1`, for returned values, and `classify/2`,
for raises, throws and exits, in the module that declares the patterns:

```elixir
@impl true
def classify({:error, %{status: status}}) when status >= 500, do: :failure
def classify(_), do: :success
```

The two are independent: overriding `classify/1` keeps the default
`classify/2`, so exceptions still count as failures.

To classify one declaration differently from the others in the same module,
name other functions with `classify_with`:

```elixir
circuit_breaker :search do
  strategy Rexsilient.CircuitBreaker.Strategy.Count, threshold: 10
  recover Rexsilient.CircuitBreaker.Recover.BasicTimeout,
    reset_timeout: :timer.seconds(5),
    probing_timeout: :timer.seconds(2)
  classify_with :classify_search
end

def classify_search({:error, :not_found}), do: :success
def classify_search(result), do: classify(result)
```

A missing `classify_search/2` falls back to `classify/2`. See
`Rexsilient.Classify`.

### Combining patterns

Fallback, retry and circuit breaker can protect the same call. Combined, they
nest in a fixed order: the fallback outside, the retry in the middle and the
circuit breaker inside, next to the call.

```
fallback( retry( circuit_breaker( call ) ) )
```

- Every attempt goes through the circuit breaker, so it counts each real
  failure.
- The retry stops as soon as the circuit breaker is open, instead of waiting
  on it.
- The fallback sees the final outcome, the last failure or the circuit
  breaker's rejection, and replaces it.

Each pattern keeps its own declaration and classifier. Patterns of different
kinds can share a name. A `policy` groups them under one name, referencing
each declaration by its name:

```elixir
defmodule MyApp.Resilience do
  use Rexsilient

  alias Rexsilient.CircuitBreaker.{Recover, Strategy}
  alias Rexsilient.Retry

  fallback :prices do
    function :cached_price
  end

  retry :prices do
    attempts 3
    strategy Retry.Strategy.Exponential, base_delay: 100, max_delay: 2_000, jitter: :full
  end

  circuit_breaker :prices do
    strategy Strategy.Count, threshold: 5
    recover Recover.BasicTimeout,
      reset_timeout: :timer.seconds(30),
      probing_timeout: :timer.seconds(10)
  end

  policy :prices do
    fallback :prices
    retry :prices
    circuit_breaker :prices
  end

  def cached_price(sku), do: Cache.last_price(sku)
end
```

The policy is then used with `@policy` from `Rexsilient.Decorator`:

```elixir
defmodule MyApp.Prices do
  use Rexsilient.Decorator

  @policy :prices
  def fetch(sku) do
    PricesClient.fetch(sku)
  end
end
```

Any entry of a policy can be left out, for example a fallback around a
circuit breaker with no retry. Names that are not declared raise an error
when `Rexsilient` starts.

Without a policy, the same result comes from stacking the decorators, which
nest in the same order whatever the order they are written in:

```elixir
@fallback :prices
@retry :prices
@circuit_breaker :prices
def fetch(sku) do
  PricesClient.fetch(sku)
end
```

or from nesting the calls:

```elixir
alias Rexsilient.{CircuitBreaker, Fallback, Retry}

Fallback.run(:prices, fn sku ->
  Retry.run(:prices, fn ->
    CircuitBreaker.run(:prices, fn -> PricesClient.fetch(sku) end)
  end)
end, sku)
```

#### Other orders

The fixed order fits most cases. A few need another one, for example:

- A circuit breaker outside the retry, so that it counts a whole retry
  sequence as one call and opens only on calls that still fail after every
  attempt.
- The same pattern twice, such as a circuit breaker per host inside a circuit
  breaker for the whole service.

For these, decorate one function per layer, each calling the next:

```elixir
@circuit_breaker :prices
def fetch(sku), do: fetch_with_retry(sku)

@doc false
@retry :prices
def fetch_with_retry(sku), do: PricesClient.fetch(sku)
```

> #### Inner layers are public {: .warning}
>
> Decorated functions must be public, so calling the inner one directly skips
> the outer layer.

or nest the calls in the order you need:

```elixir
CircuitBreaker.run(:prices, fn ->
  Retry.run(:prices, fn -> PricesClient.fetch(sku) end)
end)
```

### Notifications

Rexsilient tells *notifiers* what the patterns are doing: every call, and
every change of state. A notifier is a module that implements
`Rexsilient.Notifier`, listed in the `:notifiers` option of `Rexsilient`.
The default is `[Rexsilient.Notifier.TelemetryNotifier]`; listing other
notifiers replaces it, so include it to keep it.

Each notification has a moment, the pattern that sends it, and a state map
with its `:name`:

| Pattern | Moments |
|:--------|:--------|
| Circuit breaker | `:before` and `:after` a call, `:rejected`, and `:open`, `:half_open`, `:probing` and `:closed` when it changes state |
| Retry | `:before` and `:after` each attempt, `:delay` before waiting, and `:stop` when no attempt follows |
| Fallback | `:before` and `:after` the fallback function |

See `Rexsilient.Notifier` for the state of each moment. Notifiers other than
`TelemetryNotifier` are called by a single notifier process, so the call being
notified never waits for them.

Notifying has a cost even when nothing listens, so pass `notifiers: []` to
turn it off:

```elixir
{Rexsilient, modules: [MyApp.Resilience], notifiers: []}
```

#### Telemetry

`Rexsilient.Notifier.TelemetryNotifier`, the default notifier, emits every
notification as a `:telemetry` event named `[:rexsilient, kind, event]`,
where `kind` is `:circuit_breaker`, `:retry` or `:fallback`. Unlike other
notifiers, it runs in the calling process, so handlers see the caller's
context and must be fast.

```elixir
:telemetry.attach(
  "log-open-circuit-breakers",
  [:rexsilient, :circuit_breaker, :open],
  fn _event, _measurements, %{name: name, from: from}, _config ->
    Logger.warning("circuit breaker #{inspect(name)} opened from #{from}")
  end,
  nil
)
```

Events follow the `:telemetry.span/3` conventions: `:before` is emitted as
`:start` and `:after` as `:stop`, and the retry's `:stop` moment as
`:give_up`. Numeric values are measurements, and the rest is metadata:

`[:rexsilient, :circuit_breaker, event]`:

| Event | Measurements | Metadata |
|:------|:-------------|:---------|
| `:start` | `monotonic_time`, `system_time` | `name` |
| `:stop` | `monotonic_time`, `duration` | `name`, `result`, `outcome` |
| `:rejected` | `system_time` | `name` |
| `:open` | `system_time`, `timeout` | `name`, `from`, `outcome`, `forced`¹ |
| `:half_open` | `system_time` | `name`, `from` |
| `:probing` | `system_time`, `timeout` | `name`, `from`, `outcome` |
| `:closed` | `system_time` | `name`, `from`, `forced`¹, `restart`¹ |

¹ Only present when the change was forced with `force_open/1` or
`force_close/1`, or caused by a manager restart. A forced `:open` has
`timeout: :infinity`, in the metadata.

`[:rexsilient, :retry, event]`:

| Event | Measurements | Metadata |
|:------|:-------------|:---------|
| `:start` | `monotonic_time`, `system_time` | `name`, `attempt` |
| `:stop` | `monotonic_time`, `duration` | `name`, `attempt`, `result`, `outcome` |
| `:delay` | `delay` | `name`, `attempt`, `outcome` |
| `:give_up` | `duration` | `name`, `attempt`, `outcome`, `reason` |

`[:rexsilient, :fallback, event]`:

| Event | Measurements | Metadata |
|:------|:-------------|:---------|
| `:start` | `monotonic_time`, `system_time` | `name`, `outcome` (the one replaced) |
| `:stop` | `monotonic_time`, `duration` | `name`, `outcome` |

Times and `duration` are in native time units, `delay` and `timeout` in
milliseconds. `result` is `:success` or `:failure`, and `outcome` is
`{:value, value}` or `{kind, reason}`.

## Running tests

```bash
$ mix deps.get
$ mix test
```

## License

Rexsilient is released under the MIT License; see [LICENSE](https://github.com/fabiobarkoski/rexsilient/blob/main/LICENSE).
