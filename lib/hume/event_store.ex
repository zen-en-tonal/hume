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
  Get the next sequence number.

  This should return the next available sequence number.
  0 if the stream is empty, otherwise the last sequence number + 1.
  """
  @callback next_sequence :: seq()

  @doc """
  Append a batch of events to the stream.

  The events must be strictly ordered by sequence number.
  """
  @callback append_batch(stream(), Enumerable.t(event())) :: :ok | {:error, term()}

  @doc """
  Get all events from the stream starting from the given sequence number (exclusive).

  The events are returned in strictly ascending order by sequence number.
  """
  @callback events(stream(), from :: seq()) :: Enumerable.t(event())

  @doc """
  Appends a single event or a batch of ordered events to the given stream.

  - If given a single event `{seq, payload}`, it appends it as a batch of one event.
  - If given an ordered list of events `{:ordered, [events]}`, it appends them as a batch.

  Ensures the events are appended in order.
  """
  @spec append(module(), stream(), event() | Enumerable.t(event())) ::
          :ok | {:error, term()}
  def append(mod, stream, {seq, _payload} = event) when is_integer(seq) do
    mod.append_batch(stream, [event])
  end

  def append(mod, stream, events) do
    mod.append_batch(stream, events)
  end

  @doc """
  Assigns sequence numbers to a single payload or a list of payloads for the given stream.

  - If given a single payload, it returns a single event tuple `{seq, payload}`
  - If given a list of payloads, it returns an ordered list of events `{:ordered, [events]}`

  Ensures the events are assigned in order.
  """
  @spec number(module(), Enumerable.t(event())) :: Enumerable.t(event())
  def number(mod, payloads) when is_list(payloads) do
    payloads
    |> Stream.map(fn payload -> number(mod, payload) end)
  end

  @spec number(module(), payload()) :: event()
  def number(mod, payload) do
    {mod.next_sequence(), payload}
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
      {:next_sequence, 0},
      {:append_batch, 2},
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
