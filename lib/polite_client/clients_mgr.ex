defmodule PoliteClient.ClientsMgr do
  use GenServer

  require Logger

  alias PoliteClient.{Client, ClientsSupervisor}

  @name __MODULE__
  @registry Registry.PoliteClient

  def start_link([]) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @spec start(key :: term(), opts :: Keyword.t()) ::
          :ok
          | {:error, {:key_conflict, pid()}}
          | {:error, :max_children}
  def start(key, opts \\ []) do
    GenServer.call(@name, {:start_client, {key, opts}})
  end

  @impl GenServer
  def init(:ok) do
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:start_client, {key, opts}}, _from, state) do
    opts = sanitize_opts(opts)

    case Registry.lookup(@registry, key) do
      [] ->
        child_spec = Supervisor.child_spec({Client, opts}, id: "client_#{inspect(key)}")

        with {:ok, pid} <- DynamicSupervisor.start_child(ClientsSupervisor, child_spec),
             {:ok, _} <- Registry.register(@registry, key, pid) do
          {:reply, :ok, state}
        else
          {:error, :max_children} = error -> {:reply, error, state}
          {:error, {:already_registered, pid}} -> {:reply, {:error, {:key_conflict, pid}}, state}
        end

      [{_, client_pid}] ->
        {:reply, {:error, {:already_started, client_pid}}, state}
    end
  end

  @spec sanitize_opts(opts :: Keyword.t()) :: Keyword.t()
  defp sanitize_opts(opts) do
    if Keyword.get(opts, :name) do
      Logger.warn(
        "Do not provide a `:name` option when starting clients: use the `key` value to address the client"
      )
    end

    Keyword.drop(opts, [:name])
  end
end
