# Rexsilient

Rexsilient is a resilience toolkit for Elixir. It provides patterns such as
circuit breakers that let an application handle failing dependencies
gracefully, instead of waiting on them or making them worse.

Rexsilient is in early development. The circuit breaker is the first pattern
available; the API may change before the first stable release.

## Installation

Add `:rexsilient` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rexsilient, "~> 0.1"}
  ]
end
```

## Example

Breakers are declared in a module that uses `Rexsilient`:

```elixir
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
```

The breaker manager is added to your supervision tree, before the processes
that use the breakers:

```elixir
children = [
  {Rexsilient.CircuitBreaker, modules: [MyApp.Breakers]},
  MyAppWeb.Endpoint
]
```

Calls to the dependency then go through the breaker:

```elixir
alias Rexsilient.CircuitBreaker

case CircuitBreaker.run(:payments, fn -> Payments.charge(order) end) do
  {:ok, receipt} -> {:ok, receipt}
  {:error, :circuit_open} -> {:error, :payments_unavailable}
  {:error, reason} -> {:error, reason}
end
```

## Usage

### Circuit breaker

A circuit breaker watches the calls made to a dependency. When its `strategy`
decides there were too many failures, it *opens*: calls are rejected
immediately, without reaching the dependency. After the wait set by its
`recover` module, it lets a single call through as a *probe*. If the probe
succeeds, the breaker closes and traffic resumes. If it fails, the breaker
opens again. If it takes too long, also set by the `recover` module, another
call is let through as the probe and the slow one's result is ignored.

Built-in strategies and recovery modules:

| Setting | Module | Behaviour |
|:--------|:-------|:----------|
| `strategy` | `Strategy.Count` | Opens after `threshold` failures since the breaker last closed |
| `strategy` | `Strategy.SlidingWindow` | Opens after `threshold` failures within `window` milliseconds |
| `recover` | `Recover.BasicTimeout` | Stays open for `reset_timeout` milliseconds; gives a probe `probing_timeout` milliseconds |

`run/3` returns the function's result unchanged. When the breaker is open, it
returns `{:error, :circuit_open}` and the function is not called. The rejection
value can be changed:

```elixir
CircuitBreaker.run(:payments, fun, on_open: {:error, :unavailable})
```

To compute another result instead, such as a cached value, wrap the call in a
fallback, which always replaces `{:error, :circuit_open}`.

A call counts as a failure when the function returns `:error` or
`{:error, _}`, or when it raises, throws or exits. Exceptions are re-raised
unchanged after being recorded, so the breaker is transparent to the caller.
Every other return value counts as a success.

The breaker's state can be inspected with `status/1`:

```elixir
CircuitBreaker.status(:payments)
#=> :closed | :open | :half_open | :probing
```

### Combining patterns

Fallback, retry and circuit breaker can protect the same call. Combined, they
nest in a fixed order: the fallback outside, the retry in the middle and the
breaker inside, next to the call.

```
fallback( retry( circuit_breaker( call ) ) )
```

- Every attempt goes through the breaker, so it counts each real failure.
- The retry stops as soon as the breaker is open, instead of waiting on it.
- The fallback sees the final outcome, the last failure or the breaker's
  rejection, and replaces it.

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
breaker with no retry. Names that are not declared raise an error when
`Rexsilient` starts.

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
    CircuitBreaker.run(:prices, fn -> Prices.fetch(sku) end)
  end)
end, sku)
```

#### Other orders

The fixed order fits most cases. A few need another one, for example:

- A breaker outside the retry, so that it counts a whole retry sequence as one
  call and opens only on calls that still fail after every attempt.
- The same pattern twice, such as a breaker per host inside a breaker for the
  whole service.

For these, nest the calls in the order you need:

```elixir
CircuitBreaker.run(:prices, fn ->
  Retry.run(:prices, fn -> Prices.fetch(sku) end)
end)
```

or, with decorators, decorate one function per layer, each calling the next:

```elixir
@circuit_breaker :prices
def fetch(sku), do: fetch_with_retry(sku)

@doc false
@retry :prices
def fetch_with_retry(sku), do: PricesClient.fetch(sku)
```

Decorated functions must be public, so calling the inner one directly skips
the outer layer.

### Design

Checking a breaker is a single atomic read in the calling process, with no
message to any process, so it scales with the number of schedulers. A single
manager process owns timers and state changes for every breaker. If it
crashes, it restarts every breaker closed, so a failure of the breaker itself
never blocks traffic.

### Patterns

| Pattern | Purpose | Status |
|:--------|:--------|:-------|
| Circuit breaker | Stop calling a dependency that keeps failing | In development |
| Fallback | Provide an alternative result when a call fails | In development |
| Retry | Retry transient failures, with backoff | In development |
| Timeout | Give up on calls that take too long | Planned |
| Bulkhead | Limit concurrent calls to a dependency | Planned |
| Rate limiter | Limit how often a dependency is called | Planned |

## Running tests

```bash
$ mix deps.get
$ mix test
```
