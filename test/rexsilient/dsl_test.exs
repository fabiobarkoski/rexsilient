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

    test "a module without declarations declares empty lists and warns" do
      {mod, warning} = with_io(:stderr, fn -> compile!(nil) end)

      assert mod.__rexsilient__(:circuit_breakers) == []
      assert mod.__rexsilient__(:fallbacks) == []
      assert warning =~ "#{inspect(mod)} uses Rexsilient but declares nothing"
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

    test "rejects nil and booleans" do
      for name <- [nil, true, false] do
        assert_dsl_error(
          quote do
            circuit_breaker unquote(name) do
              strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 1)
              recover(Rexsilient.CircuitBreaker.Recover.BasicTimeout, reset_timeout: 1)
            end
          end,
          ~r/name must be an atom, got: #{Regex.escape(inspect(name))}/
        )
      end
    end

    test "rejects a name declared twice in the same module" do
      assert_dsl_error(
        quote do
          circuit_breaker :payments do
            strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 1)
            recover(Rexsilient.CircuitBreaker.Recover.BasicTimeout, reset_timeout: 1)
          end

          circuit_breaker :payments do
            strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 2)
            recover(Rexsilient.CircuitBreaker.Recover.BasicTimeout, reset_timeout: 1)
          end
        end,
        ~r/circuit_breaker :payments is already declared in/
      )
    end
  end

  describe "strategy and recover modules" do
    test "reject a value that is not a module" do
      assert_dsl_error(
        quote do
          circuit_breaker :payments do
            strategy("Count", threshold: 1)
            recover(Rexsilient.CircuitBreaker.Recover.BasicTimeout, reset_timeout: 1)
          end
        end,
        ~r"strategy/2 needs a module, got: \"Count\""
      )

      assert_dsl_error(
        quote do
          circuit_breaker :payments do
            strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 1)
            recover(nil, reset_timeout: 1)
          end
        end,
        ~r"recover/2 needs a module, got: nil"
      )
    end
  end

  describe "repeated settings" do
    test "rejects a setting set twice" do
      assert_dsl_error(
        quote do
          circuit_breaker :payments do
            strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 1)
            strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 2)
            recover(Rexsilient.CircuitBreaker.Recover.BasicTimeout, reset_timeout: 1)
          end
        end,
        ~r"strategy/2 is set twice in circuit_breaker :payments"
      )
    end
  end

  describe "classify_with" do
    test "accepts a function defined with only one arity" do
      for def_quote <- [
            quote(do: def(only(_value), do: :success)),
            quote(do: def(only(_kind, _reason), do: :failure))
          ] do
        mod =
          compile!(
            quote do
              circuit_breaker :payments do
                strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 1)
                recover(Rexsilient.CircuitBreaker.Recover.BasicTimeout, reset_timeout: 1)
                classify_with(:only)
              end

              unquote(def_quote)
            end
          )

        assert [config] = mod.__rexsilient__(:circuit_breakers)
        assert config[:classify_with] == :only
      end
    end

    test "rejects a function that is not defined" do
      assert_dsl_error(
        quote do
          circuit_breaker :payments do
            strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 1)
            recover(Rexsilient.CircuitBreaker.Recover.BasicTimeout, reset_timeout: 1)
            classify_with(:missing)
          end
        end,
        ~r"circuit_breaker :payments: classify_with :missing needs missing/1 or missing/2"
      )
    end

    test "rejects a private function" do
      assert_dsl_error(
        quote do
          circuit_breaker :payments do
            strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 1)
            recover(Rexsilient.CircuitBreaker.Recover.BasicTimeout, reset_timeout: 1)
            classify_with(:hidden)
          end

          defp hidden(_value), do: :success
        end,
        ~r"classify_with :hidden needs hidden/1 or hidden/2 defined with def"
      )
    end

    test "rejects a value that is not a function name" do
      for value <- ["custom", nil] do
        assert_dsl_error(
          quote do
            circuit_breaker :payments do
              strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 1)
              recover(Rexsilient.CircuitBreaker.Recover.BasicTimeout, reset_timeout: 1)
              classify_with(unquote(value))
            end
          end,
          ~r"classify_with/1 must be a function name, got: #{Regex.escape(inspect(value))}"
        )
      end
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
        ~r"circuit_breaker :payments is missing strategy/2"
      )
    end

    test "rejects a breaker without recover" do
      assert_dsl_error(
        quote do
          circuit_breaker :payments do
            strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 1)
          end
        end,
        ~r"circuit_breaker :payments is missing recover/2"
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

    test "rejects a setting of another block, naming the allowed ones" do
      assert_dsl_error(
        quote do
          circuit_breaker :payments do
            attempts(3)
          end
        end,
        ~r"attempts/1 is not allowed inside circuit_breaker/2; allowed: strategy/2, recover/2, classify_with/1"
      )
    end
  end
end
