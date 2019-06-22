defmodule PoliteClient.AppSup do
  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init(args) do
    children = [
      {PoliteClient.ClientsMgr, registry: Keyword.fetch!(args, :registry)},
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: PoliteClient.ClientsSupervisor,
       max_children: Keyword.get(args, :max_clients, :infinity)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
