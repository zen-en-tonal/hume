# Hume

Hume is a library for building event-sourced state machines in Elixir.

It provides a framework for defining state machines that handle events, maintain state, and take snapshots for efficient recovery. The library leverages Elixir's `GenServer` for process management and supports ETS for event storage, including ownership transfer via a dedicated "heir" process.

## Features

- **Define state machines** using a simple behavior (`Hume.Projection`)
- **Handle and persist events** to an event store (in-memory or ETS-based)
- **Take snapshots** of the current state for efficient recovery
- **Transfer ETS table ownership** using a dedicated heir process
- **Utilities for ordered event sequences** via `Hume.EventOrder`

## Usage

To get started with Hume, define a state machine by creating a module that uses `Hume.Projection` and implements the required callbacks:

```elixir
defmodule MyProjection do
  use Hume.Projection, use_ets: true, store: Hume.EventStore.ETS

  @impl true
  def init_state(_), do: %{}

  @impl true
  def handle_event({:add, key, value}, state),
    do: {:ok, Map.put(state || %{}, key, value)}

  @impl true
  def handle_event({:remove, key}, state),
    do: {:ok, Map.delete(state || %{}, key)}
end

{:ok, pid} = Hume.start_link(MyProjection, stream: MyStream)

{:ok, _} = Hume.publish(Hume.EventStore.ETS, MyStream, {:add, :foo, 42})
%{foo: 42} = Hume.state(pid)
{:ok, _} = Hume.publish(Hume.EventStore.ETS, MyStream, {:remove, :foo})
%{} = Hume.state(pid)
```

## Installation

Add `hume` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:hume, "~> 0.0.1"}
  ]
end
```

## Documentation

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

```bash
mix docs
```

Once published, the docs can be found at [https://hexdocs.pm/hume](https://hexdocs.pm/hume).

