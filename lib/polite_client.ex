defmodule PoliteClient do
  @moduledoc """
  Documentation for PoliteClient.
  """

  alias PoliteClient.{Client, ClientsMgr, Request}

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

    request = %Request{
      method: method,
      uri: uri,
      headers: headers,
      body: body,
      opts: opts
    }

    case ClientsMgr.find_name(uri.host) do
      {:ok, via_tuple} ->
        Client.async_request(via_tuple, request)

      # TODO start client dynamically
      :not_found ->
        {:error, :no_client}
    end
  end

  def resume(key) do
    case ClientsMgr.find_name(key) do
      {:ok, via_tuple} ->
        Client.resume(via_tuple)

      # TODO start client dynamically
      :not_found ->
        {:error, :no_client}
    end
  end

  def suspend(key) do
    case ClientsMgr.find_name(key) do
      {:ok, via_tuple} ->
        Client.suspend(via_tuple)

      # TODO start client dynamically
      :not_found ->
        {:error, :no_client}
    end
  end

  # TODO suspend all => need registry of all clients

  defdelegate start_client(key, opts \\ []), to: ClientsMgr, as: :start
end
