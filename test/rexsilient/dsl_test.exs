defmodule Rexsilient.DSLTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO, only: [with_io: 2]

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
              timeout(5_000)
              threshold(3)
            end
          end
        )

      assert mod.__rexsilient__(:circuit_breakers) == [
               [threshold: 3, timeout: 5_000, name: :payments]
             ]
    end

    test "collects several breakers in declaration order" do
      mod =
        compile!(
          quote do
            circuit_breaker :payments do
              timeout(5_000)
              threshold(3)
            end

            circuit_breaker :search do
              threshold(10)
              timeout(1_000)
            end
          end
        )

      assert mod.__rexsilient__(:circuit_breakers) == [
               [threshold: 3, timeout: 5_000, name: :payments],
               [timeout: 1_000, threshold: 10, name: :search]
             ]
    end

    test "evaluates values at compile time" do
      mod =
        compile!(
          quote do
            circuit_breaker :payments do
              timeout(:timer.seconds(5))
              threshold(2 + 1)
            end
          end
        )

      assert [config] = mod.__rexsilient__(:circuit_breakers)
      assert config[:timeout] == 5_000
      assert config[:threshold] == 3
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
            timeout(1)
            threshold(1)
          end
        end,
        ~r/"payments"/
      )
    end
  end

  describe "missing settings" do
    test "rejects a breaker without timeout" do
      assert_dsl_error(
        quote do
          circuit_breaker :payments do
            threshold(1)
          end
        end,
        ~r/Missing timeout/
      )
    end

    test "rejects a breaker without threshold" do
      assert_dsl_error(
        quote do
          circuit_breaker :payments do
            timeout(1)
          end
        end,
        ~r/Missing threshold/
      )
    end
  end

  describe "invalid values" do
    for {key, bad} <- [timeout: 0, timeout: -1, timeout: "1", threshold: 0, threshold: 1.5] do
      test "rejects #{key} #{inspect(bad)}" do
        key = unquote(key)
        bad = unquote(bad)

        assert_dsl_error(
          quote do
            circuit_breaker :payments do
              timeout(1)
              threshold(1)
              unquote(key)(unquote(bad))
            end
          end,
          ~r/#{key}\/1 must be a positive integer/
        )
      end
    end
  end

  describe "settings outside a breaker" do
    test "rejects timeout outside circuit_breaker" do
      assert_dsl_error(
        quote do
          timeout(5)
        end,
        ~r/timeout\/1 outside/
      )
    end

    test "rejects threshold outside circuit_breaker" do
      assert_dsl_error(
        quote do
          threshold(5)
        end,
        ~r/threshold\/1 outside/
      )
    end
  end
end
