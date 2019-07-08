defmodule PoliteClient.AppSup do
  @moduledoc false

  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init(args) do
    task_supervisor = Keyword.fetch!(args, :task_supervisor)
    partition_supervisor = Keyword.fetch!(args, :partition_supervisor_name)

    children = [
      {Task.Supervisor, name: task_supervisor},
      {PoliteClient.PartitionsMgr,
       registry: Keyword.fetch!(args, :registry),
       task_supervisor: task_supervisor,
       partition_supervisor: partition_supervisor},
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: partition_supervisor,
       max_children: Keyword.get(args, :max_partitions, :infinity)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
