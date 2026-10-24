defmodule Rexsilient.UtilsTest.Behaviour do
  @callback required(term()) :: term()
  @callback other(term(), term()) :: term()
  @callback optional() :: term()
  @optional_callbacks optional: 0
end

defmodule Rexsilient.UtilsTest.Complete do
  @behaviour Rexsilient.UtilsTest.Behaviour
  def required(_), do: :ok
  def other(_, _), do: :ok
end

defmodule Rexsilient.UtilsTest.Partial do
  def required(_), do: :ok
end

defmodule Rexsilient.UtilsTest do
  use ExUnit.Case, async: true

  alias Rexsilient.Utils
  alias Rexsilient.UtilsTest.{Behaviour, Complete, Partial}

  describe "implements!/3" do
    test "accepts a module with every required callback, optional ones aside" do
      assert Utils.implements!(Complete, Behaviour, "owner") == :ok
    end

    test "names the owner and the missing callbacks" do
      assert_raise ArgumentError,
                   "owner: Rexsilient.UtilsTest.Partial does not implement " <>
                     "Rexsilient.UtilsTest.Behaviour (missing other/2)",
                   fn -> Utils.implements!(Partial, Behaviour, "owner") end
    end

    test "rejects a module that is not available" do
      assert_raise ArgumentError,
                   "owner: module Rexsilient.UtilsTest.Nope is not available",
                   fn -> Utils.implements!(Rexsilient.UtilsTest.Nope, Behaviour, "owner") end
    end
  end

  @schema [count: :pos_integer, timeout: :non_neg_integer]

  test "returns the options as a map" do
    assert Utils.validate!([count: 1, timeout: 0], @schema) == %{count: 1, timeout: 0}
  end

  test "a missing key raises" do
    assert_raise ArgumentError, "timeout is required", fn ->
      Utils.validate!([count: 1], @schema)
    end
  end

  test "an unknown key raises" do
    assert_raise ArgumentError, ~r/unknown keys \[:timout\]/, fn ->
      Utils.validate!([count: 1, timeout: 0, timout: 5], @schema)
    end
  end

  test "options that are not a keyword list raise" do
    assert_raise ArgumentError, "options must be a keyword list, got: %{count: 1}", fn ->
      Utils.validate!(%{count: 1}, @schema)
    end
  end

  describe ":pos_integer" do
    test "rejects 0, negatives and non-integers" do
      for value <- [0, -1, 1.5, "5", nil] do
        assert_raise ArgumentError,
                     "count must be a positive integer, got: #{inspect(value)}",
                     fn -> Utils.validate!([count: value, timeout: 0], @schema) end
      end
    end
  end

  describe ":non_neg_integer" do
    test "accepts 0 and rejects negatives and non-integers" do
      assert %{timeout: 0} = Utils.validate!([count: 1, timeout: 0], @schema)

      for value <- [-1, 1.5, "30s", :infinity] do
        assert_raise ArgumentError,
                     "timeout must be a non-negative integer, got: #{inspect(value)}",
                     fn -> Utils.validate!([count: 1, timeout: value], @schema) end
      end
    end
  end
end
