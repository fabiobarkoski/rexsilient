defmodule Rexsilient.Utils do
  @moduledoc false

  @type type :: :pos_integer | :non_neg_integer

  @doc """
  Validates `opts` against `spec`, a keyword list of `key: type`.

  Every key in `spec` is required, and keys not in `spec` are rejected.
  Returns the options as a map. Raises `ArgumentError` otherwise.
  """
  @spec validate!(opts :: term(), spec :: [{atom(), type()}]) :: %{atom() => term()}
  def validate!(opts, spec) do
    if !Keyword.keyword?(opts),
      do: raise(ArgumentError, "options must be a keyword list, got: #{inspect(opts)}")

    opts = Keyword.validate!(opts, Keyword.keys(spec))

    for {key, type} <- spec, into: %{}, do: {key, fetch!(opts, key, type)}
  end

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

  defp valid?(:pos_integer, value), do: is_integer(value) and value > 0
  defp valid?(:non_neg_integer, value), do: is_integer(value) and value >= 0

  defp describe(:pos_integer), do: "a positive integer"
  defp describe(:non_neg_integer), do: "a non-negative integer"

  defp fetch!(opts, key, type) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        if !valid?(type, value),
          do: raise(ArgumentError, "#{key} must be #{describe(type)}, got: #{inspect(value)}")

        value

      :error ->
        raise ArgumentError, "#{key} is required"
    end
  end
end
