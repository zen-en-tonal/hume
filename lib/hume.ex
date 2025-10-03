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

      {:ok, pid} = Hume.start_link(MyStateMachine, [])
      Hume.send_event(pid, {:add, :foo, 42})
      {:ok, {..., %{foo: 42}}}
      Hume.send_event(pid, {:remove, :foo})
      {:ok, {..., %{}}}

  ## Telemetry

  Hume uses Elixir's Telemetry to emit notifications for important events such as state transitions and ETS table ownership transfers.

  ### Hume.Heir

    * `[:hume_heir, :transfer, :received]` - ETS table ownership received
      - Metadata: `%{name: name, tid: tid}`
    * `[:hume_heir, :transfer, :not_found]` - Ownership transfer requested but table not found
      - Metadata: `%{name: name}`
    * `[:hume_heir, :transfer, :sent]` - ETS table ownership transferred
      - Metadata: `%{name: name, tid: tid}`

  ### Hume.Machine

    * `[:hume_machine, :init]` - State machine initialized
      - Metadata: `%{machine_id}`
    * `[:hume_machine, :replay, :done]` - Snapshot and event replay completed successfully
      - Measurements: `%{total_ms, last_snapshot_ms, events_ms, replay_ms, event_count}`
      - Metadata: `%{machine_id, seq}`
    * `[:hume_machine, :replay, :error]` - Error during replay
      - Measurements: `%{total_ms, last_snapshot_ms, events_ms, replay_ms, event_count}`
      - Metadata: `%{machine_id, reason}`
    * `[:hume_machine, :event, :accept]` - Event accepted and persisted successfully
      - Measurements: `%{total_ms, handle_ms, persist_ms}`
      - Metadata: `%{machine_id, seq}`
    * `[:hume_machine, :event, :reject]` - Event processing failed
      - Measurements: `%{total_ms}`
      - Metadata: `%{machine_id, seq, reason}`
    * `[:hume_machine, :snapshot, :skip]` - Snapshot skipped (below threshold)
      - Measurements: `%{count, threshold}`
      - Metadata: `%{machine_id}`
    * `[:hume_machine, :snapshot, :done]` - Snapshot taken successfully
      - Measurements: `%{take_snap_ms}`
      - Metadata: `%{machine_id}`
    * `[:hume_machine, :snapshot, :error]` - Snapshot failed
      - Measurements: `%{take_snap_ms}`
      - Metadata: `%{machine_id, reason}`
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
    - timeout: The maximum time to wait for a response (default is 5000 ms).

  ## Returns
    - `{:ok, snapshot}` if the event is applied successfully.
    - `{:error, reason}` if an error occurs during event handling or persistence.
  """
  @spec send_event(machine(), Hume.Machine.event(), timeout()) ::
          {:ok, Hume.Machine.snapshot()} | {:error, term()}
  def send_event(machine, event, timeout \\ 5_000) do
    GenServer.call(machine, {:event, event}, timeout)
  end

  @doc """
  Retrieves the current snapshot of the state machine.

  ## Parameters
    - machine: The PID or name of the state machine process.
    - timeout: The maximum time to wait for a response (default is 5000 ms).
  ## Returns
    - `snapshot`: The current snapshot of the state machine.
  """
  @spec snapshot(machine(), timeout()) :: Hume.Machine.snapshot()
  def snapshot(machine, timeout \\ 5_000) do
    GenServer.call(machine, :snapshot, timeout)
  end

  @doc """
  Retrieves the current state of the state machine.

  ## Parameters
    - machine: The PID or name of the state machine process.
    - timeout: The maximum time to wait for a response (default is 5000 ms).
  ## Returns
    - `state`: The current state of the state machine.
  """
  @spec state(machine(), timeout()) :: Hume.Machine.state()
  def state(machine, timeout \\ 5_000) do
    GenServer.call(machine, :snapshot, timeout)
    |> elem(1)
  end

  @doc """
  Evolves the state by applying a single event.

  ## Parameters
    - mod: The module implementing the `Hume.Machine` behaviour.
    - event: The event to be applied.
    - snapshot: A tuple containing the current offset and state.

  ## Returns
    - `{:ok, snapshot}` if the event is applied successfully.
    - `{:error, reason}` if an error occurs during event handling or persistence.
  """
  @spec evolve(mod :: module(), Hume.Machine.event(), Hume.Machine.snapshot()) ::
          {:ok, Hume.Machine.snapshot()} | {:error, term()}
  def evolve(mod, event, snapshot) do
    do_evolve(mod, event, snapshot)
  end

  defp do_evolve(_, {next, _}, {seq, _}) when next <= seq do
    {:error, :stale_event}
  end

  defp do_evolve(mod, {next, event}, {_seq, state}) do
    apply(mod, :handle_event, [event, state])
    |> case do
      {:ok, new_state} ->
        {:ok, {next, new_state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Replays a list of events starting from a given snapshot.

  ## Parameters
    - mod: The module implementing the `Hume.Machine` behaviour.
    - snapshot: A tuple containing the offset and the state to start replaying from.
    - events: A ordered list of events to be replayed.

  ## Returns
    - `{:ok, snapshot}` if all events are replayed successfully.
    - `{:error, reason}` if an error occurs during event handling.
  """
  @spec replay(mod :: module(), Hume.Machine.snapshot(), events :: Hume.EventOrder.ordered()) ::
          {:ok, Hume.Machine.snapshot()} | {:error, term()}
  def replay(mod, snapshot, {:ordered, events}) do
    events
    |> Enum.reduce_while(snapshot, fn event, ss ->
      case evolve(mod, event, ss) do
        {:ok, new_ss} -> {:cont, new_ss}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      ok -> {:ok, ok}
    end
  end
end
