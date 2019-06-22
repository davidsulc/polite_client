defmodule PoliteClient.Client do
  use GenServer

  def start_link([]) do
    GenServer.start_link(__MODULE__, :ok)
  end

  @impl GenServer
  def init(:ok) do
    {:ok, %{}}
  end
end
