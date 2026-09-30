defmodule Rexsilient.DecoratorTest.Breakers do
  use Rexsilient

  circuit_breaker :decorated do
    timeout 50
    threshold 2
  end
end

defmodule Rexsilient.DecoratorTest.Client do
  use Rexsilient.Decorator

  @circuit_breaker :decorated
  def call(result), do: result

  @circuit_breaker :decorated
  def invoke(fun), do: fun.()

  def plain(result), do: result

  @circuit_breaker :decorated
  def classify(:ok), do: {:ok, :first_clause}
  def classify(:error), do: {:error, :second_clause}

  @circuit_breaker name: :decorated, on_open: {:error, :unavailable}
  def with_on_open(result), do: result

  @circuit_breaker name: :decorated, fallback: &__MODULE__.cached/0
  def with_fallback(result), do: result

  def cached, do: :cached

  @circuit_breaker :decorated
  def countdown(0), do: {:error, :done}
  def countdown(n), do: countdown(n - 1)

  @circuit_breaker :decorated
  def with_default(result, _extra \\ nil), do: result

  @circuit_breaker false
  def disabled(result), do: result
end

defmodule Rexsilient.DecoratorTest do
  # The manager is a named singleton and breakers live in :persistent_term, so
  # these tests cannot run concurrently with the circuit breaker tests.
  use ExUnit.Case, async: false

  alias Rexsilient.CircuitBreaker, as: CB
  alias Rexsilient.DecoratorTest.Client

  @name :decorated

  setup do
    start_supervised!({CB, modules: [Rexsilient.DecoratorTest.Breakers]})
    :ok
  end

  # Releases are casts; a call from this process is handled after them.
  defp sync, do: :sys.get_state(CB)

  defp trip! do
    for _ <- 1..2, do: Client.call({:error, :boom})
    sync()
    assert CB.status(@name) == :open
  end

  # Every module is compiled inside its test, so a broken decorator fails that
  # test instead of the whole file.
  defp compile!(body) do
    mod = Module.concat(__MODULE__, "M#{System.unique_integer([:positive])}")

    quoted =
      quote do
        defmodule unquote(mod) do
          use Rexsilient.Decorator
          unquote(body)
        end
      end

    Code.eval_quoted(quoted, [], file: __ENV__.file)
    mod
  end

  # Mistakes must be a CompileError blaming the user's file, not an exception
  # raised from inside lib/rexsilient/decorator.ex.
  defp assert_decorator_error(body, message) do
    err = assert_raise CompileError, message, fn -> compile!(body) end
    assert err.file == __ENV__.file
  end

  describe "decorated functions" do
    test "return the function's result unchanged" do
      for value <- [{:ok, 1}, :ok, 42, {:error, :boom}, :error] do
        assert Client.call(value) == value
      end
    end

    test "count failures and open the breaker" do
      trip!()
    end

    test "are rejected while the breaker is open" do
      trip!()
      assert Client.call(:ok) == {:error, :circuit_open}
    end

    test "raise and throw are re-raised unchanged and count as failures" do
      assert_raise RuntimeError, "boom", fn -> Client.invoke(fn -> raise "boom" end) end
      assert catch_throw(Client.invoke(fn -> throw(:ball) end)) == :ball
      sync()
      assert CB.status(@name) == :open
    end

    test "exit is re-raised unchanged and counts as a failure" do
      assert catch_exit(Client.invoke(fn -> exit(:bye) end)) == :bye
      assert catch_exit(Client.invoke(fn -> exit(:bye) end)) == :bye
      sync()
      assert CB.status(@name) == :open
    end

    test "every clause goes through the breaker" do
      assert Client.classify(:ok) == {:ok, :first_clause}
      assert Client.classify(:error) == {:error, :second_clause}
      assert Client.classify(:error) == {:error, :second_clause}
      sync()
      assert CB.status(@name) == :open
      assert Client.classify(:ok) == {:error, :circuit_open}
    end

    test "recursive calls go through the breaker too" do
      assert Client.countdown(1) == {:error, :done}
      sync()
      assert CB.status(@name) == :open
    end

    test "calls through a default argument go through the breaker" do
      Client.with_default({:error, :boom})
      Client.with_default({:error, :boom})
      sync()
      assert CB.status(@name) == :open
      assert Client.with_default(:ok) == {:error, :circuit_open}
    end
  end

  describe "undecorated functions" do
    test "a function after a decorated one is not wrapped" do
      for _ <- 1..3, do: Client.plain({:error, :boom})
      sync()
      assert CB.status(@name) == :closed

      trip!()
      assert Client.plain(:ok) == :ok
    end

    test "@circuit_breaker false leaves the function unwrapped" do
      trip!()
      assert Client.disabled(:ok) == :ok
    end
  end

  describe "options" do
    test "on_open: replaces the rejection value" do
      trip!()
      assert Client.with_on_open(:ok) == {:error, :unavailable}
    end

    test "fallback: is called on rejection" do
      trip!()
      assert Client.with_fallback(:ok) == :cached
    end

    test "a keyword list with :name behaves like the plain name" do
      assert Client.with_on_open({:error, :boom}) == {:error, :boom}
      assert Client.with_fallback({:error, :boom}) == {:error, :boom}
      sync()
      assert CB.status(@name) == :open
    end
  end

  describe "compile errors" do
    test "rejects defp" do
      assert_decorator_error(
        quote do
          @circuit_breaker :decorated
          defp hidden, do: :ok
        end,
        ~r/only supported on def, got defp hidden/
      )
    end

    test "rejects defmacro" do
      assert_decorator_error(
        quote do
          @circuit_breaker :decorated
          defmacro mac, do: :ok
        end,
        ~r/only supported on def, got defmacro mac/
      )
    end

    test "rejects an attribute not followed by a function" do
      assert_decorator_error(
        quote do
          def fun, do: :ok
          @circuit_breaker :decorated
        end,
        ~r/@circuit_breaker is not followed by a function definition/
      )
    end

    test "rejects a value that is neither an atom nor a keyword list" do
      assert_decorator_error(
        quote do
          @circuit_breaker "decorated"
          def fun, do: :ok
        end,
        ~r/@circuit_breaker on fun must be atom or a keyword list, got: "decorated"/
      )
    end
  end
end
