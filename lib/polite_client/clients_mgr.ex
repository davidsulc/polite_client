defmodule PoliteClient.ClientsMgr do
  use GenServer

  @name __MODULE__

  def start_link([]) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  def init(:ok) do
    {:ok, %{}}
  end
end
