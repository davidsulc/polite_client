defmodule PoliteClient.Client do
  @moduledoc false

  use GenServer

  require Logger

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
    state = %{
      http_client: Keyword.fetch!(args, :http_client),
      requests_in_flight: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:request, request}, from, %{http_client: c} = state) do
    %Task{ref: ref} = Task.async(fn -> c.(request) end)
    in_flight = Map.put(state.requests_in_flight, ref, from)

    {:noreply, %{state | requests_in_flight: in_flight}}
  end

  @impl GenServer
  def handle_info({ref, result}, state) when is_reference(ref) do
    requester = Map.get(state.requests_in_flight, ref)
    GenServer.reply(requester, result)
    {:noreply, %{state | requests_in_flight: Map.delete(state.requests_in_flight, ref)}}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.error("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # TODO allow specifying http_client as a module/behaviour
end
