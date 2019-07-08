defmodule PoliteClient.Partition.PendingRequest do
  @moduledoc false
  @doc """
  Struct representing a request that will be executed later.
  """

  alias PoliteClient.{AllocatedRequest, Client}

  @type t :: %__MODULE__{
          allocation: AllocatedRequest.t(),
          request: Client.request(),
          task: nil | Task.t(),
          retries: non_neg_integer()
        }

  @enforce_keys [:allocation, :request]
  defstruct allocation: nil, request: nil, task: nil, retries: 0

  @spec get_allocation(t()) :: AllocatedRequest.t()
  def get_allocation(%__MODULE__{allocation: allocation}), do: allocation

  @spec for_allocation?(pending_request :: t(), allocation :: AllocatedRequest.t()) :: boolean()
  def for_allocation?(%__MODULE__{} = pending_request, %AllocatedRequest{} = allocation) do
    pending_request
    |> get_allocation()
    |> AllocatedRequest.same?(allocation)
  end
end
