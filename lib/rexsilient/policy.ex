defmodule Rexsilient.Policy do
  @moduledoc false

  @layers [
    circuit_breaker: {Rexsilient.CircuitBreaker, :circuit_breakers, "circuit breaker"},
    retry: {Rexsilient.Retry, :retries, "retry"},
    fallback: {Rexsilient.Fallback, :fallbacks, "fallback"}
  ]

  @doc false
  def wrap_run(func, context, opts) do
    name = Keyword.fetch!(opts, :name)

    fetch_config!(name)
    |> Enum.reduce(func, fn {mod, layer_name}, inner ->
      fn -> mod.wrap_run(inner, context, name: layer_name) end
    end)
    |> then(& &1.())
  end

  @doc false
  def __install__(modules) do
    declared =
      for {_key, {_mod, kind, _label}} <- @layers, into: %{} do
        {kind,
         MapSet.new(for mod <- modules, config <- mod.__rexsilient__(kind), do: config[:name])}
      end

    policies =
      for mod <- modules,
          config <- mod.__rexsilient__(:policies),
          reduce: %{} do
        acc ->
          name = Keyword.fetch!(config, :name)

          if Map.has_key?(acc, name),
            do: raise(ArgumentError, "policy #{inspect(name)} already exists")

          Map.put(acc, name, build(name, config, declared))
      end

    for {name, layers} <- policies do
      :persistent_term.put({__MODULE__, name}, layers)
    end

    :ok
  end

  defp build(name, config, declared) do
    for {key, {mod, kind, label}} <- @layers,
        layer_name = Keyword.get(config, key) do
      if layer_name not in declared[kind] do
        raise ArgumentError,
              "policy #{inspect(name)}: unknown #{label} #{inspect(layer_name)}"
      end

      {mod, layer_name}
    end
  end

  defp fetch_config!(name) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> raise ArgumentError, "unknown policy #{inspect(name)}"
      layers -> layers
    end
  end
end
