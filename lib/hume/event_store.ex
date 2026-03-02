defmodule Hume.EventStore do
  @moduledoc """
  Behaviour module for event stores.

  An event store is responsible for storing and retrieving events in a stream.
  Each event has a sequence number that is strictly increasing within a stream.
  Events must be appended in order.
  """

  @type stream :: term()
  @type seq :: non_neg_integer()
  @type payload :: term()
  @type event :: {seq(), payload()}

  @doc """


  The events must be strictly ordered by sequence number.
  """
  @callback append(stream(), payload(), expect :: seq() | nil) :: {:ok, seq()} | {:error, term()}

  @doc """
  Get all events from the stream starting from the given sequence number (exclusive).

  The events are returned in strictly ascending order by sequence number.
  """
  @callback events(stream(), from :: seq()) :: Enumerable.t(event())

  @doc """
  Appends an event to the specified stream in the given event store.

  ## Parameters
    - event_store: The module implementing the event store (must use `Hume.EventStore`).
    - stream: The stream identifier where the event will be appended.
    - payload: The event payload to be appended.
    - expect_seq: Optional expected sequence number for optimistic concurrency control. 
      If provided, the append will only succeed if the current last sequence number in the stream matches this value.
  """
  @spec append(module(), stream(), payload(), expect_seq :: seq() | nil) ::
          {:ok, seq()} | {:error, term()}
  def append(event_store, stream, payload, expect_seq \\ nil) do
    event_store.append(stream, payload, expect_seq)
  end

  @doc """
  Validates that the given module implements the required functions of the `Hume.EventStore`
  behaviour.
  """
  @spec validate(module()) :: :ok | {:error, :invalid_module}
  def validate(nil) do
    {:error, :invalid_module}
  end

  def validate({:__aliases__, _, mods}) do
    Module.concat(mods)
    |> validate()
  end

  def validate(mod) do
    Code.ensure_loaded(mod)

    functions = [
      {:append, 3},
      {:events, 2}
    ]

    functions
    |> Enum.reduce_while(:ok, fn {fun, arity}, acc ->
      if function_exported?(mod, fun, arity) do
        {:cont, acc}
      else
        {:halt, {:error, :invalid_module}}
      end
    end)
  end
end
