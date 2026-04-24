defmodule Restate.Protocol.Messages do
  @moduledoc """
  V3 service-protocol message-type registry.

  Maps the 16-bit on-the-wire type ID to the generated protobuf module and
  back. IDs are pulled from the V3 spec table in
  `proto/service-invocation-protocol.md` and cross-checked against
  `sdk-java` v1.2.0 (the last release on the V3 line). The spec's State
  entries table has a typo — SetState/ClearState/ClearAllState IDs are one
  off; the values below match sdk-java and the wire format.
  """

  alias Dev.Restate.Service.Protocol, as: Pb

  @type_to_module %{
    0x0000 => Pb.StartMessage,
    0x0001 => Pb.CompletionMessage,
    0x0002 => Pb.SuspensionMessage,
    0x0003 => Pb.ErrorMessage,
    0x0004 => Pb.EntryAckMessage,
    0x0005 => Pb.EndMessage,
    0x0400 => Pb.InputEntryMessage,
    0x0401 => Pb.OutputEntryMessage,
    0x0800 => Pb.GetStateEntryMessage,
    0x0801 => Pb.SetStateEntryMessage,
    0x0802 => Pb.ClearStateEntryMessage,
    0x0803 => Pb.ClearAllStateEntryMessage,
    0x0804 => Pb.GetStateKeysEntryMessage,
    0x0808 => Pb.GetPromiseEntryMessage,
    0x0809 => Pb.PeekPromiseEntryMessage,
    0x080A => Pb.CompletePromiseEntryMessage,
    0x0C00 => Pb.SleepEntryMessage,
    0x0C01 => Pb.CallEntryMessage,
    0x0C02 => Pb.OneWayCallEntryMessage,
    0x0C03 => Pb.AwakeableEntryMessage,
    0x0C04 => Pb.CompleteAwakeableEntryMessage,
    0x0C05 => Pb.RunEntryMessage,
    0x0C06 => Pb.CancelInvocationEntryMessage,
    0x0C07 => Pb.GetCallInvocationIdEntryMessage,
    0x0C08 => Pb.AttachInvocationEntryMessage,
    0x0C09 => Pb.GetInvocationOutputEntryMessage
  }

  @module_to_type Map.new(@type_to_module, fn {type, mod} -> {mod, type} end)

  @doc "Wire type ID for a generated protobuf module, or nil if unknown."
  @spec type_for_module(module()) :: 0..0xFFFF | nil
  def type_for_module(module), do: Map.get(@module_to_type, module)

  @doc "Generated protobuf module for a wire type ID, or nil if unknown."
  @spec module_for_type(0..0xFFFF) :: module() | nil
  def module_for_type(type), do: Map.get(@type_to_module, type)
end
