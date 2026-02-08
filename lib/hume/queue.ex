defmodule Hume.Queue do
  @moduledoc false

  use GenServer

  alias Hume.TaskSupervisor
  alias Hume.QueueSupervisor
  alias Hume.EventStore
  alias Hume.Bus

  defstruct [
    :event_store,
    :stream,
    queue: :queue.new(),
    now_flushing: :queue.new(),
    flushing_task: nil,
    waiters: []
  ]

  def start_link({event_store, stream}) do
    name = {:via, Registry, {Hume.QueueRegistry, {event_store, stream}}}
    GenServer.start_link(__MODULE__, {event_store, stream}, name: name)
  end

  @spec push({module :: module(), stream :: String.t()}, items :: list()) ::
          :ok
  def push({event_store, stream}, items) do
    {:ok, pid} = QueueSupervisor.start_queue(event_store, stream)
    GenServer.cast(pid, {:push, items})
  end

  @spec flush({module :: module(), stream :: String.t()}) ::
          {:ok, last_sequence :: non_neg_integer() | nil} | {:error, reason :: any()}
  def flush({event_store, stream}) do
    {:ok, pid} = QueueSupervisor.start_queue(event_store, stream)
    GenServer.call(pid, :flush)
  end

  @impl true
  def init({event_store, stream}) do
    {:ok,
     %__MODULE__{
       event_store: event_store,
       stream: stream
     }}
  end

  @impl true
  def handle_call(:flush, from, %__MODULE__{} = state) do
    if state.flushing_task do
      {:noreply, %{state | waiters: [from | state.waiters]}}
    else
      {:noreply, %{do_flush(state) | waiters: [from]}}
    end
  end

  @impl true
  def handle_cast({:push, items}, %__MODULE__{} = state) do
    new_queue =
      List.wrap(items)
      |> Enum.reduce(state.queue, fn item, acc ->
        :queue.in(item, acc)
      end)

    {:noreply, %{state | queue: new_queue}}
  end

  @impl true
  # Handle the result of the flushing task
  def handle_info(
        {ref, {:append_result, res}},
        %__MODULE__{flushing_task: %{ref: task_ref}} = state
      )
      when ref == task_ref do
    case res do
      {:ok, last_sequence} ->
        Enum.each(state.waiters, fn from ->
          GenServer.reply(from, {:ok, last_sequence})
        end)

        {:noreply, %{state | flushing_task: nil, now_flushing: :queue.new(), waiters: []}}

      {:error, reason} ->
        Enum.each(state.waiters, fn from ->
          GenServer.reply(from, {:error, reason})
        end)

        # Re-enqueue the items that were being flushed
        queue = :queue.join(state.now_flushing, state.queue)

        {:noreply,
         %{state | queue: queue, flushing_task: nil, now_flushing: :queue.new(), waiters: []}}
    end
  end

  # Handle if the flushing task crashes
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %__MODULE__{flushing_task: %{ref: task_ref}} = state
      )
      when ref == task_ref do
    # Re-enqueue the items that were being flushed
    queue = :queue.join(state.now_flushing, state.queue)

    {:noreply, %{state | queue: queue, flushing_task: nil, now_flushing: :queue.new()}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp do_flush(%__MODULE__{} = state) do
    case :queue.to_list(state.queue) do
      [] ->
        state

      items ->
        task =
          Task.Supervisor.async_nolink(TaskSupervisor, fn ->
            result =
              with {:ok, last_sequence} <-
                     EventStore.append(state.event_store, state.stream, items),
                   :ok <- Bus.notify(state.event_store, state.stream, last_sequence) do
                {:ok, last_sequence}
              end

            {:append_result, result}
          end)

        %{state | flushing_task: task, queue: :queue.new(), now_flushing: state.queue}
    end
  end
end
