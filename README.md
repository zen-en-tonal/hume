# Hume

Hume is a library for building event-sourced state machines in Elixir.

It provides a framework for defining state machines that handle events, maintain state, and take snapshots for efficient recovery. The library leverages Elixir's `GenServer` for process management and supports ETS for event storage, including ownership transfer via a dedicated "heir" process.

## Features

- **Define state machines** using a simple behavior (`Hume.Machine`)
- **Handle and persist events** to an event store (in-memory or ETS-based)
- **Take snapshots** of the current state for efficient recovery
- **Transfer ETS table ownership** using a dedicated heir process
- **Utilities for ordered event sequences** via `Hume.EventOrder`

## Usage

To get started with Hume, define a state machine by creating a module that uses `Hume.Machine` and implements the required callbacks:

```elixir
defmodule MyStateMachine do
  use Hume.Machine, :use_ets

  def init_state(_) do
    %{}
  end

  def handle_event({:add, key, value}, state) do
    {:ok, Map.put(state, key, value)}
  end

  def handle_event({:remove, key}, state) do
    {:ok, Map.delete(state, key)}
  end
end

{:ok, pid} = Hume.start_link(MyStateMachine, [])
Hume.send_event(pid, {:add, :foo, 42})
{:ok, {..., %{foo: 42}}}
Hume.send_event(pid, {:remove, :foo})
{:ok, {..., %{}}}
```

## Installation

Add `hume` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:hume, "~> 0.1.0"}
  ]
end
```

## Documentation

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

```bash
mix docs
```

Once published, the docs can be found at [https://hexdocs.pm/hume](https://hexdocs.pm/hume).

