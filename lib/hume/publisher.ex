defmodule Hume.Publisher do
  @moduledoc false

  alias Hume.EventStore
  alias Hume.Queue

  @spec publish(
          event_store :: module(),
          EventStore.stream(),
          [EventStore.payload()] | EventStore.payload()
        ) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def publish(_event_store, _stream, []) do
    {:ok, []}
  end

  def publish(event_store, stream, payloads) do
    :ok = Queue.push({event_store, stream}, payloads)
    Queue.flush({event_store, stream})
  end
end
