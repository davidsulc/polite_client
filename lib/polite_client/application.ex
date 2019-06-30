defmodule PoliteClient.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @partition_supervisor_name PoliteClient.PartitionsSupervisor
  @registry_name Registry.PoliteClient
  @task_supervisor_name PoliteClient.RequestTaskSupervisor

  def start(_type, args) do
    partition_supervisor_name =
      Keyword.get(args, :partition_supervisor_name, @partition_supervisor_name)

    registry_name = Keyword.get(args, :registry_name, @registry_name)
    task_supervisor_name = Keyword.get(args, :task_supervisor_name, @task_supervisor_name)

    children = [
      {Registry, keys: :unique, name: registry_name},
      # TODO document: call pass in `:max_partitions` value to limit concurrency
      # (wraps DynamicSupervisor's :max_children value)
      {PoliteClient.AppSup,
       partition_supervisor_name: partition_supervisor_name,
       registry: registry_name,
       task_supervisor: task_supervisor_name}
    ]

    opts = [strategy: :rest_for_one, name: PoliteClient.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
