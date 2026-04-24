defmodule Dev.Restate.Service.Protocol.ServiceProtocolVersion do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "dev.restate.service.protocol.ServiceProtocolVersion",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :SERVICE_PROTOCOL_VERSION_UNSPECIFIED, 0
  field :V1, 1
  field :V2, 2
  field :V3, 3
  field :V4, 4
  field :V5, 5
  field :V6, 6
end

defmodule Dev.Restate.Service.Protocol.BuiltInSignal do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "dev.restate.service.protocol.BuiltInSignal",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :UNKNOWN, 0
  field :CANCEL, 1
end

defmodule Dev.Restate.Service.Protocol.StartMessage.StateEntry do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.StartMessage.StateEntry",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :bytes
  field :value, 2, type: :bytes
end

defmodule Dev.Restate.Service.Protocol.StartMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.StartMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :id, 1, type: :bytes
  field :debug_id, 2, type: :string, json_name: "debugId"
  field :known_entries, 3, type: :uint32, json_name: "knownEntries"

  field :state_map, 4,
    repeated: true,
    type: Dev.Restate.Service.Protocol.StartMessage.StateEntry,
    json_name: "stateMap"

  field :partial_state, 5, type: :bool, json_name: "partialState"
  field :key, 6, type: :string

  field :retry_count_since_last_stored_entry, 7,
    type: :uint32,
    json_name: "retryCountSinceLastStoredEntry"

  field :duration_since_last_stored_entry, 8,
    type: :uint64,
    json_name: "durationSinceLastStoredEntry"

  field :random_seed, 9, type: :uint64, json_name: "randomSeed"
end

defmodule Dev.Restate.Service.Protocol.SuspensionMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.SuspensionMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :waiting_completions, 1, repeated: true, type: :uint32, json_name: "waitingCompletions"
  field :waiting_signals, 2, repeated: true, type: :uint32, json_name: "waitingSignals"
  field :waiting_named_signals, 3, repeated: true, type: :string, json_name: "waitingNamedSignals"
end

defmodule Dev.Restate.Service.Protocol.ErrorMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.ErrorMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :code, 1, type: :uint32
  field :message, 2, type: :string
  field :stacktrace, 3, type: :string

  field :related_command_index, 4,
    proto3_optional: true,
    type: :uint32,
    json_name: "relatedCommandIndex"

  field :related_command_name, 5,
    proto3_optional: true,
    type: :string,
    json_name: "relatedCommandName"

  field :related_command_type, 6,
    proto3_optional: true,
    type: :uint32,
    json_name: "relatedCommandType"

  field :next_retry_delay, 8, proto3_optional: true, type: :uint64, json_name: "nextRetryDelay"
end

defmodule Dev.Restate.Service.Protocol.EndMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.EndMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
end

defmodule Dev.Restate.Service.Protocol.CommandAckMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.CommandAckMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :command_index, 1, type: :uint32, json_name: "commandIndex"
end

defmodule Dev.Restate.Service.Protocol.ProposeRunCompletionMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.ProposeRunCompletionMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :result_completion_id, 1, type: :uint32, json_name: "resultCompletionId"
  field :value, 14, type: :bytes, oneof: 0
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
end

defmodule Dev.Restate.Service.Protocol.NotificationTemplate do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.NotificationTemplate",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :id, 0

  oneof :result, 1

  field :completion_id, 1, type: :uint32, json_name: "completionId", oneof: 0
  field :signal_id, 2, type: :uint32, json_name: "signalId", oneof: 0
  field :signal_name, 3, type: :string, json_name: "signalName", oneof: 0
  field :void, 4, type: Dev.Restate.Service.Protocol.Void, oneof: 1
  field :value, 5, type: Dev.Restate.Service.Protocol.Value, oneof: 1
  field :failure, 6, type: Dev.Restate.Service.Protocol.Failure, oneof: 1
  field :invocation_id, 16, type: :string, json_name: "invocationId", oneof: 1

  field :state_keys, 17,
    type: Dev.Restate.Service.Protocol.StateKeys,
    json_name: "stateKeys",
    oneof: 1
end

defmodule Dev.Restate.Service.Protocol.InputCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.InputCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :headers, 1, repeated: true, type: Dev.Restate.Service.Protocol.Header
  field :value, 14, type: Dev.Restate.Service.Protocol.Value
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.OutputCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.OutputCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :value, 14, type: Dev.Restate.Service.Protocol.Value, oneof: 0
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.GetLazyStateCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetLazyStateCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :bytes
  field :result_completion_id, 11, type: :uint32, json_name: "resultCompletionId"
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.GetLazyStateCompletionNotificationMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetLazyStateCompletionNotificationMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :completion_id, 1, type: :uint32, json_name: "completionId"
  field :void, 4, type: Dev.Restate.Service.Protocol.Void, oneof: 0
  field :value, 5, type: Dev.Restate.Service.Protocol.Value, oneof: 0
end

defmodule Dev.Restate.Service.Protocol.SetStateCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.SetStateCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :bytes
  field :value, 3, type: Dev.Restate.Service.Protocol.Value
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.ClearStateCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.ClearStateCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :bytes
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.ClearAllStateCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.ClearAllStateCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.GetLazyStateKeysCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetLazyStateKeysCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :result_completion_id, 11, type: :uint32, json_name: "resultCompletionId"
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.GetLazyStateKeysCompletionNotificationMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetLazyStateKeysCompletionNotificationMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :completion_id, 1, type: :uint32, json_name: "completionId"
  field :state_keys, 17, type: Dev.Restate.Service.Protocol.StateKeys, json_name: "stateKeys"
end

defmodule Dev.Restate.Service.Protocol.GetEagerStateCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetEagerStateCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :key, 1, type: :bytes
  field :void, 13, type: Dev.Restate.Service.Protocol.Void, oneof: 0
  field :value, 14, type: Dev.Restate.Service.Protocol.Value, oneof: 0
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.GetEagerStateKeysCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetEagerStateKeysCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :value, 14, type: Dev.Restate.Service.Protocol.StateKeys
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.GetPromiseCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetPromiseCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :result_completion_id, 11, type: :uint32, json_name: "resultCompletionId"
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.GetPromiseCompletionNotificationMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetPromiseCompletionNotificationMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :completion_id, 1, type: :uint32, json_name: "completionId"
  field :value, 5, type: Dev.Restate.Service.Protocol.Value, oneof: 0
  field :failure, 6, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
end

defmodule Dev.Restate.Service.Protocol.PeekPromiseCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.PeekPromiseCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :result_completion_id, 11, type: :uint32, json_name: "resultCompletionId"
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.PeekPromiseCompletionNotificationMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.PeekPromiseCompletionNotificationMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :completion_id, 1, type: :uint32, json_name: "completionId"
  field :void, 4, type: Dev.Restate.Service.Protocol.Void, oneof: 0
  field :value, 5, type: Dev.Restate.Service.Protocol.Value, oneof: 0
  field :failure, 6, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
end

defmodule Dev.Restate.Service.Protocol.CompletePromiseCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.CompletePromiseCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :completion, 0

  field :key, 1, type: :string

  field :completion_value, 2,
    type: Dev.Restate.Service.Protocol.Value,
    json_name: "completionValue",
    oneof: 0

  field :completion_failure, 3,
    type: Dev.Restate.Service.Protocol.Failure,
    json_name: "completionFailure",
    oneof: 0

  field :result_completion_id, 11, type: :uint32, json_name: "resultCompletionId"
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.CompletePromiseCompletionNotificationMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.CompletePromiseCompletionNotificationMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :completion_id, 1, type: :uint32, json_name: "completionId"
  field :void, 4, type: Dev.Restate.Service.Protocol.Void, oneof: 0
  field :failure, 6, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
end

defmodule Dev.Restate.Service.Protocol.SleepCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.SleepCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :wake_up_time, 1, type: :uint64, json_name: "wakeUpTime"
  field :result_completion_id, 11, type: :uint32, json_name: "resultCompletionId"
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.SleepCompletionNotificationMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.SleepCompletionNotificationMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :completion_id, 1, type: :uint32, json_name: "completionId"
  field :void, 4, type: Dev.Restate.Service.Protocol.Void
end

defmodule Dev.Restate.Service.Protocol.CallCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.CallCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :handler_name, 2, type: :string, json_name: "handlerName"
  field :parameter, 3, type: :bytes
  field :headers, 4, repeated: true, type: Dev.Restate.Service.Protocol.Header
  field :key, 5, type: :string
  field :idempotency_key, 6, proto3_optional: true, type: :string, json_name: "idempotencyKey"

  field :invocation_id_notification_idx, 10,
    type: :uint32,
    json_name: "invocationIdNotificationIdx"

  field :result_completion_id, 11, type: :uint32, json_name: "resultCompletionId"
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.CallInvocationIdCompletionNotificationMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.CallInvocationIdCompletionNotificationMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :completion_id, 1, type: :uint32, json_name: "completionId"
  field :invocation_id, 16, type: :string, json_name: "invocationId"
end

defmodule Dev.Restate.Service.Protocol.CallCompletionNotificationMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.CallCompletionNotificationMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :completion_id, 1, type: :uint32, json_name: "completionId"
  field :value, 5, type: Dev.Restate.Service.Protocol.Value, oneof: 0
  field :failure, 6, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
end

defmodule Dev.Restate.Service.Protocol.OneWayCallCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.OneWayCallCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :handler_name, 2, type: :string, json_name: "handlerName"
  field :parameter, 3, type: :bytes
  field :invoke_time, 4, type: :uint64, json_name: "invokeTime"
  field :headers, 5, repeated: true, type: Dev.Restate.Service.Protocol.Header
  field :key, 6, type: :string
  field :idempotency_key, 7, proto3_optional: true, type: :string, json_name: "idempotencyKey"

  field :invocation_id_notification_idx, 10,
    type: :uint32,
    json_name: "invocationIdNotificationIdx"

  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.SendSignalCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.SendSignalCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :signal_id, 0

  oneof :result, 1

  field :target_invocation_id, 1, type: :string, json_name: "targetInvocationId"
  field :idx, 2, type: :uint32, oneof: 0
  field :name, 3, type: :string, oneof: 0
  field :void, 4, type: Dev.Restate.Service.Protocol.Void, oneof: 1
  field :value, 5, type: Dev.Restate.Service.Protocol.Value, oneof: 1
  field :failure, 6, type: Dev.Restate.Service.Protocol.Failure, oneof: 1
  field :entry_name, 12, type: :string, json_name: "entryName"
end

defmodule Dev.Restate.Service.Protocol.RunCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.RunCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :result_completion_id, 11, type: :uint32, json_name: "resultCompletionId"
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.RunCompletionNotificationMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.RunCompletionNotificationMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :completion_id, 1, type: :uint32, json_name: "completionId"
  field :value, 5, type: Dev.Restate.Service.Protocol.Value, oneof: 0
  field :failure, 6, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
end

defmodule Dev.Restate.Service.Protocol.AttachInvocationCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.AttachInvocationCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :target, 0

  field :invocation_id, 1, type: :string, json_name: "invocationId", oneof: 0

  field :idempotent_request_target, 3,
    type: Dev.Restate.Service.Protocol.IdempotentRequestTarget,
    json_name: "idempotentRequestTarget",
    oneof: 0

  field :workflow_target, 4,
    type: Dev.Restate.Service.Protocol.WorkflowTarget,
    json_name: "workflowTarget",
    oneof: 0

  field :result_completion_id, 11, type: :uint32, json_name: "resultCompletionId"
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.AttachInvocationCompletionNotificationMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.AttachInvocationCompletionNotificationMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :completion_id, 1, type: :uint32, json_name: "completionId"
  field :value, 5, type: Dev.Restate.Service.Protocol.Value, oneof: 0
  field :failure, 6, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
end

defmodule Dev.Restate.Service.Protocol.GetInvocationOutputCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetInvocationOutputCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :target, 0

  field :invocation_id, 1, type: :string, json_name: "invocationId", oneof: 0

  field :idempotent_request_target, 3,
    type: Dev.Restate.Service.Protocol.IdempotentRequestTarget,
    json_name: "idempotentRequestTarget",
    oneof: 0

  field :workflow_target, 4,
    type: Dev.Restate.Service.Protocol.WorkflowTarget,
    json_name: "workflowTarget",
    oneof: 0

  field :result_completion_id, 11, type: :uint32, json_name: "resultCompletionId"
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.GetInvocationOutputCompletionNotificationMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetInvocationOutputCompletionNotificationMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :completion_id, 1, type: :uint32, json_name: "completionId"
  field :void, 4, type: Dev.Restate.Service.Protocol.Void, oneof: 0
  field :value, 5, type: Dev.Restate.Service.Protocol.Value, oneof: 0
  field :failure, 6, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
end

defmodule Dev.Restate.Service.Protocol.CompleteAwakeableCommandMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.CompleteAwakeableCommandMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :awakeable_id, 1, type: :string, json_name: "awakeableId"
  field :value, 2, type: Dev.Restate.Service.Protocol.Value, oneof: 0
  field :failure, 3, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.SignalNotificationMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.SignalNotificationMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :signal_id, 0

  oneof :result, 1

  field :idx, 2, type: :uint32, oneof: 0
  field :name, 3, type: :string, oneof: 0
  field :void, 4, type: Dev.Restate.Service.Protocol.Void, oneof: 1
  field :value, 5, type: Dev.Restate.Service.Protocol.Value, oneof: 1
  field :failure, 6, type: Dev.Restate.Service.Protocol.Failure, oneof: 1
end

defmodule Dev.Restate.Service.Protocol.StateKeys do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.StateKeys",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :keys, 1, repeated: true, type: :bytes
end

defmodule Dev.Restate.Service.Protocol.Value do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.Value",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :content, 1, type: :bytes
end

defmodule Dev.Restate.Service.Protocol.Failure do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.Failure",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :code, 1, type: :uint32
  field :message, 2, type: :string
  field :metadata, 3, repeated: true, type: Dev.Restate.Service.Protocol.FailureMetadata
end

defmodule Dev.Restate.Service.Protocol.FailureMetadata do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.FailureMetadata",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Dev.Restate.Service.Protocol.Header do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.Header",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Dev.Restate.Service.Protocol.WorkflowTarget do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.WorkflowTarget",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :workflow_name, 1, type: :string, json_name: "workflowName"
  field :workflow_key, 2, type: :string, json_name: "workflowKey"
end

defmodule Dev.Restate.Service.Protocol.IdempotentRequestTarget do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.IdempotentRequestTarget",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :service_key, 2, proto3_optional: true, type: :string, json_name: "serviceKey"
  field :handler_name, 3, type: :string, json_name: "handlerName"
  field :idempotency_key, 4, type: :string, json_name: "idempotencyKey"
end

defmodule Dev.Restate.Service.Protocol.Void do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.Void",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
end
