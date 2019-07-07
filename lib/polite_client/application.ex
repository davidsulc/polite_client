defmodule PoliteClient.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @partition_supervisor_name PoliteClient.PartitionsSupervisor
  @registry_name Registry.PoliteClient
  @task_supervisor_name PoliteClient.RequestTaskSupervisor

  def start(_type, args) do
    children = [
      {Registry, keys: :unique, name: @registry_name},
      {
        PoliteClient.AppSup,
        # TODO document: call pass in `:max_partitions` value to limit concurrency
        # (wraps DynamicSupervisor's :max_children value)
        partition_supervisor_name: @partition_supervisor_name,
        registry: @registry_name,
        task_supervisor: @task_supervisor_name,
        max_children: Keyword.get(args, :max_children, :infinity)
      }
    ]

    opts = [strategy: :rest_for_one, name: PoliteClient.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
