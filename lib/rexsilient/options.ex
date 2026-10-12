defmodule Rexsilient.Options do
  @moduledoc false

  def classifier(module, func, arity) do
    Function.capture(module, func, arity)
  end

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

    for {key, type} <- spec, into: %{} do
      case Keyword.fetch(opts, key) do
        {:ok, value} ->
          if !valid?(type, value),
            do: raise(ArgumentError, "#{key} must be #{describe(type)}, got: #{inspect(value)}")

          {key, value}

        :error ->
          raise ArgumentError, "#{key} is required"
      end
    end
  end

  defp valid?(:pos_integer, value), do: is_integer(value) and value > 0
  defp valid?(:non_neg_integer, value), do: is_integer(value) and value >= 0

  defp describe(:pos_integer), do: "a positive integer"
  defp describe(:non_neg_integer), do: "a non-negative integer"
end
