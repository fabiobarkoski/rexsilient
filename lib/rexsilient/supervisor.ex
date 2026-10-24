defmodule Rexsilient.Supervisor do
  @moduledoc false

  alias Rexsilient.Notifier.TelemetryNotifier

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    modules = Keyword.fetch!(opts, :modules)

    :ok = Rexsilient.Fallback.__install__(modules)
    :ok = Rexsilient.Retry.__install__(modules)
    :ok = Rexsilient.Policy.__install__(modules)

    children = [
      {Task.Supervisor, name: Rexsilient.Notifier.TaskSupervisor},
      {Rexsilient.Notifier, notifiers: Keyword.get(opts, :notifiers, [TelemetryNotifier])},
      {Rexsilient.CircuitBreaker, modules: modules}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
