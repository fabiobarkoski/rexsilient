defmodule Rexsilient.PolicyTest.Resilience do
  use Rexsilient

  alias Rexsilient.CircuitBreaker.{Recover, Strategy}

  fallback :pol do
    function(:recover)
  end

  retry :pol do
    attempts(3)
    strategy(Rexsilient.Retry.Strategy.Constant, delay: 0)
  end

  circuit_breaker :pol do
    strategy(Strategy.Count, threshold: 5)
    recover(Recover.BasicTimeout, reset_timeout: :timer.seconds(10), probing_timeout: 5_000)
  end

  # Written out of order: the nesting order is fixed.
  policy :pol do
    circuit_breaker(:pol)
    fallback(:pol)
    retry(:pol)
  end

  policy :pol_no_retry do
    fallback(:pol)
    circuit_breaker(:pol)
  end

  def recover(arg), do: {:fallback, arg}
end

# Redeclares :pol, to check that duplicated names are rejected.
defmodule Rexsilient.PolicyTest.DuplicatePolicies do
  use Rexsilient

  policy :pol do
    retry(:pol)
  end
end

# References declarations of Resilience.
defmodule Rexsilient.PolicyTest.CrossModule do
  use Rexsilient

  policy :pol_cross do
    retry(:pol)
    circuit_breaker(:pol)
  end
end

defmodule Rexsilient.PolicyTest.UnknownReference do
  use Rexsilient

  policy :pol_unknown do
    fallback(:pol)
    retry(:nope)
  end
end

defmodule Rexsilient.PolicyTest.Client do
  use Rexsilient.Decorator

  @policy :pol
  def call(result) do
    send(self(), :attempt)
    result
  end

  @policy name: :pol
  def with_keyword(result), do: result

  @policy :pol_no_retry
  def no_retry(result) do
    send(self(), :attempt)
    result
  end

  # Written out of order: stacked decorators nest like a policy.
  @circuit_breaker :pol
  @retry :pol
  @fallback :pol
  def stacked(result) do
    send(self(), :attempt)
    result
  end

  @policy :nope
  def unknown(result), do: result
end

defmodule Rexsilient.PolicyTest do
  # Declarations live in :persistent_term and the breaker manager is a named
  # singleton, so these tests cannot run concurrently with the others.
  use ExUnit.Case, async: false

  alias Rexsilient.CircuitBreaker, as: CB
  alias Rexsilient.Policy

  alias Rexsilient.PolicyTest.{
    Client,
    CrossModule,
    DuplicatePolicies,
    Resilience,
    UnknownReference
  }

  setup do
    start_supervised!({Rexsilient, modules: [Resilience]})
    :ok
  end

  # Releases are casts; a call from this process is handled after them.
  defp sync, do: :sys.get_state(CB)

  # Counts the :attempt messages sent by the decorated functions.
  defp attempts(count \\ 0) do
    receive do
      :attempt -> attempts(count + 1)
    after
      0 -> count
    end
  end

  # Every module is compiled inside its test, so a broken macro fails that test
  # instead of the whole file.
  defp compile!(using, body) do
    mod = Module.concat(__MODULE__, "M#{System.unique_integer([:positive])}")

    quoted =
      quote do
        defmodule unquote(mod) do
          use unquote(using)
          unquote(body)
        end
      end

    Code.eval_quoted(quoted, [], file: __ENV__.file)
    mod
  end

  defp assert_compile_error(using, body, message) do
    err = assert_raise CompileError, message, fn -> compile!(using, body) end
    assert err.file == __ENV__.file
  end

  # The same checks for @policy and for stacked decorators: both nest as
  # fallback(retry(circuit_breaker(call))).
  for {fun, label} <- [call: "@policy", stacked: "stacked decorators"] do
    describe "nesting order with #{label}" do
      test "return the function's result unchanged on success" do
        assert Client.unquote(fun)({:ok, 1}) == {:ok, 1}
        assert attempts() == 1
      end

      test "retry before falling back, so the fallback is outermost" do
        assert Client.unquote(fun)({:error, :boom}) == {:fallback, {:error, :boom}}
        assert attempts() == 3
      end

      test "count every attempt in the breaker, so the breaker is innermost" do
        Client.unquote(fun)({:error, :boom})
        assert attempts() == 3
        sync()
        assert CB.status(:pol) == :closed

        # Attempts 4 and 5 fail and open the breaker; the retry stops on the
        # rejection instead of making a sixth attempt.
        assert Client.unquote(fun)({:error, :boom}) == {:fallback, {:error, :boom}}
        assert attempts() == 2
        sync()
        assert CB.status(:pol) == :open
      end

      test "fall back without calling the function while the breaker is open" do
        for _ <- 1..2, do: Client.unquote(fun)({:error, :boom})
        sync()
        assert CB.status(:pol) == :open
        attempts()

        assert Client.unquote(fun)(:ok) == {:fallback, :ok}
        assert attempts() == 0
      end
    end
  end

  describe "@policy" do
    test "a keyword list with :name behaves like the plain name" do
      assert Client.with_keyword(:ok) == :ok
      assert Client.with_keyword(:error) == {:fallback, :error}
    end

    test "entries left out are skipped" do
      assert Client.no_retry({:error, :boom}) == {:fallback, {:error, :boom}}
      assert attempts() == 1
    end

    test "an unknown policy raises when called" do
      assert_raise ArgumentError, "unknown policy :nope", fn -> Client.unknown(:ok) end
    end

    test "cannot be combined with other decorators" do
      assert_compile_error(
        Rexsilient.Decorator,
        quote do
          @policy :pol
          @retry :pol
          def fun, do: :ok
        end,
        ~r/@policy on fun cannot be combined with other decorators/
      )
    end
  end

  describe "registration" do
    test "a duplicated name raises" do
      assert_raise ArgumentError, "policy :pol already exists", fn ->
        Policy.__install__([Resilience, DuplicatePolicies])
      end
    end

    test "a reference to an undeclared name raises" do
      assert_raise ArgumentError, "policy :pol_unknown: unknown retry :nope", fn ->
        Policy.__install__([Resilience, UnknownReference])
      end
    end

    test "references are found in any registered module" do
      assert Policy.__install__([Resilience, CrossModule]) == :ok
    end
  end

  describe "declaring policies" do
    test "keeps the referenced names" do
      mod =
        compile!(
          Rexsilient,
          quote do
            policy :local do
              retry(:r)
              circuit_breaker(:cb)
            end
          end
        )

      assert [config] = mod.__rexsilient__(:policies)
      assert config[:name] == :local
      assert config[:retry] == :r
      assert config[:circuit_breaker] == :cb
      refute Keyword.has_key?(config, :fallback)
    end

    test "rejects an empty policy" do
      assert_compile_error(
        Rexsilient,
        quote do
          policy :empty do
          end
        end,
        ~r/policy :empty needs at least one of fallback\/1, retry\/1, circuit_breaker\/1/
      )
    end

    test "names and references are evaluated, so expressions are allowed" do
      mod =
        compile!(
          Rexsilient,
          quote do
            @policy_name :from_attribute
            @breaker :cb

            policy @policy_name do
              circuit_breaker(@breaker)
            end
          end
        )

      assert [config] = mod.__rexsilient__(:policies)
      assert config[:name] == :from_attribute
      assert config[:circuit_breaker] == :cb
    end

    test "rejects an entry set twice" do
      assert_compile_error(
        Rexsilient,
        quote do
          policy :twice do
            retry(:a)
            retry(:b)
          end
        end,
        ~r"retry/1 is set twice in policy :twice"
      )
    end

    test "rejects nil as a reference" do
      assert_compile_error(
        Rexsilient,
        quote do
          policy :prices do
            retry(nil)
          end
        end,
        ~r/name must be an atom, got: nil/
      )
    end

    test "rejects an entry outside a policy" do
      assert_compile_error(
        Rexsilient,
        quote do
          retry(:r)
        end,
        ~r/retry\/1 outside the block/
      )
    end

    test "rejects an entry inside another block" do
      assert_compile_error(
        Rexsilient,
        quote do
          fallback :f do
            function(:recover)
            retry(:r)
          end
        end,
        ~r/retry\/1 is not allowed inside fallback\/2/
      )
    end

    test "rejects a name that is not an atom" do
      assert_compile_error(
        Rexsilient,
        quote do
          policy "prices" do
            retry(:r)
          end
        end,
        ~r/"prices"/
      )

      assert_compile_error(
        Rexsilient,
        quote do
          policy :prices do
            retry("r")
          end
        end,
        ~r/"r"/
      )
    end
  end
end
