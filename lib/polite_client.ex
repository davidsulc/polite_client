defmodule PoliteClient do
  @moduledoc """
  Documentation for PoliteClient.
  """

  alias PoliteClient.{AllocatedRequest, Partition, PartitionsMgr}

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
  def async_request(method \\ :get, url, headers \\ [], body \\ "", opts \\ []) do
    uri = URI.parse(url)

    request = %{
      method: method,
      uri: uri,
      headers: headers,
      body: body,
      opts: opts
    }

    with_partition(uri.host, &Partition.async_request(&1, request))
  end

  def allocated?(%AllocatedRequest{partition: key, ref: ref}) do
    PartitionsMgr.allocated?(key, ref)
  end

  def cancel(%AllocatedRequest{partition: key, ref: ref}) do
    PartitionsMgr.cancel(key, ref)
  end

  def resume(key), do: with_partition(key, &Partition.resume/1)

  def suspend(key, opts \\ [])
  def suspend(:all, opts), do: PartitionsMgr.suspend_all(opts)
  def suspend(key, opts), do: with_partition(key, &Partition.suspend(&1, opts))

  defp with_partition(key, fun) do
    case PartitionsMgr.find_name(key) do
      {:ok, via_tuple} ->
        fun.(via_tuple)

      # TODO start partition dynamically
      :not_found ->
        {:error, :no_partition}
    end
  end

  defdelegate start_partition(key, opts \\ []), to: PartitionsMgr, as: :start
end
