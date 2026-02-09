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
  Append a batch of events to the stream.

  The events must be strictly ordered by sequence number.
  """
  @callback append_batch(stream(), Enumerable.t(payload())) :: {:ok, seq()} | {:error, term()}

  @doc """
  Get all events from the stream starting from the given sequence number (exclusive).

  The events are returned in strictly ascending order by sequence number.
  """
  @callback events(stream(), from :: seq()) :: Enumerable.t(event())

  @doc """
  Appends a single event or a batch of ordered events to the given stream.

  Ensures the events are appended in order.
  """
  @spec append(module(), stream(), payload() | Enumerable.t(payload())) ::
          {:ok, seq()} | {:error, term()}
  def append(mod, stream, payload) do
    mod.append_batch(stream, List.wrap(payload))
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
