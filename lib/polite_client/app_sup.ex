defmodule PoliteClient.AppSup do
  use Supervisor

  def start_link([]) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl Supervisor
  def init(:ok) do
    children = [
      PoliteClient.ClientsMgr,
      {DynamicSupervisor, strategy: :one_for_one, name: PoliteClient.ClientsSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
