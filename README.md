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
# a fixed value
CircuitBreaker.run(:payments, fun, on_open: {:error, :unavailable})

# a function, called only when the call is rejected
CircuitBreaker.run(:prices, fn -> Prices.fetch(sku) end,
  fallback: fn -> Cache.last_price(sku) end
)
```

A call counts as a failure when the function returns `:error` or
`{:error, _}`, or when it raises, throws or exits. Exceptions are re-raised
unchanged after being recorded, so the breaker is transparent to the caller.
Every other return value counts as a success.

The breaker's state can be inspected with `status/1`:

```elixir
CircuitBreaker.status(:payments)
#=> :closed | :open | :half_open | :probing
```

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
| Fallback | Provide an alternative result when a call is rejected | Partial, through `fallback:` |
| Retry | Retry transient failures, with backoff | Planned |
| Timeout | Give up on calls that take too long | Planned |
| Bulkhead | Limit concurrent calls to a dependency | Planned |
| Rate limiter | Limit how often a dependency is called | Planned |

## Running tests

```bash
$ mix deps.get
$ mix test
```
