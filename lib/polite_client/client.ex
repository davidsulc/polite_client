defmodule PoliteClient.Client do
  @moduledoc false

  use GenServer

  alias PoliteClient.Request

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, args)
  end

  def perform_request(pid, %Request{} = request) do
    GenServer.call(pid, {:request, request})
  end

  @impl GenServer
  def init(_args) do
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:request, request}, _from, state) do
    {:reply, get_http_client().(request), state}
  end

  defp get_http_client() do
    fn %Request{method: method, uri: uri, headers: headers, body: body, opts: opts} ->
      Mojito.request(method, URI.to_string(uri), headers, body, opts)
    end
  end
end
