defmodule Restate.ServiceTest do
  use ExUnit.Case, async: true

  alias Restate.Context

  describe "happy path" do
    defmodule Greeter do
      use Restate.Service, type: :virtual_object

      @handler type: :exclusive
      def count(%Context{} = ctx, _input) do
        n = (Context.get_state(ctx, "counter") || 0) + 1
        Context.set_state(ctx, "counter", n)
        "hello #{n}"
      end

      @handler type: :exclusive
      def long_greet(%Context{} = ctx, name) do
        Context.sleep(ctx, 10)
        "hello #{name}"
      end
    end

    test "service name defaults to the last module segment" do
      assert Greeter.__restate_service__()[:name] == "Greeter"
    end

    test "service type is what was passed to use" do
      assert Greeter.__restate_service__()[:type] == :virtual_object
    end

    test "handlers are recorded in declaration order" do
      handlers = Greeter.__restate_service__()[:handlers]

      assert [
               %{name: "count", type: :exclusive, mfa: {_, :count, 2}},
               %{name: "long_greet", type: :exclusive, mfa: {_, :long_greet, 2}}
             ] = handlers
    end

    test "__restate_handlers__/0 returns the same list" do
      assert Greeter.__restate_handlers__() == Greeter.__restate_service__()[:handlers]
    end

    test "the underlying functions remain callable normally" do
      # The macro doesn't transform the function; it just records
      # metadata. Calling Greeter.count/2 works exactly like a plain
      # def — important for testability.
      assert is_function(&Greeter.count/2)
      assert is_function(&Greeter.long_greet/2)
    end
  end

  describe "service-name override" do
    defmodule MyApp.Internal.Counter do
      use Restate.Service, name: "PublicCounter", type: :virtual_object

      @handler type: :exclusive
      def add(%Context{} = _ctx, _n), do: :ok
    end

    test "honors the :name option" do
      assert MyApp.Internal.Counter.__restate_service__()[:name] == "PublicCounter"
    end
  end

  describe "handler-name override" do
    defmodule HandlerNameOverride do
      use Restate.Service, type: :service

      @handler name: "publicName"
      def some_internal_name(%Context{} = _ctx, _input), do: :ok
    end

    test "honors per-handler :name" do
      [%{name: name, mfa: {_, fn_name, _}}] =
        HandlerNameOverride.__restate_service__()[:handlers]

      assert name == "publicName"
      assert fn_name == :some_internal_name
    end
  end

  describe "service types" do
    defmodule PlainService do
      use Restate.Service, type: :service
      @handler []
      def echo(%Context{} = _ctx, x), do: x

      @handler true
      def echo_marker_form(%Context{} = _ctx, x), do: x
    end

    defmodule WorkflowService do
      use Restate.Service, type: :workflow
      @handler type: :workflow
      def main(%Context{} = _ctx, _input), do: :ok

      @handler type: :shared
      def status(%Context{} = _ctx, _input), do: :running
    end

    test ":service services accept @handler with no :type" do
      handlers = PlainService.__restate_service__()[:handlers]
      assert [%{name: "echo", type: nil}, %{name: "echo_marker_form", type: nil}] = handlers
    end

    test ":workflow services support :workflow + :shared handler types" do
      handlers = WorkflowService.__restate_service__()[:handlers]

      assert [
               %{name: "main", type: :workflow},
               %{name: "status", type: :shared}
             ] = handlers
    end
  end

  describe "compile-time validation" do
    test "rejects arity != 2" do
      assert_raise CompileError, ~r/must take exactly 2 arguments/, fn ->
        Code.compile_string("""
        defmodule Restate.ServiceTest.BadArity do
          use Restate.Service, type: :service
          @handler []
          def too_many(_ctx, _input, _extra), do: :ok
        end
        """)
      end
    end

    test "rejects defp" do
      assert_raise CompileError, ~r/must be defined with `def`/, fn ->
        Code.compile_string("""
        defmodule Restate.ServiceTest.BadVisibility do
          use Restate.Service, type: :service
          @handler []
          defp hidden(_ctx, _input), do: :ok
        end
        """)
      end
    end

    test "rejects services with no handlers" do
      assert_raise CompileError, ~r/has no handlers/, fn ->
        Code.compile_string("""
        defmodule Restate.ServiceTest.Empty do
          use Restate.Service, type: :service
        end
        """)
      end
    end

    test "rejects duplicate handler names" do
      assert_raise CompileError, ~r/declared more than once/, fn ->
        Code.compile_string("""
        defmodule Restate.ServiceTest.Dup do
          use Restate.Service, type: :service
          @handler []
          def echo(_ctx, _input), do: :ok
          @handler name: "echo"
          def echo_alias(_ctx, _input), do: :ok
        end
        """)
      end
    end

    test "rejects unknown service :type" do
      assert_raise ArgumentError, ~r/:type must be :service, :virtual_object, or :workflow/, fn ->
        Code.compile_string("""
        defmodule Restate.ServiceTest.BadType do
          use Restate.Service, type: :nonsense
          @handler []
          def echo(_ctx, _input), do: :ok
        end
        """)
      end
    end

    test "requires :type option" do
      assert_raise ArgumentError, ~r/requires a :type option/, fn ->
        Code.compile_string("""
        defmodule Restate.ServiceTest.NoType do
          use Restate.Service
          @handler []
          def echo(_ctx, _input), do: :ok
        end
        """)
      end
    end

    test "rejects unknown handler :type" do
      assert_raise CompileError, ~r/:type must be/, fn ->
        Code.compile_string("""
        defmodule Restate.ServiceTest.BadHandlerType do
          use Restate.Service, type: :virtual_object
          @handler type: :weird
          def echo(_ctx, _input), do: :ok
        end
        """)
      end
    end
  end

  describe "registration via Restate.Server.Registry" do
    defmodule Registerable do
      use Restate.Service, type: :virtual_object

      @handler type: :exclusive
      def ping(%Context{} = _ctx, _input), do: :pong
    end

    test "the macro output drops cleanly into register_service/1" do
      # Just enough to confirm there's no shape mismatch between
      # what the macro emits and what the registry accepts. We
      # don't exercise an end-to-end invocation here — that's what
      # the conformance suite is for.
      Restate.Server.Registry.reset()

      :ok = Restate.Server.Registry.register_service(Registerable.__restate_service__())

      assert %{mfa: {Registerable, :ping, 2}, type: :exclusive} =
               Restate.Server.Registry.lookup_handler("Registerable", "ping")

      Restate.Server.Registry.reset()
    end
  end
end
