defmodule Rexsilient.Utils do
  @moduledoc false

  @doc """
  Raises `ArgumentError` unless `module` is available and exports every
  required callback of `behaviour`. `owner` names the declaration in the
  message, such as `"circuit breaker :payments"`.
  """
  @spec implements!(module(), behaviour :: module(), owner :: String.t()) :: :ok
  def implements!(module, behaviour, owner) do
    if !Code.ensure_loaded?(module),
      do: raise(ArgumentError, "#{owner}: module #{inspect(module)} is not available")

    optional = behaviour.behaviour_info(:optional_callbacks)

    missing =
      for {name, arity} = callback <- behaviour.behaviour_info(:callbacks),
          callback not in optional,
          not function_exported?(module, name, arity),
          do: "#{name}/#{arity}"

    if missing != [] do
      raise ArgumentError,
            "#{owner}: #{inspect(module)} does not implement #{inspect(behaviour)} " <>
              "(missing #{Enum.join(missing, ", ")})"
    end

    :ok
  end
end
