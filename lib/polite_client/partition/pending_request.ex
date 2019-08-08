defmodule PoliteClient.Partition.PendingRequest do
  @moduledoc false
  @doc """
  Struct representing a request that will be executed later.
  """

  alias PoliteClient.{AllocatedRequest, Client}

  @type t :: %__MODULE__{
          allocation: AllocatedRequest.t(),
          request: Client.request(),
          client: Client.t(),
          task: nil | Task.t(),
          retries: non_neg_integer()
        }

  @enforce_keys [:allocation, :request, :client]
  defstruct allocation: nil, request: nil, client: nil, task: nil, retries: 0

  @spec get_allocation(t()) :: AllocatedRequest.t()
  def get_allocation(%__MODULE__{allocation: allocation}), do: allocation

  @spec for_allocation?(pending_request :: t(), allocation :: AllocatedRequest.t()) :: boolean()
  def for_allocation?(%__MODULE__{} = pending_request, %AllocatedRequest{} = allocation) do
    pending_request
    |> get_allocation()
    |> AllocatedRequest.same?(allocation)
  end

  @doc "Cancels a pending request and notifies the caller."
  @spec cancel(t()) :: no_return()
  def cancel(%__MODULE__{} = pending_request) do
    allocated_request = get_allocation(pending_request)

    pending_request
    |> shutdown_associated_task()
    |> case do
      {:ok, {_duration, result}} -> AllocatedRequest.send_result(allocated_request, result)
      _ -> AllocatedRequest.cancel_and_notify(allocated_request)
    end
  end

  @doc "Returns true if the process owning the allocation is alive."
  @spec owner_alive?(t()) :: boolean()
  def owner_alive?(%__MODULE__{allocation: allocation}),
    do: AllocatedRequest.owner_alive?(allocation)

  defp shutdown_associated_task(%__MODULE__{task: nil}), do: :no_task
  defp shutdown_associated_task(%__MODULE__{task: task}), do: Task.shutdown(task)
end
