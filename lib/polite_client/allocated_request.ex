defmodule PoliteClient.AllocatedRequest do
  @type t :: %__MODULE__{
          ref: reference(),
          owner: pid(),
          partition: String.t()
        }

  @doc """
  The Allocated struct.

  It represents an HTTP request that has been acknowledged by a partition
  and will be processed asynchronously.

  It contains these fields:
    * `:ref` - the reference identifying the allocated request
    * `:owner` - the PID of the process that made the request
    * `:partition` - the key of the partition in which the request has been allocated
  """
  @enforce_keys [:ref, :owner, :partition]
  defstruct [:ref, :owner, :partition]
end
