defmodule Hume.QueueSupervisor do
  use Supervisor

  alias Hume.Queue
  alias Hume.QueueRegistry
  alias Hume.QueueDynamicSupervisor

  def start_link(_) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def start_queue(event_store, stream) do
    case DynamicSupervisor.start_child(
           QueueDynamicSupervisor,
           {Queue, {event_store, stream}}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @impl true
  def init(_) do
    children = [
      {Registry, keys: :unique, name: QueueRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: QueueDynamicSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
