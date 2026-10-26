defmodule Rexsilient.OptionsTest do
  use ExUnit.Case, async: true

  alias Rexsilient.Options

  @schema [count: :pos_integer, timeout: :non_neg_integer]

  test "returns the options as a map" do
    assert Options.validate!([count: 1, timeout: 0], @schema) == %{count: 1, timeout: 0}
  end

  test "a missing key raises" do
    assert_raise ArgumentError, "timeout is required", fn ->
      Options.validate!([count: 1], @schema)
    end
  end

  test "an unknown key raises" do
    assert_raise ArgumentError, ~r/unknown keys \[:timout\]/, fn ->
      Options.validate!([count: 1, timeout: 0, timout: 5], @schema)
    end
  end

  test "options that are not a keyword list raise" do
    assert_raise ArgumentError, "options must be a keyword list, got: %{count: 1}", fn ->
      Options.validate!(%{count: 1}, @schema)
    end
  end

  describe ":pos_integer" do
    test "rejects 0, negatives and non-integers" do
      for value <- [0, -1, 1.5, "5", nil] do
        assert_raise ArgumentError,
                     "count must be a positive integer, got: #{inspect(value)}",
                     fn -> Options.validate!([count: value, timeout: 0], @schema) end
      end
    end
  end

  describe ":non_neg_integer" do
    test "accepts 0 and rejects negatives and non-integers" do
      assert %{timeout: 0} = Options.validate!([count: 1, timeout: 0], @schema)

      for value <- [-1, 1.5, "30s", :infinity] do
        assert_raise ArgumentError,
                     "timeout must be a non-negative integer, got: #{inspect(value)}",
                     fn -> Options.validate!([count: 1, timeout: value], @schema) end
      end
    end
  end
end
