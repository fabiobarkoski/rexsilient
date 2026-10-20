defmodule Rexsilient.FallbackTest.Remote do
  def recover(arg), do: {:remote, arg}
end

defmodule Rexsilient.FallbackTest.Fallbacks do
  use Rexsilient

  fallback :fb_test do
    function(:recover)
  end

  fallback :fb_remote do
    function({Rexsilient.FallbackTest.Remote, :recover})
  end

  fallback :fb_custom do
    function(:recover)
    classify_with(:custom_classify)
  end

  fallback :fb_raising do
    function(:explode)
  end

  fallback :fb_values_only do
    function(:recover)
    classify_with(:values_only)
  end

  fallback :fb_exceptions_only do
    function(:recover)
    classify_with(:exceptions_only)
  end

  def values_only(:boom), do: :failure
  def values_only(_), do: :success

  def exceptions_only(:throw, :ignored), do: :success
  def exceptions_only(_kind, _reason), do: :failure

  def recover(arg), do: {:fallback, arg}
  def recover(a, b), do: {:fallback, a, b}

  def explode(_arg), do: raise("fallback failed")

  def custom_classify(:boom), do: :failure
  def custom_classify(_), do: :success

  def custom_classify(:throw, :ignored), do: :success
  def custom_classify(_kind, _reason), do: :failure
end

defmodule Rexsilient.FallbackTest.CustomClassifyFallbacks do
  use Rexsilient

  fallback :fb_classify_override do
    function(:recover)
  end

  def recover(arg), do: {:fallback, arg}

  def classify(:boom), do: :failure
  def classify(_), do: :success
end

# Redeclares :fb_test, to check that duplicated names are rejected.
defmodule Rexsilient.FallbackTest.DuplicateFallbacks do
  use Rexsilient

  fallback :fb_test do
    function(:recover)
  end

  def recover(arg), do: arg
end

defmodule Rexsilient.FallbackTest.Client do
  use Rexsilient.Decorator

  @fallback :fb_test
  def call(result), do: result

  @fallback :fb_test
  def invoke(fun), do: fun.()

  @fallback :fb_test
  def pair(a, _b), do: a

  @fallback name: :fb_test
  def with_keyword(result), do: result

  @fallback :fb_test
  def classify(:ok), do: {:ok, :first_clause}
  def classify(:error), do: {:error, :second_clause}

  def plain(result), do: result

  @fallback false
  def disabled(result), do: result
end

defmodule Rexsilient.FallbackTest do
  # Fallbacks live in :persistent_term, shared by the whole node.
  use ExUnit.Case, async: false

  alias Rexsilient.Fallback

  alias Rexsilient.FallbackTest.{
    Client,
    CustomClassifyFallbacks,
    DuplicateFallbacks,
    Fallbacks,
    Remote
  }

  @name :fb_test

  setup do
    :ok = Fallback.__install__([Fallbacks, CustomClassifyFallbacks])
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

  describe "run/3 results" do
    test "returns the function's result unchanged on success" do
      for value <- [{:ok, 1}, :ok, 42, %{a: 1}] do
        assert Fallback.run(@name, fn arg -> arg end, value) == value
      end
    end

    test "passes the argument to the function" do
      assert Fallback.run(@name, fn arg -> {:got, arg} end, :value) == {:got, :value}
    end

    test ":error and {:error, _} call the fallback with the same argument" do
      assert Fallback.run(@name, fn _ -> :error end, :value) == {:fallback, :value}
      assert Fallback.run(@name, fn _ -> {:error, :boom} end, :value) == {:fallback, :value}
    end

    test "a list is passed as a single argument" do
      assert Fallback.run(@name, fn arg -> {:error, arg} end, [1, 2]) == {:fallback, [1, 2]}
    end

    test "raise, throw and exit call the fallback" do
      assert Fallback.run(@name, fn _ -> raise "boom" end, :value) == {:fallback, :value}
      assert Fallback.run(@name, fn _ -> throw(:ball) end, :value) == {:fallback, :value}
      assert Fallback.run(@name, fn _ -> exit(:bye) end, :value) == {:fallback, :value}
    end

    test "the fallback is not called on success" do
      Fallback.run(@name, fn _ -> send(self(), :called) && :ok end, :value)
      assert_received :called

      assert Fallback.run(:fb_raising, fn _ -> :ok end, :value) == :ok
    end

    test "a fallback in another module is called" do
      assert Fallback.run(:fb_remote, fn _ -> :error end, :value) == {:remote, :value}
    end

    test "an error raised by the fallback propagates" do
      assert_raise RuntimeError, "fallback failed", fn ->
        Fallback.run(:fb_raising, fn _ -> :error end, :value)
      end
    end

    test "an unknown fallback raises" do
      assert_raise ArgumentError, "unknown fallback :nope", fn ->
        Fallback.run(:nope, fn _ -> :ok end, :value)
      end
    end
  end

  describe "classify" do
    test "classify_with decides which values call the fallback" do
      assert Fallback.run(:fb_custom, fn _ -> {:error, :a} end, :value) == {:error, :a}
      assert Fallback.run(:fb_custom, fn _ -> :error end, :value) == :error
      assert Fallback.run(:fb_custom, fn _ -> :boom end, :value) == {:fallback, :value}
    end

    test "classify_with decides which exceptions call the fallback; the others are re-raised" do
      assert catch_throw(Fallback.run(:fb_custom, fn _ -> throw(:ignored) end, :value)) ==
               :ignored

      assert Fallback.run(:fb_custom, fn _ -> throw(:other) end, :value) == {:fallback, :value}
    end

    test "{:error, :circuit_open} always calls the fallback, even if classified as a success" do
      assert Fallback.run(@name, fn _ -> {:error, :circuit_open} end, :value) ==
               {:fallback, :value}

      # :fb_custom classifies every value but :boom as a success.
      assert Fallback.run(:fb_custom, fn _ -> {:error, :circuit_open} end, :value) ==
               {:fallback, :value}
    end

    test "an overridden classify/1 is used without classify_with" do
      assert Fallback.run(:fb_classify_override, fn _ -> {:error, :a} end, :value) ==
               {:error, :a}

      assert Fallback.run(:fb_classify_override, fn _ -> :boom end, :value) ==
               {:fallback, :value}
    end

    test "classify_with with only /1 uses the module's classify/2 for exceptions" do
      assert Fallback.run(:fb_values_only, fn _ -> {:error, :a} end, :value) == {:error, :a}
      assert Fallback.run(:fb_values_only, fn _ -> :boom end, :value) == {:fallback, :value}

      assert Fallback.run(:fb_values_only, fn _ -> raise "boom" end, :value) ==
               {:fallback, :value}
    end

    test "classify_with with only /2 uses the module's classify/1 for values" do
      assert Fallback.run(:fb_exceptions_only, fn _ -> {:error, :a} end, :value) ==
               {:fallback, :value}

      assert catch_throw(Fallback.run(:fb_exceptions_only, fn _ -> throw(:ignored) end, :value)) ==
               :ignored
    end

    test "overriding classify/1 keeps the default classify/2" do
      assert Fallback.run(:fb_classify_override, fn _ -> raise "boom" end, :value) ==
               {:fallback, :value}
    end
  end

  describe "registration" do
    test "a duplicated name raises" do
      assert_raise ArgumentError, "fallback :fb_test already exists", fn ->
        Fallback.__install__([Fallbacks, DuplicateFallbacks])
      end
    end
  end

  describe "declaring fallbacks" do
    test "a bare function name refers to the declaring module" do
      mod =
        compile!(
          quote do
            fallback :local do
              function(:recover)
            end
          end
        )

      assert [config] = mod.__rexsilient__(:fallbacks)
      assert config[:name] == :local
      assert config[:function] == {mod, :recover}
    end

    test "a {module, function} tuple is kept, with aliases expanded" do
      # Remote is aliased at the top of this module: an alias inside the quote
      # would not apply to the quoted code, because of hygiene.
      mod =
        compile!(
          quote do
            fallback :remote do
              function({Remote, :recover})
              classify_with(:custom)
            end

            def custom(_), do: :success
          end
        )

      assert [config] = mod.__rexsilient__(:fallbacks)
      assert config[:function] == {Remote, :recover}
      assert config[:classify_with] == :custom
    end

    test "collects several fallbacks in declaration order" do
      mod =
        compile!(
          quote do
            fallback :first do
              function(:a)
            end

            fallback :second do
              function(:b)
            end
          end
        )

      assert Enum.map(mod.__rexsilient__(:fallbacks), & &1[:name]) == [:first, :second]
    end

    test "rejects a fallback without function" do
      err =
        assert_raise CompileError, ~r"fallback :empty is missing function/1", fn ->
          compile!(
            quote do
              fallback :empty do
                classify_with(:custom)
              end
            end
          )
        end

      assert err.file == __ENV__.file
    end

    test "rejects a function that is not a name or {module, name}" do
      for value <- ["recover", nil, {"Remote", :recover}, {Remote, "recover"}, {Remote, :a, :b}] do
        err =
          assert_raise CompileError,
                       ~r"function/1 must be a function name or \{module, name\}, got: #{Regex.escape(inspect(value))}",
                       fn ->
                         compile!(
                           quote do
                             fallback :bad do
                               function(unquote(Macro.escape(value)))
                             end
                           end
                         )
                       end

        assert err.file == __ENV__.file
      end
    end

    test "rejects a name that is not an atom" do
      assert_raise CompileError, ~r/"payments"/, fn ->
        compile!(
          quote do
            fallback "payments" do
              function(:recover)
            end
          end
        )
      end
    end
  end

  describe "decorated functions" do
    test "return the function's result unchanged on success" do
      for value <- [{:ok, 1}, :ok, 42] do
        assert Client.call(value) == value
      end
    end

    test "call the fallback with the function's arguments on failure" do
      assert Client.call({:error, :boom}) == {:fallback, {:error, :boom}}
      assert Client.pair(:error, :second) == {:fallback, :error, :second}
    end

    test "call the fallback when the function raises" do
      fun = fn -> raise "boom" end
      assert Client.invoke(fun) == {:fallback, fun}
    end

    test "every clause goes through the fallback" do
      assert Client.classify(:ok) == {:ok, :first_clause}
      assert Client.classify(:error) == {:fallback, :error}
    end

    test "a keyword list with :name behaves like the plain name" do
      assert Client.with_keyword(:ok) == :ok
      assert Client.with_keyword(:error) == {:fallback, :error}
    end

    test "undecorated and disabled functions are not wrapped" do
      assert Client.plain(:error) == :error
      assert Client.disabled(:error) == :error
    end
  end
end
