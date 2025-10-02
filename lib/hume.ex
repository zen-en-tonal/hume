defmodule Hume do
  @moduledoc """
  Hume is a library for building event-sourced state machines in Elixir.

  It provides a framework for defining state machines that can handle events,
  maintain state, and take snapshots of their state for efficient recovery.

  The library leverages Elixir's `GenServer` for process management and can use
  ETS for event storage. It also includes a mechanism for transferring ETS table
  ownership using a "heir" process.

  ## Features

    - Define state machines using a simple behaviour.
    - Handle events and update state accordingly.
    - Persist events to an event store (in-memory or ETS).
    - Take snapshots of the current state for efficient recovery.
    - Transfer ETS table ownership using a dedicated heir process.

  ## Getting Started
  To get started with Hume, you can define a state machine by creating a module
  that uses `Hume.Machine` and implements the required callbacks. You can then
  start the state machine process and send events to it.

  ## Example

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

      iex> {:ok, pid} = Hume.start_link(MyStateMachine, [])
      iex> Hume.send_event(pid, {:add, :foo, 42})
      {:ok, {..., %{foo: 42}}}
      iex> Hume.send_event(pid, {:remove, :foo})
      {:ok, {..., %{}}}

  """

  @type machine :: GenServer.server()
  @type option :: GenServer.option() | {:use_heir, boolean()}

  @doc """
  Starts a state machine process.

  ## Parameters
    - mod: The module implementing the state machine (must use `Hume.Machine`).
    - opts: See `GenServer.start_link/3` options. Additionally, you can pass `{:use_heir, boolean()}` to specify whether to use the hair process for ETS table ownership transfer.

  ## Returns
    - `{:ok, pid}` if the process starts successfully.
    - `{:error, reason}` if the process fails to start.
  """
  @spec start_link(module(), [option()]) :: GenServer.on_start()
  def start_link(mod, opts \\ []) do
    GenServer.start_link(mod, opts, opts)
  end

  @doc """
  Starts a state machine process without linking it to the current process.

  ## Parameters
    - mod: The module implementing the state machine (must use `Hume.Machine`).
    - opts: See `GenServer.start/3` options. Additionally, you can pass `{:use_heir, boolean()}` to specify whether to use the hair process for ETS table ownership transfer.

  ## Returns
    - `{:ok, pid}` if the process starts successfully.
    - `{:error, reason}` if the process fails to start.
  """
  @spec start(module(), [option()]) :: GenServer.on_start()
  def start(mod, opts \\ []) do
    GenServer.start(mod, opts, opts)
  end

  @doc """
  Sends an event to the state machine process.

  ## Parameters
    - machine: The PID or name of the state machine process.
    - event: The event to be applied.

  ## Returns
    - `{:ok, snapshot}` if the event is applied successfully.
    - `{:error, reason}` if an error occurs during event handling or persistence.
  """
  @spec send_event(machine(), Hume.Machine.event()) ::
          {:ok, Hume.Machine.snapshot()} | {:error, term()}
  def send_event(machine, event) do
    GenServer.call(machine, {:event, event})
  end
end
