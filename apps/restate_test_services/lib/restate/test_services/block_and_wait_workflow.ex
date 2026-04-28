defmodule Restate.TestServices.BlockAndWaitWorkflow do
  @moduledoc """
  Mirror of `dev.restate.sdktesting.contracts.BlockAndWaitWorkflow`
  and `restatedev/sdk-java`'s `BlockAndWaitWorkflowImpl.kt`.

  Demonstrates the Workflow service type — keyed, single-execution-
  per-key, with durable promises as the external coordination
  primitive.

  ## Handlers

    * `run` (`:workflow`) — one-shot per workflow key. Stores the
      input under `"my-state"`, blocks on the durable promise
      `"durable-promise"`, then asserts the promise is resolved
      via `peek_promise/2` before returning the resolved value.

    * `unblock` (`:shared`) — resolves the durable promise. Callable
      from any number of concurrent client requests on the same key
      while `run` is still blocked.

    * `getState` (`:shared`) — read-only state accessor. The
      conformance test polls this to confirm `run` has actually
      stored its input before issuing `unblock`.
  """

  alias Restate.Context

  @state_key "my-state"
  @promise_key "durable-promise"

  def run(%Context{} = ctx, input) when is_binary(input) do
    Context.set_state(ctx, @state_key, input)

    output = Context.get_promise(ctx, @promise_key)

    case Context.peek_promise(ctx, @promise_key) do
      {:ok, _} ->
        output

      _ ->
        raise Restate.TerminalError,
          message: "Durable promise should be completed",
          code: 500
    end
  end

  def unblock(%Context{} = ctx, output) when is_binary(output) do
    Context.complete_promise(ctx, @promise_key, output)
    nil
  end

  def get_state(%Context{} = ctx, _input) do
    Context.get_state(ctx, @state_key)
  end
end
