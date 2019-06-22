defmodule PoliteClient do
  @moduledoc """
  Documentation for PoliteClient.
  """

  alias PoliteClient.{Client, ClientsMgr, Request}

  def request(method \\ :get, url, headers \\ [], body \\ "", opts \\ []) do
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
        Client.perform_request(pid, request)

      # TODO start client dynamically
      :not_found ->
        {:error, :no_client}
    end
  end

  defdelegate start_client(key, opts \\ []), to: ClientsMgr, as: :start
end
