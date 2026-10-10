defmodule Rexsilient.DSLTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO, only: [with_io: 2]

  alias Rexsilient.CircuitBreaker.Recover.BasicTimeout
  alias Rexsilient.CircuitBreaker.Strategy.Count

  # Every module is compiled inside its test, so a broken macro fails that test
  # instead of the whole file. Unique names keep async runs from colliding.
  defp compile!(body) do
    mod = Module.concat(__MODULE__, "M#{System.unique_integer([:positive])}")

    quoted =
      quote do
        defmodule unquote(mod) do
          use Rexsilient
          unquote(body)
        end
      end

    Code.eval_quoted(quoted, [], file: __ENV__.file)
    mod
  end

  # DSL mistakes must be a CompileError blaming the user's file (ADR 0001, 5.10),
  # not an exception raised from inside lib/rexsilient.ex.
  defp assert_dsl_error(body, message) do
    err = assert_raise CompileError, message, fn -> compile!(body) end
    assert err.file == __ENV__.file
  end

  describe "declaring breakers" do
    test "collects one breaker" do
      mod =
        compile!(
          quote do
            circuit_breaker :payments do
              strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 3)
              recover(Rexsilient.CircuitBreaker.Recover.BasicTimeout, reset_timeout: 5_000)
            end
          end
        )

      assert mod.__rexsilient__(:circuit_breakers) == [
               [
                 recover: {BasicTimeout, [reset_timeout: 5_000]},
                 strategy: {Count, [threshold: 3]},
                 name: :payments
               ]
             ]
    end

    test "collects several breakers in declaration order" do
      mod =
        compile!(
          quote do
            circuit_breaker :payments do
              strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 3)
              recover(Rexsilient.CircuitBreaker.Recover.BasicTimeout, reset_timeout: 5_000)
            end

            circuit_breaker :search do
              recover(Rexsilient.CircuitBreaker.Recover.BasicTimeout, reset_timeout: 1_000)
              strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 10)
            end
          end
        )

      assert mod.__rexsilient__(:circuit_breakers) == [
               [
                 recover: {BasicTimeout, [reset_timeout: 5_000]},
                 strategy: {Count, [threshold: 3]},
                 name: :payments
               ],
               [
                 strategy: {Count, [threshold: 10]},
                 recover: {BasicTimeout, [reset_timeout: 1_000]},
                 name: :search
               ]
             ]
    end

    test "evaluates modules and options at compile time" do
      mod =
        compile!(
          quote do
            alias Rexsilient.CircuitBreaker.Recover.BasicTimeout
            alias Rexsilient.CircuitBreaker.Strategy.Count

            circuit_breaker :payments do
              strategy(Count, threshold: 2 + 1)
              recover(BasicTimeout, reset_timeout: :timer.seconds(5))
            end
          end
        )

      assert [config] = mod.__rexsilient__(:circuit_breakers)
      assert config[:strategy] == {Count, [threshold: 3]}
      assert config[:recover] == {BasicTimeout, [reset_timeout: 5_000]}
    end

    test "a module without breakers declares an empty list and warns" do
      {mod, warning} = with_io(:stderr, fn -> compile!(nil) end)

      assert mod.__rexsilient__(:circuit_breakers) == []
      assert warning =~ "#{inspect(mod)} uses Rexsilient but declares no circuit breakers"
    end
  end

  describe "invalid names" do
    test "rejects a string name" do
      assert_dsl_error(
        quote do
          circuit_breaker "payments" do
            strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 1)
            recover(Rexsilient.CircuitBreaker.Recover.BasicTimeout, reset_timeout: 1)
          end
        end,
        ~r/"payments"/
      )
    end
  end

  describe "missing settings" do
    test "rejects a breaker without strategy" do
      assert_dsl_error(
        quote do
          circuit_breaker :payments do
            recover(Rexsilient.CircuitBreaker.Recover.BasicTimeout, reset_timeout: 1)
          end
        end,
        ~r/Missing strategy/
      )
    end

    test "rejects a breaker without recover" do
      assert_dsl_error(
        quote do
          circuit_breaker :payments do
            strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 1)
          end
        end,
        ~r/Missing recover/
      )
    end
  end

  describe "settings outside a breaker" do
    test "rejects strategy outside circuit_breaker" do
      assert_dsl_error(
        quote do
          strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 1)
        end,
        ~r/strategy\/2 outside/
      )
    end

    test "rejects recover outside circuit_breaker" do
      assert_dsl_error(
        quote do
          recover(Rexsilient.CircuitBreaker.Recover.BasicTimeout, reset_timeout: 1)
        end,
        ~r/recover\/2 outside/
      )
    end
  end
end
