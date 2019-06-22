defmodule PoliteClient.ClientsMgr do
  use GenServer

  require Logger

  alias PoliteClient.{Client, ClientsSupervisor}

  @name __MODULE__

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: @name)
  end

  @spec start(key :: term(), opts :: Keyword.t()) ::
          :ok
          | {:error, {:key_conflict, pid()}}
          | {:error, :max_children}
  def start(key, opts \\ []) do
    GenServer.call(@name, {:start_client, {key, opts}})
  end

  @spec get(key :: term()) :: {:ok, pid()} | :not_found
  def get(key) do
    GenServer.call(@name, {:find_client, key})
  end

  @impl GenServer
  def init(args) do
    {:ok, %{registry: Keyword.fetch!(args, :registry)}}
  end

  @impl GenServer
  def handle_call({:start_client, {key, opts}}, _from, state) do
    state
    |> via_tuple(key)
    |> GenServer.whereis()
    |> case do
      nil ->
        case start_client(state, key, opts) do
          :ok -> {:reply, :ok, state}
          {:error, _} = error -> error
        end

      client_pid ->
        {:reply, {:error, {:already_started, client_pid}}, state}
    end
  end

  @impl GenServer
  def handle_call({:find_client, key}, _from, state) do
    state
    |> via_tuple(key)
    |> GenServer.whereis()
    |> case do
      nil -> {:reply, :not_found, state}
      pid -> {:reply, {:ok, pid}, state}
    end
  end

  defp start_client(state, key, opts) do
    opts = sanitize_opts(opts)
    via_tuple = via_tuple(state, key)

    child_spec =
      Supervisor.child_spec({Client, opts},
        id: "client_#{inspect(key)}",
        start: {Client, :start_link, [[name: via_tuple]]}
      )

    with {:started, nil} <- {:started, state |> via_tuple(key) |> GenServer.whereis()},
         {:ok, _pid} <- DynamicSupervisor.start_child(ClientsSupervisor, child_spec) do
      :ok
    else
      {:started, pid} -> {:error, {:key_conflict, pid}}
      {:error, :max_children} = error -> error
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

  def via_tuple(%{registry: registry}, key) do
    {:via, Registry, {registry, key}}
  end
end
