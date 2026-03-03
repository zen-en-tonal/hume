defmodule Hume.Publisher do
  @moduledoc false

  alias Hume.EventStore
  alias Hume.Bus

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
    with {:ok, seq} <- EventStore.append(event_store, stream, payload, opts[:expect_seq]),
         :ok <- Bus.notify(event_store, stream, seq) do
      {:ok, seq}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
