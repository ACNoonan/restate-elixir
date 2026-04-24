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
end

defmodule Dev.Restate.Service.Protocol.CompletionMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.CompletionMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :entry_index, 1, type: :uint32, json_name: "entryIndex"
  field :empty, 13, type: Dev.Restate.Service.Protocol.Empty, oneof: 0
  field :value, 14, type: :bytes, oneof: 0
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
end

defmodule Dev.Restate.Service.Protocol.SuspensionMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.SuspensionMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :entry_indexes, 1, repeated: true, type: :uint32, json_name: "entryIndexes"
end

defmodule Dev.Restate.Service.Protocol.ErrorMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.ErrorMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :code, 1, type: :uint32
  field :message, 2, type: :string
  field :description, 3, type: :string

  field :related_entry_index, 4,
    proto3_optional: true,
    type: :uint32,
    json_name: "relatedEntryIndex"

  field :related_entry_name, 5,
    proto3_optional: true,
    type: :string,
    json_name: "relatedEntryName"

  field :related_entry_type, 6,
    proto3_optional: true,
    type: :uint32,
    json_name: "relatedEntryType"

  field :next_retry_delay, 8, proto3_optional: true, type: :uint64, json_name: "nextRetryDelay"
end

defmodule Dev.Restate.Service.Protocol.EntryAckMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.EntryAckMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :entry_index, 1, type: :uint32, json_name: "entryIndex"
end

defmodule Dev.Restate.Service.Protocol.EndMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.EndMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
end

defmodule Dev.Restate.Service.Protocol.InputEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.InputEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :headers, 1, repeated: true, type: Dev.Restate.Service.Protocol.Header
  field :value, 14, type: :bytes
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.OutputEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.OutputEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :value, 14, type: :bytes, oneof: 0
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.GetStateEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetStateEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :key, 1, type: :bytes
  field :empty, 13, type: Dev.Restate.Service.Protocol.Empty, oneof: 0
  field :value, 14, type: :bytes, oneof: 0
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.SetStateEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.SetStateEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :bytes
  field :value, 3, type: :bytes
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.ClearStateEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.ClearStateEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :bytes
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.ClearAllStateEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.ClearAllStateEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.GetStateKeysEntryMessage.StateKeys do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetStateKeysEntryMessage.StateKeys",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :keys, 1, repeated: true, type: :bytes
end

defmodule Dev.Restate.Service.Protocol.GetStateKeysEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetStateKeysEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :value, 14,
    type: Dev.Restate.Service.Protocol.GetStateKeysEntryMessage.StateKeys,
    oneof: 0

  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.GetPromiseEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetPromiseEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :key, 1, type: :string
  field :value, 14, type: :bytes, oneof: 0
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.PeekPromiseEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.PeekPromiseEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :key, 1, type: :string
  field :empty, 13, type: Dev.Restate.Service.Protocol.Empty, oneof: 0
  field :value, 14, type: :bytes, oneof: 0
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.CompletePromiseEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.CompletePromiseEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :completion, 0

  oneof :result, 1

  field :key, 1, type: :string
  field :completion_value, 2, type: :bytes, json_name: "completionValue", oneof: 0

  field :completion_failure, 3,
    type: Dev.Restate.Service.Protocol.Failure,
    json_name: "completionFailure",
    oneof: 0

  field :empty, 13, type: Dev.Restate.Service.Protocol.Empty, oneof: 1
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 1
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.SleepEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.SleepEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :wake_up_time, 1, type: :uint64, json_name: "wakeUpTime"
  field :empty, 13, type: Dev.Restate.Service.Protocol.Empty, oneof: 0
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.CallEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.CallEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :handler_name, 2, type: :string, json_name: "handlerName"
  field :parameter, 3, type: :bytes
  field :headers, 4, repeated: true, type: Dev.Restate.Service.Protocol.Header
  field :key, 5, type: :string
  field :idempotency_key, 6, proto3_optional: true, type: :string, json_name: "idempotencyKey"
  field :value, 14, type: :bytes, oneof: 0
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.OneWayCallEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.OneWayCallEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :handler_name, 2, type: :string, json_name: "handlerName"
  field :parameter, 3, type: :bytes
  field :invoke_time, 4, type: :uint64, json_name: "invokeTime"
  field :headers, 5, repeated: true, type: Dev.Restate.Service.Protocol.Header
  field :key, 6, type: :string
  field :idempotency_key, 7, proto3_optional: true, type: :string, json_name: "idempotencyKey"
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.AwakeableEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.AwakeableEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :value, 14, type: :bytes, oneof: 0
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.CompleteAwakeableEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.CompleteAwakeableEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :id, 1, type: :string
  field :value, 14, type: :bytes, oneof: 0
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.RunEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.RunEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :value, 14, type: :bytes, oneof: 0
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.CancelInvocationEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.CancelInvocationEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :target, 0

  field :invocation_id, 1, type: :string, json_name: "invocationId", oneof: 0
  field :call_entry_index, 2, type: :uint32, json_name: "callEntryIndex", oneof: 0
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.GetCallInvocationIdEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetCallInvocationIdEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :result, 0

  field :call_entry_index, 1, type: :uint32, json_name: "callEntryIndex"
  field :value, 14, type: :string, oneof: 0
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 0
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.AttachInvocationEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.AttachInvocationEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :target, 0

  oneof :result, 1

  field :invocation_id, 1, type: :string, json_name: "invocationId", oneof: 0
  field :call_entry_index, 2, type: :uint32, json_name: "callEntryIndex", oneof: 0

  field :idempotent_request_target, 3,
    type: Dev.Restate.Service.Protocol.IdempotentRequestTarget,
    json_name: "idempotentRequestTarget",
    oneof: 0

  field :workflow_target, 4,
    type: Dev.Restate.Service.Protocol.WorkflowTarget,
    json_name: "workflowTarget",
    oneof: 0

  field :value, 14, type: :bytes, oneof: 1
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 1
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.GetInvocationOutputEntryMessage do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.GetInvocationOutputEntryMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :target, 0

  oneof :result, 1

  field :invocation_id, 1, type: :string, json_name: "invocationId", oneof: 0
  field :call_entry_index, 2, type: :uint32, json_name: "callEntryIndex", oneof: 0

  field :idempotent_request_target, 3,
    type: Dev.Restate.Service.Protocol.IdempotentRequestTarget,
    json_name: "idempotentRequestTarget",
    oneof: 0

  field :workflow_target, 4,
    type: Dev.Restate.Service.Protocol.WorkflowTarget,
    json_name: "workflowTarget",
    oneof: 0

  field :empty, 13, type: Dev.Restate.Service.Protocol.Empty, oneof: 1
  field :value, 14, type: :bytes, oneof: 1
  field :failure, 15, type: Dev.Restate.Service.Protocol.Failure, oneof: 1
  field :name, 12, type: :string
end

defmodule Dev.Restate.Service.Protocol.Failure do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.Failure",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :code, 1, type: :uint32
  field :message, 2, type: :string
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

defmodule Dev.Restate.Service.Protocol.Empty do
  @moduledoc false

  use Protobuf,
    full_name: "dev.restate.service.protocol.Empty",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
end
