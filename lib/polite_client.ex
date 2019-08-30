defmodule PoliteClient do
  @moduledoc """
  PoliteClient implements client-side back-pressure by applying the
  [circuit breaker](https://en.wikipedia.org/wiki/Circuit_breaker_design_pattern) and
  [rate limiter](https://en.wikipedia.org/wiki/Rate_limiting) patterns to requests (grouped
  by partition).

  When repeatedly sending requests to a remote host, it is important to do so in so-called
  polite fashion. This is all the more imporant when these reuquests are performed for
  a sustained period of time, such as when scraping a website.

  How can we make our requests polite? By not straining the remote host and degrading its service.
  This typically means spacing out requests so you're not slamming the host with back-to-back
  requests that would prevent it from serving other clients in a timely manner. In addition,
  if the host is in a degraded state (responding much too slowly, returning unexpected errors,
  etc.), no further requests should be made for some time interval, in order to give the remote
  host the opportunity to recover.

  # Quickstart

  Let's say we're going to scrape www.example.com and www.exmaple.net concurrently. We assume these
  are on different hosts, and therefore making requests to one won't impact the other: we'll use
  one partition for each host.

  We'll use `Mojito` as our HTTP client library, but any other library would also work (such as
  HTTPotion, Hackney, Tesla, etc.). However, the `:client` function must conform to the
  `t:PoliteClient.Client.t/0` spec and return `{:ok, ...}` and `{:error, ...}` tuples. (`Mojito.get/2`
  already does this, so no further wrapping is needed.)

  ```
  :ok = PoliteClient.start("www.example.com", client: &Mojito.get/1)
  :ok = PoliteClient.start("www.example.net", client: &Mojito.get/1)

  allocated_request_a = PoliteClient.async_request("www.example.com", "https://www.example.com/index.html")
  allocated_request_b = PoliteClient.async_request("www.example.com", "https://www.example.com/about.html")
  allocated_request_c = PoliteClient.async_request("www.example.net", "https://www.example.net/index.html")
  allocated_request_d = PoliteClient.async_request("www.example.net", "https://www.example.net/contact.html")
  ```

  ## Mapping requests to partitions

  Since PoliteClient doesn't know of any relationship between the request types you're using and the partition
  keys, there's too much room for error: you could give the wrong partition key for a given request. Therefore,
  you should instead map requests to partition keys. And since the data type that you use for requests is
  completely free, here's an example where we use `URI` instances and map based on host:

  ```
  :ok = PoliteClient.start("www.example.com", client: fn %URI{} = uri ->
    uri
    |> URI.to_string()
    |> Mojito.get()
  end)

  mapper = fn %URI{hostname: host} -> host end

  async_request_wrapper = fn %URI{} = uri ->
    PoliteClient.async_request(mapper.(request), request)
  end

  request = URI.parse("https://www.example.com/index.html")
  allocated_request = async_request_wrapper.(request)

  ```

  ## Controlling back pressure

  Let's now start a partition that will ensure the delay before a request is twice the time 
  it took to make the previous one (but at least half a second), and that will suspend itself
  for 5 minutes if 3 consecutive requests fail, or will suspend itself permanently (until manually
  resumed) if a single request took more than 10 seconds:

  ```
  {:ok, rate_limiter_config} = PoliteClient.RateLimiter.config({:relative, 2, min_delay: 500})

  {:ok, health_checker_config} =
    PoliteClient.HealthChecker.config(
      fn consecutive_errors, %PoliteClient.ResponseMeta{result: result, duration: duration} ->
        consecutive_errors =
          case result do
            {:ok, _} -> 0 # the streak of errors was broken, reset the count
            {:error, _} -> consecutive_errors + 1 # increment the error streak
          end

        status =
          cond do
            # the `ResponseMeta` duration is in microseconds!
            duration > 10_000_000 -> {:suspend, :infinity}
            consecutive_errors > 2 -> {:suspend, 5 * 60 * 1_000}
            true -> :ok
          end

        {status, consecutive_errors}
      end,
      0
    )

  :ok = PoliteClient.start(:foo,
    client: &Mojito.get/1,
    rate_limiter: rate_limiter_config,
    health_checker: health_checker_config)
  ```

  Refer to the documentation for `PoliteClient.RateLimiter.config/1` for common configurations.

  And naturally, the health check and rate limit functionality can be delegated to third-party libraries
  (such as `ExRated` and `fuse`).

  # Configuration

  The number of partitions that can be created can be limited:

  ```
  config :polite_client, :max_partitions, 5
  ```

  With the above configuration, calling `PoliteClient.start/2` to start a 6th partition will return
  `{:error, :max_partitions}`.
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
  * `{:error, {:retries_exhausted, last_error}}` where `last_error` is the value returned by the partition's
    request client (`t:PoliteClient.Client.t/0`) during the last retry attempt
    (i.e. it will be an instance of the `t:PoliteClient.Client.result/0` error case)
  * `{:error, {:task_failed, reason}}` if the task executing the request (via the client) fails
  * `:canceled` if the request was canceled either directly through `PoliteClient.cancel/1`, or by halting
  the partition (through `PoliteClient.suspend/2`, `PoliteClient.suspend_all/1`, or directly stopping the partition
  GenServer)

  Options:

  * `:client` - the `t:PoliteClient.Client.t/0` to use for the request. If none is provided, the partition's
    client will be used.

  ## Example

  In the examples below, the `:client` value would typically be a function making a request via an
  HTTP client (such as Hackney, Tesla, HTTPotion, Mojito, etc.).

  ```
  PoliteClient.start(:my_partition, client: fn request -> {:ok, request} end)
  %PoliteClient.AllocatedRequest{ref: ref} = PoliteClient.async_request(:my_partition, :bar)
  receive do
    {^ref, result} -> result
  end
  {:ok, :foo}
  ```

  Be mindful of long delays before results are returned (expecially if the queue length is significant). To handle this,
  you may want to add and `after` clause to the `receive`, or listen for the responses from within a `handle_info` clause
  in a GenServer.
  """
  @spec async_request(key :: partition_key(), request :: PoliteClient.Client.request()) ::
          AllocatedRequest.t()
          | {:error, :max_queued | :suspended}
  def async_request(key, request, opts \\ []) do
    with_partition(key, &Partition.async_request(&1, request, opts))
  end

  @doc """
  Tells whether the `allocated_request` is still allocated.

  Allocations may be lost in the event of partition crashes.

  ## Example

  ```
  # with a partition with key `:my_partition` running
  allocated_request = PoliteClient.async_request(:my_partition, "some request")
  PoliteClient.allocated?(allocated_request)
  # => true
  PoliteClient.cancel(allocated_request)
  PoliteClient.allocated?(allocated_request)
  # => false
  ```
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
  will simply return `:ok` with no messages sent.

  ## Example

  ```
  # with a partition with key `:my_partition` running
  allocated_request = PoliteClient.async_request(:my_partition, "some request")
  PoliteClient.cancel(allocated_request)
  # => :ok
  flush()
  # => {#Reference<0.256178682.2266497026.226577>, :canceled}
  ```
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

  If the `purge: true` option is given, all pending requests will be canceled (with notifications
  sent, see `cancel/1`).
  """
  @spec suspend(key :: partition_key(), opts :: Keyword.t()) :: :ok | {:error, reason}
        when reason: :no_partition | :suspended
  def suspend(key, opts \\ []), do: with_partition(key, &Partition.suspend(&1, opts))

  @doc "Returns the partition's current status."
  @spec status(key :: partition_key()) :: :active | :suspended
  def status(key), do: with_partition(key, &Partition.status/1)

  @doc """
  Returns the pid used by a partition.

  Do not use a partition's pid to interact with it: prefer using its `t:partition_key/0` value instead
  as it is stable across restarts.

  You should only seek to obtain a partition's pid if you with to work directly with the process itself
  (monitor, link to it, etc.).

  ## Examples

  ```
  # with a partition with key `:my_partition` running
  PoliteClient.whereis(:my_partition)
  #=> #PID<0.84.0>

  PoliteClient.whereis(:foo)
  {:error, :no_partition}
  ```
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

  Note that mapping requests to partitions is the caller's responsibility (see top of module documentation).

  Partitions are independent from one another, in particular their health checker and rate limiter
  states are not shared. Therefore, a partition can have a more restrictive rate limiter, or a more
  forgiving health checker implementation.

  These options MUST be provided:

  * `client` - the `t:PoliteClient.Client.t()` implementation to use when executing requests

  These options MAY be provided:

  * `rate_limiter` - a  valid `t:PoliteClient.RateLimiter.config/0`. Defaults to a constant delay of
      1 second between requests. To force immediate requests, call `PoliteClient.RateLimiter.config/1`
      with `{:constant, 0}`.
  * `health_checker` - a  valid `t:PoliteClient.HealthChecker.config/0`. Defaults to always considering the
      host as healthy.
  * `max_retries` - number of times a failed request should be retried after the initial attempt. In this
      context, a failed request is one where a response from the server isn't received (e.g. network error):
      receiving an error response from the server (e.g. HTTP 5xx Server errors) is considered a successful request.
  * `max_queued` - the number of requests to keep in a queue. Once the queue is full, calls to `async_request/2`
      will return `{:error, :max_queued}`. Defaults to 250.

  The `key` identifies the parttion, and must be unique. If a partition is already active with the
  given `key`, `{:error, {:already_started, pid}}` will be returned, where `pid` is the pid of the
  existing partition identified by `key`.

  If the applications was started with a `:max_partitions` value and there are already that many
  partitions, `{:error, :max_partitions}` will be returned.
  """
  @spec start(key :: partition_key(), opts :: Keyword.t()) ::
          :ok
          | {:error, {:already_started, pid()}}
          | {:error, :max_partitions}
  defdelegate start(key, opts \\ []), to: PartitionsMgr, as: :start

  @spec stop(key :: partition_key(), opts :: Keyword.t()) ::
          :ok | {:error, reason}
        when reason: :no_partition | :busy
  defdelegate stop(key, opts \\ []), to: PartitionsMgr, as: :stop

  @doc """
  Suspends all partitions.

  Behaves like `suspend/2` without requiring a partition key, as the suspend call will be made to all
  partitions with the provided options.
  """
  defdelegate suspend_all(opts \\ []), to: PartitionsMgr
end
