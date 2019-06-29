defmodule PoliteClient.AppSup do
  use Supervisor

  @task_supervisor PoliteClient.RequestTaskSupervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init(args) do
    children = [
      {Task.Supervisor, name: @task_supervisor},
      {PoliteClient.PartitionsMgr,
       registry: Keyword.fetch!(args, :registry), task_supervisor: @task_supervisor},
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: PoliteClient.PartitionsSupervisor,
       max_children: Keyword.get(args, :max_partitions, :infinity)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
