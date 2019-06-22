defmodule PoliteClient.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @registry Registry.PoliteClient

  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {PoliteClient.AppSup, registry: @registry}
    ]

    opts = [strategy: :rest_for_one, name: PoliteClient.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
