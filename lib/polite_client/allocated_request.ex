defmodule PoliteClient.AllocatedRequest do
  @moduledoc """
  Struct representing requests that are acknowledged by the `PoliteClient`, as well
  as related functions.

  Allocated requests are acknowledgements from the PoliteClient regarding requests
  made by clients: when an AllocatedRequest is received, it signifies that the PoliteClient
  will make a best effort attempt to execute the request.

  Caller will be sent a message tagged with the AllocatedRequest's `ref` value to provide the
  request's result.
  """

  @typedoc """
  The AllocatedRequest type.

  See `%PoliteClient.AllocatedRequest{}` for information about each field of the structure.
  """
  @type t :: %__MODULE__{
          ref: reference(),
          owner: pid(),
          partition: PoliteClient.partition_key()
        }

  @doc """
  The AllocatedRequest struct.

  It represents an HTTP request that has been acknowledged by a partition
  and will be processed asynchronously.

  It contains these fields:
    * `:ref` - the reference identifying the allocated request
    * `:owner` - the PID of the process that made the request
    * `:partition` - the key of the partition in which the request has been allocated
  """
  @enforce_keys [:ref, :owner, :partition]
  defstruct [:ref, :owner, :partition]

  @doc "Returns true if both `%PoliteClient.AllocatedRequest{}`s have the same `ref` value."
  @spec same?(left :: t(), right :: t()) :: boolean()
  def same?(%__MODULE__{ref: ref}, %__MODULE__{ref: ref}), do: true
  def same?(_left, _right), do: false

  def cancel_and_notify(%__MODULE__{ref: ref, owner: pid}) do
    Process.demonitor(ref, [:flush])
    send(pid, {ref, :canceled})
  end

  @doc "Returns true if the process owning the allocated request is alive."
  @spec owner_alive?(t()) :: boolean()
  def owner_alive?(%__MODULE__{owner: pid}), do: Process.alive?(pid)

  def send_result(%__MODULE__{ref: ref, owner: pid}, result), do: send(pid, {ref, result})
end
