defmodule Restate.Service do
  @moduledoc """
  Declarative service definitions: `use Restate.Service` + `@handler`
  attribute on `def`.

  ## Use

      defmodule MyApp.Greeter do
        use Restate.Service, name: "Greeter", type: :virtual_object

        alias Restate.Context

        @handler type: :exclusive
        def count(%Context{} = ctx, _input) do
          n = (Context.get_state(ctx, "counter") || 0) + 1
          Context.set_state(ctx, "counter", n)
          "hello \#{n}"
        end

        @handler type: :exclusive
        def long_greet(%Context{} = ctx, name) do
          Context.sleep(ctx, 10_000)
          "hello \#{name}"
        end
      end

  Then register the service from your `Application.start/2`:

      Restate.Server.Registry.register_service(MyApp.Greeter.__restate_service__())

  Or batch-register many at once:

      [MyApp.Greeter, MyApp.Counter, MyApp.WorkflowFoo]
      |> Enum.each(&Restate.Server.Registry.register_service(&1.__restate_service__()))

  ## What the macro does at compile time

    1. **Validates handler signatures.** Every `def` annotated with
       `@handler` must have arity 2 (the `(ctx, input)` shape) and
       must be `def` (not `defp`). Violations raise `CompileError`
       at the user's def site, with a message that points at the
       failing function. Catching the easy mistakes before the test
       suite runs.

    2. **Builds the discovery manifest entry from the module.** The
       generated `__restate_service__/0` returns a map shaped exactly
       like what `Restate.Server.Registry.register_service/1`
       accepts — so registration is one call per module instead of
       a hand-built nested map per handler.

    3. **Records each handler's MFA in module reflection.** The
       generated `__restate_handlers__/0` returns the list — useful
       for typed-call helpers, telemetry, or test scaffolding.

  ## Options for `use Restate.Service`

    * `:type` (required) — `:service`, `:virtual_object`, or `:workflow`.
    * `:name` (optional) — public service name. Defaults to the last
      segment of the module's name (e.g. `MyApp.Greeter` → `"Greeter"`).
      Override when the module name is forced into a particular
      Elixir namespace but the service name on the wire is different.

  ## Options for `@handler`

    * `:type` (optional) — `:exclusive`, `:shared`, `:workflow`, or
      `nil`. The default is `:exclusive` for `:virtual_object` and
      `:workflow` services and `nil` for `:service` services.
    * `:name` (optional) — public handler name. Defaults to the
      function's name as a string.

  Two equivalent shorthand forms when there are no options:

      @handler []
      def echo(ctx, x), do: x

      @handler true
      def echo(ctx, x), do: x

  Note: a bare `@handler` (no value) is a no-op in Elixir's
  attribute syntax — it reads the current attribute value rather
  than setting it. Always pass at least `[]` or `true`.

  ## Why use this instead of plain functions

  The pre-macro pattern (still supported) was a plain
  `def name(ctx, input)` function plus a hand-built registration
  map in `Application.start/2`. The macro adds three things on top:

    1. **Compile-time arity check** — typo'd handlers fail at
       compile time, not at the first replay.
    2. **Single source of truth** — the handler list lives next to
       the handler implementations, not in a separate registration
       file that drifts.
    3. **Reflection** — `__restate_service__/0` and
       `__restate_handlers__/0` are introspectable from tests,
       observability tools, or future macro layers (e.g. typed
       call wrappers like `MyService.greet(ctx, "name")` that
       compile-error when a handler is renamed).

  ## Limitations

    * No automatic `@spec` emission. The handler types
      `(Restate.Context.t(), term()) :: term()` are loose enough
      that auto-spec would mostly just suppress useful Dialyzer
      checks. Write your own `@spec` per handler when you want
      the type discipline.
    * `@handler` only has effect on `def` (public). `defp` raises a
      `CompileError`; if you want a private helper, just use a
      plain `defp` without the attribute.
    * Re-using the same handler name within a service is a
      compile error — handler names must be unique on the wire.
  """

  @doc false
  defmacro __using__(opts) do
    type =
      case Keyword.fetch(opts, :type) do
        {:ok, t} when t in [:service, :virtual_object, :workflow] ->
          t

        {:ok, other} ->
          raise ArgumentError,
                "Restate.Service :type must be :service, :virtual_object, or :workflow, " <>
                  "got: #{inspect(other)}"

        :error ->
          raise ArgumentError, "Restate.Service requires a :type option"
      end

    quote bind_quoted: [opts: opts, type: type] do
      Module.register_attribute(__MODULE__, :restate_handlers, accumulate: true, persist: false)
      Module.register_attribute(__MODULE__, :handler, accumulate: false)
      @on_definition Restate.Service
      @before_compile Restate.Service

      @restate_service_type type
      @restate_service_name (case Keyword.get(opts, :name) do
                               nil -> __MODULE__ |> Module.split() |> List.last()
                               name when is_binary(name) -> name
                             end)
    end
  end

  @doc false
  def __on_definition__(env, kind, name, args, _guards, _body) do
    case Module.get_attribute(env.module, :handler) do
      nil ->
        :ok

      raw ->
        # Consume the attribute so it doesn't carry to the next def.
        Module.delete_attribute(env.module, :handler)

        opts = normalize_handler_attr!(env, name, args, raw)
        validate_handler!(env, kind, name, args)
        record_handler!(env, name, args, opts)
    end
  end

  # `@handler` accepts:
  #   * a keyword list — `@handler type: :exclusive` (parsed as
  #     `@handler [type: :exclusive]`) or `@handler []` for the
  #     no-options form on plain `:service` services.
  #   * `true` — equivalent to `@handler []`. Slightly less typing
  #     when there are no options to pass.
  # Anything else is a clear user mistake and we raise so they don't
  # silently get a non-handler.
  defp normalize_handler_attr!(_env, _name, _args, true), do: []
  defp normalize_handler_attr!(_env, _name, _args, opts) when is_list(opts), do: opts

  defp normalize_handler_attr!(env, name, args, other) do
    raise_compile_error(
      env,
      "Restate `@handler` for `#{name}/#{length(args)}` must be a keyword list or `true`, " <>
        "got #{inspect(other)}. " <>
        "Use `@handler type: :exclusive` (or any keyword opts), `@handler []` for no options, " <>
        "or `@handler true` as a marker-only form."
    )
  end

  defp validate_handler!(env, kind, name, args) do
    if kind != :def do
      raise_compile_error(
        env,
        "Restate handler `#{name}/#{length(args)}` must be defined with `def`, " <>
          "got `#{kind}`. Private handlers can't be invoked through the journal — " <>
          "use a plain `defp` (without `@handler`) if you want a private helper."
      )
    end

    if length(args) != 2 do
      raise_compile_error(
        env,
        "Restate handler `#{name}/#{length(args)}` must take exactly 2 arguments " <>
          "(`ctx`, `input`), got #{length(args)}. The first argument is a " <>
          "`%Restate.Context{}`; the second is the JSON-decoded handler input."
      )
    end
  end

  defp record_handler!(env, name, args, opts) do
    public_name =
      case Keyword.get(opts, :name) do
        nil -> Atom.to_string(name)
        bin when is_binary(bin) -> bin
      end

    handler_type =
      case Keyword.get(opts, :type) do
        nil -> nil
        t when t in [:exclusive, :shared, :workflow] -> t
        other ->
          raise_compile_error(
            env,
            "Restate handler `#{name}/#{length(args)}` :type must be " <>
              ":exclusive, :shared, :workflow, or nil — got #{inspect(other)}"
          )
      end

    # Reject duplicate public names within the same service.
    existing = Module.get_attribute(env.module, :restate_handlers) || []

    if Enum.any?(existing, fn h -> h.name == public_name end) do
      raise_compile_error(
        env,
        "Restate handler name `#{public_name}` is declared more than once in " <>
          "#{inspect(env.module)}. Handler names must be unique within a service. " <>
          "Use `@handler name: \"...\"` to give one of them a different public name."
      )
    end

    Module.put_attribute(env.module, :restate_handlers, %{
      name: public_name,
      type: handler_type,
      mfa: {env.module, name, length(args)}
    })
  end

  defp raise_compile_error(env, message) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description: message
  end

  @doc false
  defmacro __before_compile__(env) do
    handlers =
      env.module
      |> Module.get_attribute(:restate_handlers, [])
      # accumulate: true prepends, so reverse for declaration order.
      |> Enum.reverse()

    if handlers == [] do
      raise CompileError,
        file: env.file,
        description:
          "Restate service #{inspect(env.module)} has no handlers. " <>
            "Mark at least one function with `@handler` " <>
            "(`@handler type: :exclusive` for VirtualObject / Workflow, " <>
            "or `@handler` alone for plain Service)."
    end

    service_name = Module.get_attribute(env.module, :restate_service_name)
    service_type = Module.get_attribute(env.module, :restate_service_type)

    caller_funs = build_caller_funs(handlers, service_name)

    caller_block =
      quote do
        defmodule Caller do
          @moduledoc """
          Compile-time-checked typed call wrappers for `#{unquote(service_name)}`.

          Generated automatically from the `@handler`-annotated `def`s
          on the parent service module. Calling a non-existent handler
          through this module is a compile error (the function doesn't
          exist), instead of a runtime 404 from the runtime.

          Each handler `<name>` gets two wrappers:

            * `<name>(ctx, input, opts \\\\ [])` — synchronous request /
              reply via `Restate.Context.call/5`. Returns the decoded
              response, or raises `Restate.TerminalError` if the
              target raised one.

            * `send_<name>(ctx, input, opts \\\\ [])` — fire-and-forget
              via `Restate.Context.send_async/5`. Returns `:ok`
              immediately; the spawned invocation runs independently.

          `opts` are forwarded verbatim to the underlying primitive —
          `:key` for VirtualObject / Workflow targets, `:idempotency_key`
          for de-dupe, etc. See `Restate.Context.call/5` and
          `Restate.Context.send_async/5` for the full option list.
          """
          unquote_splicing(caller_funs)
        end
      end

    quote do
      @doc """
      Service definition for `Restate.Server.Registry.register_service/1`.

      Returns a map shaped:

          %{name: binary, type: atom, handlers: [%{name, type, mfa}]}

      Generated by `Restate.Service` at compile time from the module's
      `@handler`-annotated `def`s. Stable on every call.
      """
      @spec __restate_service__() :: map()
      def __restate_service__ do
        %{
          name: unquote(service_name),
          type: unquote(service_type),
          handlers: unquote(Macro.escape(handlers))
        }
      end

      @doc """
      List of handler descriptors for this service.

      Each entry is `%{name: binary, type: atom | nil, mfa: {module, atom, 2}}`
      in declaration order. Useful for typed-call wrappers, telemetry
      attachments, or test scaffolding that needs to enumerate handlers.
      """
      @spec __restate_handlers__() :: [map()]
      def __restate_handlers__, do: unquote(Macro.escape(handlers))

      unquote(caller_block)
    end
  end

  # Build the list of `def` AST nodes that go inside the generated
  # `Caller` submodule. One synchronous wrapper + one fire-and-forget
  # wrapper per handler. The wrapper's *function* name is the Elixir
  # function atom (`def count`), which keeps user-facing call sites
  # idiomatic Elixir snake_case even if the handler's *public* name
  # was overridden via `@handler name: "publicName"`.
  defp build_caller_funs(handlers, service_name) do
    Enum.flat_map(handlers, fn h ->
      {_mod, fn_atom, _arity} = h.mfa
      send_atom = String.to_atom("send_" <> Atom.to_string(fn_atom))
      public_name = h.name

      [
        quote do
          @doc """
          Sync call to `#{unquote(service_name)}.#{unquote(public_name)}`.
          See `Restate.Context.call/5` for option semantics.
          """
          def unquote(fn_atom)(ctx, input, opts \\ []) do
            Restate.Context.call(
              ctx,
              unquote(service_name),
              unquote(public_name),
              input,
              opts
            )
          end
        end,
        quote do
          @doc """
          Fire-and-forget invocation of `#{unquote(service_name)}.#{unquote(public_name)}`.
          See `Restate.Context.send_async/5` for option semantics.
          """
          def unquote(send_atom)(ctx, input, opts \\ []) do
            Restate.Context.send_async(
              ctx,
              unquote(service_name),
              unquote(public_name),
              input,
              opts
            )
          end
        end
      ]
    end)
  end
end
