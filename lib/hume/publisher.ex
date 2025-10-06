defmodule Hume.Publisher do
  @moduledoc false

  alias Hume.{EventStore, EventOrder}

  @spec publish(event_store :: module(), EventStore.stream(), [EventStore.payload()]) ::
          {:ok, [EventStore.event()]} | {:error, term()}
  def publish(_event_store, _stream, []) do
    {:ok, []}
  end

  def publish(event_store, stream, payloads) when is_list(payloads) do
    events = EventStore.number(event_store, payloads)
    last_event = events |> EventOrder.to_list() |> List.last()

    with :ok <- EventStore.append(event_store, stream, events),
         :ok <- Hume.Bus.notify(event_store, stream, last_event |> elem(0)) do
      {:ok, events}
    end
  end

  @spec publish(event_store :: module(), EventStore.stream(), EventStore.payload()) ::
          {:ok, EventStore.event()} | {:error, term()}
  def publish(event_store, stream, payload) do
    event = EventStore.number(event_store, payload)

    with :ok <- EventStore.append(event_store, stream, event),
         :ok <- Hume.Bus.notify(event_store, stream, event |> elem(0)) do
      {:ok, event}
    end
  end
end
