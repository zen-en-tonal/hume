defmodule Hume.Publisher do
  @moduledoc false

  alias Hume.EventStore

  @spec publish(
          event_store :: module(),
          EventStore.stream(),
          EventStore.payload(),
          keyword()
        ) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def publish(_event_store, _stream, _payload, _opts \\ [])

  def publish(_event_store, _stream, nil, _opts) do
    {:ok, nil}
  end

  def publish(event_store, stream, payload, opts) do
    case EventStore.append(event_store, stream, payload, opts[:expect_seq]) do
      {:ok, seq} -> {:ok, seq}
      {:error, reason} -> {:error, reason}
    end
  end
end
