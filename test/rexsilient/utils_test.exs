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
end
