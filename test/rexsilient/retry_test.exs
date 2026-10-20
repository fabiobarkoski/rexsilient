defmodule Rexsilient.RetryTest.Recording do
  # Sends every call to the test process, counts the calls in its state, and
  # stops at the attempt given as :stop_at.
  @behaviour Rexsilient.Retry.Strategy

  @impl true
  def init(opts), do: %{calls: 0, stop_at: Keyword.get(opts, :stop_at)}

  @impl true
  def delay(context, state) do
    send(self(), {:delay, context, state.calls})

    if context.attempt == state.stop_at,
      do: :stop,
      else: {:retry, 0, %{state | calls: state.calls + 1}}
  end
end

defmodule Rexsilient.RetryTest.Raiser do
  def boom!, do: raise("boom")
end

defmodule Rexsilient.RetryTest.Retries do
  use Rexsilient

  alias Rexsilient.Retry.Strategy
  alias Rexsilient.RetryTest.Recording

  retry :rt_test do
    attempts(3)
    strategy(Recording, [])
  end

  retry :rt_stop do
    attempts(5)
    strategy(Recording, stop_at: 2)
  end

  retry :rt_infinity do
    attempts(:infinity)
    strategy(Recording, stop_at: 10)
  end

  retry :rt_custom do
    attempts(3)
    strategy(Recording, [])
    classify_with(:retryable)
  end

  retry :rt_delay do
    attempts(2)
    strategy(Strategy.Constant, delay: 50)
  end

  def retryable({:error, :retry_me}), do: :failure
  def retryable(_), do: :success

  def retryable(:throw, :retry_me), do: :failure
  def retryable(_kind, _reason), do: :success
end

# Redeclares :rt_test, to check that duplicated names are rejected.
defmodule Rexsilient.RetryTest.DuplicateRetries do
  use Rexsilient

  retry :rt_test do
    attempts(2)
    strategy(Rexsilient.Retry.Strategy.Constant, delay: 0)
  end
end

# A breaker strategy: init/1 accepts the options, but delay/2 is missing.
defmodule Rexsilient.RetryTest.WrongStrategyRetries do
  use Rexsilient

  retry :rt_wrong_strategy do
    attempts(2)
    strategy(Rexsilient.CircuitBreaker.Strategy.Count, threshold: 1)
  end
end

defmodule Rexsilient.RetryTest.InvalidRetries do
  use Rexsilient

  retry :rt_invalid do
    attempts(2)
    strategy(Rexsilient.Retry.Strategy.Constant, delay: -1)
  end
end

defmodule Rexsilient.RetryTest.Client do
  use Rexsilient.Decorator

  @retry :rt_test
  def call(fun), do: fun.()

  @retry name: :rt_test
  def with_keyword(fun), do: fun.()

  def plain(fun), do: fun.()
end

defmodule Rexsilient.RetryTest do
  # Retries live in :persistent_term, shared by the whole node.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Rexsilient.Retry
  alias Rexsilient.RetryTest.{Client, DuplicateRetries, InvalidRetries, Raiser, Retries}

  setup do
    :ok = Retry.__install__([Retries])
  end

  # Every module is compiled inside its test, so a broken macro fails that test
  # instead of the whole file.
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

  # Returns a function that returns `values` in order, one per call, and
  # sends :attempt to the test process on every call.
  defp sequence(values) do
    {:ok, agent} = Agent.start_link(fn -> values end)

    fn ->
      send(self(), :attempt)
      Agent.get_and_update(agent, fn [value | rest] -> {value, rest} end)
    end
  end

  defp always(value) do
    fn ->
      send(self(), :attempt)
      value
    end
  end

  defp attempts_made(count \\ 0) do
    receive do
      :attempt -> attempts_made(count + 1)
    after
      0 -> count
    end
  end

  describe "run/2 results" do
    test "returns the function's result unchanged on success, without retrying" do
      for value <- [{:ok, 1}, :ok, 42, %{a: 1}] do
        assert Retry.run(:rt_test, always(value)) == value
        assert attempts_made() == 1
      end

      refute_received {:delay, _, _}
    end

    test "retries failures until a success, and returns it" do
      assert Retry.run(:rt_test, sequence([{:error, 1}, :error, {:ok, 3}])) == {:ok, 3}
      assert attempts_made() == 3
    end

    test "returns the last failure when no attempts remain" do
      assert Retry.run(:rt_test, sequence([{:error, 1}, {:error, 2}, {:error, 3}])) ==
               {:error, 3}

      assert attempts_made() == 3
    end

    test "re-raises the last exception when no attempts remain" do
      assert_raise RuntimeError, "boom", fn ->
        Retry.run(:rt_test, fn ->
          send(self(), :attempt)
          raise "boom"
        end)
      end

      assert attempts_made() == 3
    end

    test "keeps the exception's original stacktrace" do
      stacktrace =
        try do
          Retry.run(:rt_test, &Raiser.boom!/0)
          flunk("expected a raise")
        rescue
          RuntimeError -> __STACKTRACE__
        end

      assert [{Raiser, :boom!, 0, _} | _] = stacktrace
    end

    test "retries throws and exits, and re-throws or exits with the last one" do
      assert catch_throw(Retry.run(:rt_test, fn -> throw(:ball) end)) == :ball
      assert catch_exit(Retry.run(:rt_test, fn -> exit(:bye) end)) == :bye
      assert_received {:delay, %{attempt: 2, outcome: {:throw, :ball}}, 1}
      assert_received {:delay, %{attempt: 2, outcome: {:exit, :bye}}, 1}
    end

    test "never retries {:error, :circuit_open}" do
      assert Retry.run(:rt_test, always({:error, :circuit_open})) == {:error, :circuit_open}
      assert attempts_made() == 1
    end

    test "an unknown retry raises" do
      assert_raise ArgumentError, "unknown retry :nope", fn ->
        Retry.run(:nope, fn -> :ok end)
      end
    end
  end

  describe "strategy" do
    test "is called after every failed attempt but the last" do
      Retry.run(:rt_test, sequence([{:error, 1}, {:error, 2}, {:error, 3}]))

      assert_received {:delay, %{attempt: 1, outcome: {:value, {:error, 1}}}, _}
      assert_received {:delay, %{attempt: 2, outcome: {:value, {:error, 2}}}, _}
      refute_received {:delay, %{attempt: 3}, _}
    end

    test "gets a raise as {:error, exception}" do
      assert_raise RuntimeError, fn -> Retry.run(:rt_test, &Raiser.boom!/0) end

      assert_received {:delay, %{attempt: 1, outcome: {:error, %RuntimeError{message: "boom"}}},
                       _}
    end

    test "its state is passed from one attempt to the next" do
      Retry.run(:rt_test, always(:error))

      assert_received {:delay, %{attempt: 1}, 0}
      assert_received {:delay, %{attempt: 2}, 1}
    end

    test "every run starts from the state returned by init/1" do
      Retry.run(:rt_test, always(:error))
      Retry.run(:rt_test, always(:error))

      assert_received {:delay, %{attempt: 1}, 0}
      assert_received {:delay, %{attempt: 2}, 1}
      assert_received {:delay, %{attempt: 1}, 0}
      assert_received {:delay, %{attempt: 2}, 1}
    end

    test ":stop returns the last failure while attempts remain" do
      assert Retry.run(:rt_stop, sequence([{:error, 1}, {:error, 2}, {:ok, 3}])) == {:error, 2}
      assert attempts_made() == 2
    end

    test ":stop re-raises the last exception" do
      assert_raise RuntimeError, "boom", fn -> Retry.run(:rt_stop, &Raiser.boom!/0) end
    end

    test "with :infinity attempts, only the strategy stops" do
      assert Retry.run(:rt_infinity, always(:error)) == :error
      assert attempts_made() == 10
    end

    test "the caller sleeps for the returned delay" do
      start = System.monotonic_time(:millisecond)
      Retry.run(:rt_delay, always(:error))
      assert System.monotonic_time(:millisecond) - start >= 50
    end
  end

  describe "classify" do
    test "classify_with decides which values are retried" do
      assert Retry.run(:rt_custom, always({:error, :other})) == {:error, :other}
      assert attempts_made() == 1

      assert Retry.run(:rt_custom, always({:error, :retry_me})) == {:error, :retry_me}
      assert attempts_made() == 3
    end

    test "classify_with decides which exceptions are retried; the others are re-raised at once" do
      assert catch_throw(Retry.run(:rt_custom, fn -> throw(:ignored) end)) == :ignored
      refute_received {:delay, _, _}

      assert catch_throw(Retry.run(:rt_custom, fn -> throw(:retry_me) end)) == :retry_me
      assert_received {:delay, %{attempt: 2}, _}
    end
  end

  describe "registration" do
    test "a duplicated name raises" do
      assert_raise ArgumentError, "retry :rt_test already exists", fn ->
        Retry.__install__([Retries, DuplicateRetries])
      end
    end

    test "invalid strategy options raise with the retry's name" do
      message =
        "retry :rt_invalid: invalid strategy options for Rexsilient.Retry.Strategy.Constant: " <>
          "delay must be a non-negative integer, got: -1"

      assert_raise ArgumentError, message, fn -> Retry.__install__([InvalidRetries]) end
    end

    test "a strategy of another behaviour names the retry and the missing callback" do
      message =
        "retry :rt_wrong_strategy: Rexsilient.CircuitBreaker.Strategy.Count " <>
          "does not implement Rexsilient.Retry.Strategy (missing delay/2)"

      assert_raise ArgumentError, message, fn ->
        Retry.__install__([Rexsilient.RetryTest.WrongStrategyRetries])
      end
    end
  end

  describe "declaring retries" do
    test "collects one retry" do
      mod =
        compile!(
          quote do
            retry :payments do
              attempts(3)
              strategy(Rexsilient.Retry.Strategy.Constant, delay: 100)
              classify_with(:retryable)
            end

            def retryable(_), do: :success
          end
        )

      assert [config] = mod.__rexsilient__(:retries)
      assert config[:name] == :payments
      assert config[:attempts] == 3
      assert config[:strategy] == {Rexsilient.Retry.Strategy.Constant, [delay: 100]}
      assert config[:classify_with] == :retryable
    end

    test "collects several retries in declaration order" do
      mod =
        compile!(
          quote do
            retry :first do
              attempts(2)
              strategy(Rexsilient.Retry.Strategy.Constant, delay: 0)
            end

            retry :second do
              attempts(2)
              strategy(Rexsilient.Retry.Strategy.Constant, delay: 0)
            end
          end
        )

      assert Enum.map(mod.__rexsilient__(:retries), & &1[:name]) == [:first, :second]
    end

    test "accepts :infinity attempts" do
      mod =
        compile!(
          quote do
            retry :forever do
              attempts(:infinity)
              strategy(Rexsilient.Retry.Strategy.Constant, delay: 0)
            end
          end
        )

      assert [config] = mod.__rexsilient__(:retries)
      assert config[:attempts] == :infinity
    end

    test "a module declaring only retries does not warn" do
      output =
        capture_io(:stderr, fn ->
          compile!(
            quote do
              retry :only do
                attempts(2)
                strategy(Rexsilient.Retry.Strategy.Constant, delay: 0)
              end
            end
          )
        end)

      refute output =~ "declares nothing"
    end

    test "rejects a retry without attempts" do
      err =
        assert_raise CompileError, ~r"retry :no_attempts is missing attempts/1", fn ->
          compile!(
            quote do
              retry :no_attempts do
                strategy(Rexsilient.Retry.Strategy.Constant, delay: 0)
              end
            end
          )
        end

      assert err.file == __ENV__.file
    end

    test "rejects a retry without strategy" do
      assert_raise CompileError, ~r"retry :no_strategy is missing strategy/2", fn ->
        compile!(
          quote do
            retry :no_strategy do
              attempts(2)
            end
          end
        )
      end
    end

    test "rejects attempts that are not a positive integer or :infinity" do
      for value <- [0, -1, "3", :forever] do
        assert_raise CompileError, ~r/attempts must be a positive integer or :infinity/, fn ->
          compile!(
            quote do
              retry :bad do
                attempts(unquote(value))
                strategy(Rexsilient.Retry.Strategy.Constant, delay: 0)
              end
            end
          )
        end
      end
    end

    test "attempts and the name are evaluated, so expressions are allowed" do
      mod =
        compile!(
          quote do
            @name :from_attribute
            @max 2

            retry @name do
              attempts(@max + 1)
              strategy(Rexsilient.Retry.Strategy.Constant, delay: 0)
            end
          end
        )

      assert [config] = mod.__rexsilient__(:retries)
      assert config[:name] == :from_attribute
      assert config[:attempts] == 3
    end

    test "rejects an expression that evaluates to invalid attempts" do
      assert_raise CompileError,
                   ~r/attempts must be a positive integer or :infinity, got: 0/,
                   fn ->
                     compile!(
                       quote do
                         @max 1

                         retry :bad do
                           attempts(@max - 1)
                           strategy(Rexsilient.Retry.Strategy.Constant, delay: 0)
                         end
                       end
                     )
                   end
    end

    test "rejects attempts outside retry" do
      assert_raise CompileError, ~r/attempts\/1 outside the block/, fn ->
        compile!(
          quote do
            attempts(3)
          end
        )
      end
    end

    test "rejects a name that is not an atom" do
      assert_raise CompileError, ~r/"payments"/, fn ->
        compile!(
          quote do
            retry "payments" do
              attempts(2)
              strategy(Rexsilient.Retry.Strategy.Constant, delay: 0)
            end
          end
        )
      end
    end
  end

  describe "decorated functions" do
    test "retry the body" do
      assert Client.call(sequence([:error, {:ok, 2}])) == {:ok, 2}
      assert attempts_made() == 2
    end

    test "a keyword list with :name behaves like the plain name" do
      assert Client.with_keyword(always(:error)) == :error
      assert attempts_made() == 3
    end

    test "undecorated functions are not retried" do
      assert Client.plain(always(:error)) == :error
      assert attempts_made() == 1
    end
  end
end
