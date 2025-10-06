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
  that uses `Hume.Projection` and implements the required callbacks. You can then
  start the state machine process and send events to it.

  ## Example

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

  ## Telemetry


  """

  @doc """
  Starts a state machine process.

  ## Options
    - `:stream` - The stream identifier (required).
    - `:projection` - The unique name for the projection (required). GenServer name will be set to this value.
    - `:registry` - The registry module for process registration (default :local). Can be `:local`, `:global`, or `{module, name}` for custom registries.

  ## Returns
    - `{:ok, pid}` if the process starts successfully.
    - `{:error, reason}` if the process fails to start.
  """
  @spec start_link(module(), [Hume.Projection.option()]) :: GenServer.on_start()
  def start_link(mod, opts \\ []) do
    Hume.Projection.start_link(mod, opts)
  end

  @doc """
  Starts a state machine process without linking it to the current process.

  See `Hume.start_link/2` for options and return values.
  """
  @spec start(module(), [Hume.Projection.option()]) :: GenServer.on_start()
  def start(mod, opts \\ []) do
    Hume.Projection.start(mod, opts)
  end

  @doc """
  Publishes an event to the specified event store and stream.

  ## Parameters
    - event_store: The module implementing the event store (must use `Hume.EventStore`).
    - stream: The stream identifier where the event will be published.
    - payload: The event payload to be published.

  ## Returns
    - `{:ok, event}` if the event is published successfully.
    - `{:error, reason}` if there is an error during publishing.
  """
  @spec publish(
          event_store :: module(),
          Hume.EventStore.stream(),
          [Hume.EventStore.payload()]
        ) :: {:ok, [Hume.EventStore.event()]} | {:error, term()}
  def publish(event_store, stream, payloads) when is_list(payloads) do
    Hume.Publisher.publish(event_store, stream, payloads)
  end

  @spec publish(
          event_store :: module(),
          Hume.EventStore.stream(),
          Hume.EventStore.payload()
        ) :: {:ok, Hume.EventStore.event()} | {:error, term()}
  def publish(event_store, stream, payload) do
    Hume.Publisher.publish(event_store, stream, payload)
  end

  @doc """
  See `Hume.Projection.state/2`.
  """
  @spec state(GenServer.server(), timeout()) :: Hume.Projection.state()
  def state(server, timeout \\ 5_000) do
    Hume.Projection.state(server, timeout)
  end
end
