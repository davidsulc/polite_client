defmodule PoliteClient.AllocatedRequest do
  @type t :: %__MODULE__{
          ref: reference() | nil,
          owner: pid() | nil
        }

  @doc """
  The Allocated struct.

  It represents an HTTP request that has been acknowledged by a partition
  and will be processed asynchronously.

  It contains these fields:
    * `:ref` - the reference identifying the allocated request
    * `:owner` - the PID of the process that made the request
  """
  @enforce_keys [:ref, :owner]
  defstruct ref: nil, owner: nil
end
