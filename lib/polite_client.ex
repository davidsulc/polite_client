defmodule PoliteClient do
  @moduledoc """
  Documentation for PoliteClient.
  """

  alias PoliteClient.{Client, ClientsMgr, Request}

  def async_request(method \\ :get, url, headers \\ [], body \\ "", opts \\ []) do
    uri = URI.parse(url)

    request = %Request{
      method: method,
      uri: uri,
      headers: headers,
      body: body,
      opts: opts
    }

    case ClientsMgr.get(uri.host) do
      {:ok, pid} ->
        Client.async_request(pid, request)

      # TODO start client dynamically
      :not_found ->
        {:error, :no_client}
    end
  end

  def sync_request(method \\ :get, url, headers \\ [], body \\ "", opts \\ []) do
    case async_request(method, url, headers, body, opts) do
      {:error, _} = error ->
        error

      ref when is_reference(ref) ->
        receive do
          {^ref, result} -> result
        end
    end
  end

  defdelegate start_client(key, opts \\ []), to: ClientsMgr, as: :start
end
