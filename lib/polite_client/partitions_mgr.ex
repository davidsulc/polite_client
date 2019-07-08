defmodule PoliteClient.PartitionsMgr do
  @moduledoc false

  use GenServer

  require Logger

  alias PoliteClient.{Partition, PartitionsSupervisor}

  @name __MODULE__

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: @name)
  end

  @spec start(key :: PoliteClient.partition_key(), opts :: Keyword.t()) ::
          :ok
          | {:error, {:key_conflict, pid()}}
          | {:error, :max_partitions}
  def start(key, opts \\ []) do
    GenServer.call(@name, {:start_partition, {key, opts}})
  end

  @doc "Find the partition corresponding to `key`."
  @spec find_name(key :: PoliteClient.partition_key()) ::
          {:ok, {:via, module(), term()}} | :not_found
  def find_name(key) do
    GenServer.call(@name, {:find_partition, key})
  end

  @doc "Returns true if the partition still has the request allocated."
  @spec allocated?(PoliteClient.partition_key(), reference()) :: boolean()
  def allocated?(key, ref) do
    GenServer.call(@name, {:allocated?, key, ref})
  end

  @doc "Cancel the request."
  @spec cancel(PoliteClient.partition_key(), reference()) :: :ok
  def cancel(key, ref) do
    GenServer.call(@name, {:cancel, key, ref})
  end

  @doc "Suspend all partitions."
  @spec suspend_all(opts :: Keyword.t()) :: :ok
  def suspend_all(opts \\ []) do
    GenServer.call(@name, {:suspend_all, opts})
  end

  @impl GenServer
  def init(args) do
    {:ok,
     %{
       partition_supervisor: Keyword.fetch!(args, :partition_supervisor),
       registry: Keyword.fetch!(args, :registry),
       task_supervisor: Keyword.fetch!(args, :task_supervisor)
     }}
  end

  @impl GenServer
  def handle_call({:start_partition, {key, opts}}, _from, state) do
    state
    |> find_partition(key)
    |> case do
      nil ->
        case start_partition(state, key, opts) do
          :ok -> {:reply, :ok, state}
          {:error, _} = error -> {:reply, error, state}
        end

      partition_pid ->
        {:reply, {:error, {:already_started, partition_pid}}, state}
    end
  end

  @impl GenServer
  def handle_call({:find_partition, key}, _from, state) do
    via_tuple = via_tuple(state, key)

    case GenServer.whereis(via_tuple) do
      nil -> {:reply, :not_found, state}
      pid when is_pid(pid) -> {:reply, {:ok, via_tuple}, state}
    end
  end

  @impl GenServer
  def handle_call({:allocated?, key, ref}, _from, state) do
    case find_partition(state, key) do
      nil -> {:reply, false, state}
      location -> {:reply, Partition.allocated?(location, ref), state}
    end
  end

  @impl GenServer
  def handle_call({:cancel, key, ref}, _from, state) do
    cancelation_result =
      state
      |> find_partition(key)
      |> Partition.cancel(ref)

    {:reply, cancelation_result, state}
  end

  @impl GenServer
  def handle_call({:suspend_all, opts}, _from, state) do
    state.partition_supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} -> Partition.suspend(pid, opts) end)

    {:reply, :ok, state}
  end

  defp find_partition(state, key) do
    state
    |> via_tuple(key)
    |> GenServer.whereis()
  end

  defp start_partition(state, key, opts) do
    via_tuple = via_tuple(state, key)

    partition_opts =
      opts
      |> Keyword.put(:name, via_tuple)
      |> Keyword.put(:key, key)
      |> Keyword.put(:task_supervisor, state.task_supervisor)

    child_spec =
      Supervisor.child_spec(Partition,
        id: "partition_#{inspect(key)}",
        start: {Partition, :start_link, [partition_opts]}
      )

    with {:started, nil} <- {:started, find_partition(state, key)},
         {:ok, _pid} <- DynamicSupervisor.start_child(PartitionsSupervisor, child_spec) do
      :ok
    else
      {:started, pid} -> {:error, {:key_conflict, pid}}
      {:error, :max_children} -> {:error, :max_partitions}
      {:error, _} = error -> error
    end
  end

  def via_tuple(%{registry: registry}, key) do
    {:via, Registry, {registry, key}}
  end
end
