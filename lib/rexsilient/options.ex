defmodule Rexsilient.Options do
  @moduledoc """
  Validates the options given to strategies and recover modules.

  The built-in modules use it in their `init/1`, and custom ones can too, so
  that invalid options fail the same way: with an `ArgumentError` that
  Rexsilient raises again with the declaration's name.

      @impl true
      def init(opts) do
        Rexsilient.Options.validate!(opts, delay: :non_neg_integer, budget: :pos_integer)
      end

  """

  @typedoc """
  The type an option must have:

    * `:pos_integer` - an integer greater than `0`.

    * `:non_neg_integer` - an integer greater than or equal to `0`.

  """
  @type type :: :pos_integer | :non_neg_integer

  @doc """
  Validates `opts` against `spec`, a keyword list of `key: type`.

  Every key in `spec` is required, and keys not in `spec` are rejected.
  Returns the options as a map. Raises `ArgumentError` otherwise.

  ## Examples

      Rexsilient.Options.validate!([threshold: 5], threshold: :pos_integer)
      #=> %{threshold: 5}

      Rexsilient.Options.validate!([threshold: 0], threshold: :pos_integer)
      ** (ArgumentError) threshold must be a positive integer, got: 0

  """
  @spec validate!(opts :: term(), spec :: [{atom(), type()}]) :: %{atom() => term()}
  def validate!(opts, spec) do
    if !Keyword.keyword?(opts),
      do: raise(ArgumentError, "options must be a keyword list, got: #{inspect(opts)}")

    opts = Keyword.validate!(opts, Keyword.keys(spec))

    for {key, type} <- spec, into: %{}, do: {key, fetch!(opts, key, type)}
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
