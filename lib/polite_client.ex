defmodule PoliteClient do
  @moduledoc """
  Documentation for PoliteClient.
  """

  alias PoliteClient.{AllocatedRequest, Partition, PartitionsMgr}

  @type partition_key :: Registry.key()

  @doc """
  Performs a request asynchronously.

  If the request has been successfully acknowledged, the caller will immediately receive a
  `t:PoliteClient.AllocatedRequest.t/0` struct representing the async request.

  ## Message format

  The reply sent in relation to the request will be in the format `{ref, result}`, where `ref` is
  the reference held by the `t:PoliteClient.AllocatedRequest.t/0` struct, and `result` is one of:

  * the `t:PoliteClient.Client.result/0` return value of the partition's `t:PoliteClient.Client.t/0` request client
  * `{:error, {:retries_exhausted, last_error}}` where `last_error is the `t:PoliteClient.Client.error returned by the partition's
  request client (`t:PoliteClient.Client.t/0`) during the last retry attempt (i.e. it will be an instance of the
  `t:PoliteClient.Client.rasult/0` error case)
  * `{:error, {:task_failed, reason}}` if the task executing the request (via the client) fails

  ## Example

  In the examples below, the `:client` value would typically be a function making a request via an
  HTTP client (such as Hackney, Tesla, HTTPotion, Mojito, etc.).

  iex> PoliteClient.start_partition(:my_partition, client: fn _ -> {:ok, :foo} end)
  iex> %PoliteClient.AllocatedRequest{ref: ref} = PoliteClient.async_request(:my_partition, :bar)
  iex> receive do
  iex>   {^ref, result} -> result
  iex> end
  {:ok, :foo}

  Be mindful of long delays before results are returned (expecially if the queue length is significant). To handle this,
  you may want to add and `after` clause to the `receive`, or listen for the responses from within a `handle_info` clause
  in a GenServer.

  ## Known limitations

  Partitions don't monitor callers, so queued requests will stay in their queue event if the caller
  dies in the meantime. The caller's liveliness is only checked before spawning the request task
  (the task is only spawned if the caller is alive). Therefore, it's possible a partition will
  refuse new requests due to reaching the max queue size, even though some of those requests
  won't end up being made (because they belong to now dead callers).
  """
  @spec async_request(key :: partition_key(), request :: PoliteClient.Client.request()) ::
          AllocatedRequest.t()
          | {:error, :max_queued | :suspended}
  def async_request(key, request) do
    with_partition(key, &Partition.async_request(&1, request))
  end

  @doc """
  Tells whether the `allocated_request` is still allocated.

  Allocations may be lost in the event of partition crashes.
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

  @doc """
  Returns the pid used by a partition.

  Do not use a partition's pid to interact with it: prefer using its `t:partition_key/0` value instead
  as it is stable across restarts.

  You should only seek to obtain a partition's pid if you with to work directly with the process itself
  (monitor, link to it, etc.).
  """
  @spec whereis(partition_key()) :: pid() | {:error, :no_partition}
  def whereis(key) do
    case PartitionsMgr.find_name(key) do
      {:ok, via_tuple} -> GenServer.whereis(via_tuple)
      :not_found -> {:error, :no_partition}
    end
  end

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

  A partition provides back pressure to all requests transiting through it. Partitions should be keyed
  so the requests only get throttled when necessary: typically partitions would be keyed by host,
  as making requests to host A usually won't affect host B (assuing they're not sharing infrastructure).
  Requests transiting through the same partition are NOT executed concurrently, by design.

  Should you want to (e.g.) be able to make requests to 2 different hosts using the same politeness
  rules (health checker, rate limit, etc.), start 2 separate partitions using the same options (but
  different partition keys, of course).

  Note that mapping requests to partitions is the caller's responsibility
  TODO example in quickstart + (refer to quick start).

  The `key` identifies the parttion, and must be unique. If a partition is already active with the
  given `key`, `{:error, {:key_conflict, pid}}` will be returned, where `pid` is the pid of the
  existing partition identified by `key`.

  Partitions are independent from one another, in particular their health checker and rate limiter
  states are not shared. Therefore, a partition can have a more restrictive rate limiter, or a more
  forgiving health checker implementation.

  These options MUST be provided:

  * `client` - the `t:PoliteClient.Client.t()` implementation to use when executing requests

  These options MAY be provided:

  * `rate_limiter` - a  valid `t:PoliteClient.RateLimiter.config/0`. Defaults to a constant delay of
      1 second between requests.
  * `health_checker` - a  valid `t:PoliteClient.HealthChecker.config/0`. Defaults to always considering the
      host as healthy.
      * `max_retries` - number of times a failed request should be retried after the initial attempt. In this
      context, a failed request is one where a response from the server isn't received (e.g. network error):
      receiving an error response from the server (e.g. HTTP 5xx Server errors) is considered a successful request.
  * `max_queued` - the number of requests to keep in a queue. Once the queue is full, calls to `async_request/2`
      will return `{:error, :max_queued}`. Defaults to 250.
  """
  @spec start_partition(key :: partition_key(), opts :: Keyword.t()) ::
          :ok
          | {:error, {:key_conflict, pid()}}
          | {:error, :max_partitions}
  defdelegate start_partition(key, opts \\ []), to: PartitionsMgr, as: :start

  @spec stop_partition(key :: partition_key(), opts :: Keyword.t()) ::
          :ok | {:error, reason}
        when reason: :no_partition | :busy
  defdelegate stop_partition(key, opts \\ []), to: PartitionsMgr, as: :stop

  @doc "Suspends all partitions."
  defdelegate suspend_all(opts), to: PartitionsMgr
end
