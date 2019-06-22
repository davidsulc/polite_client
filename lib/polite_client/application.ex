defmodule PoliteClient.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Registry.PoliteClient},
      PoliteClient.AppSup
    ]

    opts = [strategy: :rest_for_one, name: PoliteClient.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
