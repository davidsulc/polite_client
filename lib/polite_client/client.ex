defmodule PoliteClient.Client do
  @moduledoc false

  use GenServer

  alias PoliteClient.Request

  @type http_client() :: (Request.t() -> {:ok, term()} | {:error, term()})

  def start_link(args) do
    # TODO verify args contains :http_client
    GenServer.start_link(__MODULE__, args, args)
  end

  def perform_request(pid, %Request{} = request) do
    GenServer.call(pid, {:request, request})
  end

  @impl GenServer
  def init(args) do
    {:ok, %{http_client: Keyword.fetch!(args, :http_client)}}
  end

  @impl GenServer
  def handle_call({:request, request}, _from, %{http_client: c} = state) do
    {:reply, c.(request), state}
  end

  # TODO allow specifying http_client as a module/behaviour
end
