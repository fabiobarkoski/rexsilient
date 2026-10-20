defmodule Rexsilient.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    modules = Keyword.fetch!(opts, :modules)

    # Fallbacks and retries have no runtime state, so they are installed here
    # instead of in a process of their own.
    :ok = Rexsilient.Fallback.__install__(modules)
    :ok = Rexsilient.Retry.__install__(modules)
    :ok = Rexsilient.Policy.__install__(modules)

    children = [
      {Rexsilient.CircuitBreaker, modules: modules}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
