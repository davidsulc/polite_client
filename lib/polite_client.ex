defmodule PoliteClient do
  @moduledoc """
  Documentation for PoliteClient.
  """

  alias PoliteClient.{AllocatedRequest, Partition, PartitionsMgr}

  @type partition_key :: Registry.key()

  # TODO
  # Document: to "convert" into a sync request:
  # case async_request(method, url, headers, body, opts) do
  #   {:error, _} = error -> error
  #   {:queued, ref} when is_reference(ref) -> await_result(ref)
  #   ref when is_reference(ref) -> await_result(ref)
  # end
  # Warn about potential long blocking time on queued requests
  # => need to have a timeout value
  #
  # (note an `after` clause can be added to have a timeout)
  # defp await_result(ref) when is_reference(ref) do
  #   receive do
  #     {^ref, result} -> result
  #   end
  # end
  @doc """
  Performs a request asynchronously.

  The caller will immediately receive a `t:PoliteClient.AllocatedRequest.t/0` struct representing
  the async request.

  ## Message format

  The reply sent upon completion of the request will be in the format `{ref, result}`, where `ref` is
  the reference held by the `t:PoliteClient.AllocatedRequest.t/0` struct, and `result` is the return
  value of the partition's request client (`t:PoliteClient.Client.t/0`).
  """
  @spec async_request(key :: partition_key(), request :: PoliteClient.Client.request()) ::
          AllocatedRequest.t()
  def async_request(key, request) do
    with_partition(key, &Partition.async_request(&1, request))
  end

  @doc """
  Tells whether the `allocated_request` is still allocated.

  Allocations may be lost in the event of partition crashes.

  TODO should caller be able to monitor partition?
  """
  @spec allocated?(allocated_request :: AllocatedRequest.t()) :: boolean()
  def allocated?(%AllocatedRequest{partition: key, ref: ref}) do
    PartitionsMgr.allocated?(key, ref)
  end

  @doc """
  Cancels a request.

  Assuming the `allocated_request` was know to the partition, the caller will receive a
  `{ref, :canceled}` message, where `ref` is the reference matching `allocated_request.ref`.

  If the request is unknown (already executed, lost due to crash, etc.) the cancelation
  will be a no op.
  """
  @spec cancel(allocated_request :: AllocatedRequest.t()) :: :ok
  def cancel(%AllocatedRequest{partition: key} = allocated_request) do
    PartitionsMgr.cancel(key, allocated_request)
  end

  @doc """
  Returns a partition to active duty.

  Upon resuming, the partition will again begin accepting and executing requests on behalf
  of callers. When a partition is resumed, its rate limiter and health checker states are
  reinitialized (with their respective `initial_state` values). As a consequence, the next
  request will be sent immediately.

  If the partition was already active, this is a no op.
  """
  @spec resume(key :: partition_key()) :: :ok | {:error, :no_partition}
  def resume(key), do: with_partition(key, &Partition.resume/1)

  @doc """
  Suspends the partition.

  Will suspend the partition idendified by `key` if it exists (otherwise, `{:error, :no_partition}`
  is returned). While suspended, a partition will only respond to the following:

  * `PoliteClient.allocated?/1`
  * `PoliteClient.cancel/1`
  * `PoliteClient.resume/1`

  All other calls will return `{:error, :suspended}`.
  """
  @spec suspend(key :: partition_key(), opts :: Keyword.t()) :: :ok | {:error, :no_partition}
  def suspend(key, opts \\ []), do: with_partition(key, &Partition.suspend(&1, opts))

  defp with_partition(key, fun) do
    case PartitionsMgr.find_name(key) do
      {:ok, via_tuple} ->
        fun.(via_tuple)

      :not_found ->
        {:error, :no_partition}
    end
  end

  @doc """
  Starts a partition.

  The `key` identifies the parttion, and must be unique. If a partition is already active with the
  given `key`, `{:error, {:key_conflict, pid}}` will be returned, where `pid` is the pid of the
  existing partition identified by `key`.

  Partitions are independent from one another, in particular their health checker and rate limiter
  states are not shared. Therefore, a partition can have a more restrictive rate limiter, or a more
  forgiving health checker implementation.

  These options MUST be provided:

  * `client` - the `t:PoliteClient.Client.t()` implementation to use when executing requests

  These options MAY be provided:
  TODO

  * `rate_limiter` - a  valid `t:PoliteClient.RateLimiter.config/0`
  * `health_checker` - a  valid `t:PoliteClient.HealthChecker.config/0`
  * `max_retries`
  * `max_queued`
  """
  @spec start_partition(key :: partition_key(), opts :: Keyword.t()) ::
          :ok
          | {:error, {:key_conflict, pid()}}
          | {:error, :max_partitions}
  defdelegate start_partition(key, opts \\ []), to: PartitionsMgr, as: :start

  @doc "Suspends all partitions."
  defdelegate suspend_all(opts), to: PartitionsMgr
end
