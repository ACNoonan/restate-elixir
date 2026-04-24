defmodule Restate.Protocol.Messages do
  @moduledoc """
  V5 service-protocol message-type registry.

  Maps the 16-bit on-the-wire type ID to the generated protobuf module and
  back. V5 partitions the 16-bit space into three namespaces:

    * `0x0000` — control frames (Start/Suspension/Error/End/CommandAck/
      ProposeRunCompletion)
    * `0x0400` — Command messages (SDK → runtime journal entries)
    * `0x8000` — Notification messages (runtime → SDK completions)

  IDs are taken from the inline `Type:` comments in `protocol.proto` and
  cross-checked against `sdk-java` HEAD's `MessageType.java`. Two values
  the proto comments don't capture cleanly:

    * `SendSignalCommandMessage = 0x0410` (proto comment has a stray `0`:
      it reads `0x04000 + 10`; canonical is `0x0400 + 0x10`).
    * `SignalNotificationMessage = 0xFBFF` (one below the custom-entry
      range that starts at `0xFC00`).
  """

  alias Dev.Restate.Service.Protocol, as: Pb

  @type_to_module %{
    # --- Control frames (0x0000 namespace) ---
    0x0000 => Pb.StartMessage,
    0x0001 => Pb.SuspensionMessage,
    0x0002 => Pb.ErrorMessage,
    0x0003 => Pb.EndMessage,
    0x0004 => Pb.CommandAckMessage,
    0x0005 => Pb.ProposeRunCompletionMessage,

    # --- Commands (0x0400 namespace) ---
    0x0400 => Pb.InputCommandMessage,
    0x0401 => Pb.OutputCommandMessage,
    0x0402 => Pb.GetLazyStateCommandMessage,
    0x0403 => Pb.SetStateCommandMessage,
    0x0404 => Pb.ClearStateCommandMessage,
    0x0405 => Pb.ClearAllStateCommandMessage,
    0x0406 => Pb.GetLazyStateKeysCommandMessage,
    0x0407 => Pb.GetEagerStateCommandMessage,
    0x0408 => Pb.GetEagerStateKeysCommandMessage,
    0x0409 => Pb.GetPromiseCommandMessage,
    0x040A => Pb.PeekPromiseCommandMessage,
    0x040B => Pb.CompletePromiseCommandMessage,
    0x040C => Pb.SleepCommandMessage,
    0x040D => Pb.CallCommandMessage,
    0x040E => Pb.OneWayCallCommandMessage,
    0x0410 => Pb.SendSignalCommandMessage,
    0x0411 => Pb.RunCommandMessage,
    0x0412 => Pb.AttachInvocationCommandMessage,
    0x0413 => Pb.GetInvocationOutputCommandMessage,
    0x0414 => Pb.CompleteAwakeableCommandMessage,

    # --- Notifications (0x8000 namespace) ---
    0x8002 => Pb.GetLazyStateCompletionNotificationMessage,
    0x8006 => Pb.GetLazyStateKeysCompletionNotificationMessage,
    0x8009 => Pb.GetPromiseCompletionNotificationMessage,
    0x800A => Pb.PeekPromiseCompletionNotificationMessage,
    0x800B => Pb.CompletePromiseCompletionNotificationMessage,
    0x800C => Pb.SleepCompletionNotificationMessage,
    0x800D => Pb.CallCompletionNotificationMessage,
    0x800E => Pb.CallInvocationIdCompletionNotificationMessage,
    0x8011 => Pb.RunCompletionNotificationMessage,
    0x8012 => Pb.AttachInvocationCompletionNotificationMessage,
    0x8013 => Pb.GetInvocationOutputCompletionNotificationMessage,
    0xFBFF => Pb.SignalNotificationMessage
  }

  @module_to_type Map.new(@type_to_module, fn {type, mod} -> {mod, type} end)

  @doc "Wire type ID for a generated protobuf module, or nil if unknown."
  @spec type_for_module(module()) :: 0..0xFFFF | nil
  def type_for_module(module), do: Map.get(@module_to_type, module)

  @doc "Generated protobuf module for a wire type ID, or nil if unknown."
  @spec module_for_type(0..0xFFFF) :: module() | nil
  def module_for_type(type), do: Map.get(@type_to_module, type)
end
