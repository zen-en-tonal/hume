defmodule Hume.Projection do
  @moduledoc """
  Behaviour and macros for defining event-sourced state machines.

  This module provides a behaviour that can be implemented by modules to define
  event-sourced state machines. It also includes macros to automatically generate
  boilerplate code for managing state, handling events, taking snapshots, and
  persisting events.

  ## Usage
  To use this module, define a new module and use `Hume.Projection` with the
  desired options. Implement the required callbacks to define the initial state,
  event handling logic, and snapshot management.

  ## Options
  When using `Hume.Projection`, you can provide the following options:
    - `:store` (required): The module implementing the event store behaviour.
    - `:use_ets`: Use ETS for snapshot storage (default is false).
    - `:snapshot_every`: Number of events after which to take a snapshot (default is 100).
    - `:snapshot_after`: Time in milliseconds after which to take a snapshot (default is 30 seconds).
    - `:catch_up_after`: Time in milliseconds after which to check for new events (default is 30 seconds).
    - `:strict_online`: Whether to enforce strict event handling during online catch-up (default is true).

  ## Callbacks
  The following callbacks must be implemented by the module using `Hume.Projection`:
    - `init_state/1`: Initializes the state of the machine.
    - `handle_event/2`: Handles an event and updates the state.
    - `last_snapshot/1`: Retrieves the last snapshot of the machine.
    - `persist_snapshot/2`: Persists a snapshot of the current state.

  ## Example
      defmodule MyProjection do
        use Hume.Projection, use_ets: true, store: MyEventStore

        @impl true
        def init_state(_), do: %{}

        @impl true
        def handle_event({:add, key, value}, state),
          do: {:ok, Map.put(state || %{}, key, value)}

        @impl true
        def handle_event({:remove, key}, state),
          do: {:ok, Map.delete(state || %{}, key)}
      end
  """

  alias Hume.{Bus, EventOrder}

  require Logger

  @type stream :: term()

  @type projection :: atom()

  @type state :: term()

  @type event :: {seq(), term()}

  @type seq :: integer()

  @type offset :: seq()

  @type snapshot :: {offset(), state() | nil}

  @type option() ::
          GenServer.option()
          | {:stream, stream() | [stream()]}
          | {:projection, projection()}

  @type macro_option() ::
          {:use_ets, boolean()}
          | {:store, module()}
          | {:snapshot_every, non_neg_integer()}
          | {:snapshot_after, non_neg_integer()}
          | {:catch_up_after, non_neg_integer()}
          | {:strict_online, boolean()}

  @doc """
  Initial state of the machine.

  ## Parameters
    - projection: The name or identifier of the machine.

  ## Returns
    - The initial state of the machine.
  """
  @callback init_state(projection()) :: state()

  @doc """
  Callback invoked when the projection process is initialized.
  This is optional and can be used to perform any setup required.

  ## Parameters
    - projection: The name or identifier of the machine.

  ## Returns
    - `:ok`
  """
  @callback on_init(projection()) :: :ok

  @doc """
  Handles an event and updates the state accordingly.

  ## Parameters
    - event: The event to be handled.
    - state: The current state of the machine.

  ## Returns
    - `{:ok, new_state}` if the event was handled successfully, where `new_state` is the updated state.
    - `{:error, reason}` if an error occurred while handling the event.
  """
  @callback handle_event(event :: term(), state()) :: {:ok, state()} | {:error, term()}

  @doc """
  Retrieves the last snapshot of the machine.

  ## Returns
    - `snapshot` if a snapshot exists, where `snapshot` is a tuple containing the offset and state.
    - `nil` if no snapshot exists.
  """
  @callback last_snapshot(projection()) :: snapshot() | nil

  @doc """
  Persists a snapshot of the current state.

  ## Parameters
    - snapshot: A tuple containing the offset and the current state.

  ## Returns
    - `:ok` if the snapshot was taken successfully.
    - `{:error, reason}` if an error occurred while taking the snapshot.
  """
  @callback persist_snapshot(projection(), snapshot()) :: :ok | {:error, term()}

  @doc """
  Callback invoked when the projection has caught up with the event store.

  This can be used to perform any actions needed after catching up, such as
  notifying other parts of the system or updating internal state.
  ## Parameters
    - snapshot: The current snapshot of the projection after catching up.
  ## Returns
    - `:ok`
  """
  @callback on_caught_up(snapshot()) :: :ok

  @optional_callbacks on_init: 1, on_caught_up: 1

  @spec __using__(opts :: [macro_option()]) :: Macro.t()
  defmacro __using__(opts) do
    quote do
      unquote(validate_opts(opts))
      unquote(impl_genserver(opts))
      unquote(impl_default(opts))
    end
  end

  defp validate_opts(opts) do
    allowed_opts = [
      :use_ets,
      :store,
      :snapshot_every,
      :snapshot_after,
      :catch_up_after,
      :strict_online
    ]

    invalid_opts = Keyword.keys(opts) -- allowed_opts

    if invalid_opts != [] do
      raise ArgumentError, "Invalid options for Hume.Projection: #{inspect(invalid_opts)}"
    end

    :ok
  end

  defp impl_genserver(macro_opts) do
    store_mod = Keyword.fetch!(macro_opts, :store)
    snap_every = Keyword.get(macro_opts, :snapshot_every, 100)
    snap_after = Keyword.get(macro_opts, :snapshot_after, :timer.seconds(30))
    catch_up_after = Keyword.get(macro_opts, :catch_up_after, :timer.seconds(30))
    strict_online = Keyword.get(macro_opts, :strict_online, true)

    quote bind_quoted: [
            store_mod: store_mod,
            snap_every: snap_every,
            snap_after: snap_after,
            catch_up_after: catch_up_after,
            strict_online: strict_online
          ],
          location: :keep do
      use GenServer

      require Logger

      @behaviour Hume.Projection

      @store store_mod
      @snapshot_every snap_every
      @snapshot_after snap_after
      @catch_up_after catch_up_after
      @strict_online strict_online

      def child_spec(opts) do
        %{
          id: {__MODULE__, Keyword.fetch!(opts, :projection)},
          start: {Hume.Projection, :start_link, [__MODULE__, opts]},
          restart: :permanent,
          shutdown: 5000,
          type: :worker
        }
      end

      @impl true
      def init(%{streams: streams} = opts) do
        for stream <- streams, do: Bus.subscribe(@store, stream)

        state =
          opts
          |> Map.put(:count, 0)
          |> Map.put(:snapshot, nil)

        on_init(opts.projection)

        :telemetry.execute(
          [
            :hume,
            :projection,
            :init
          ],
          %{},
          %{module: __MODULE__, opts: opts}
        )

        {:ok, state, {:continue, :catch_up}}
      end

      @impl true
      def on_init(_projection), do: :ok

      @impl true
      def handle_continue(:catch_up, %{streams: streams, projection: proj} = s) do
        {last_snapshot_ms, ss} =
          :timer.tc(
            fn -> last_snapshot(proj) || {0, init_state(proj)} end,
            :millisecond
          )

        :telemetry.execute(
          [
            :hume,
            :projection,
            :catch_up,
            :start
          ],
          %{},
          %{module: __MODULE__, streams: streams}
        )

        result =
          case catch_up(streams, ss, strict: false) do
            {:ok, new_ss, count} ->
              Process.send_after(self(), :tick_snapshot, @snapshot_after)
              Process.send_after(self(), :tick_catch_up, @catch_up_after)
              GenServer.cast(self(), :on_caught_up)
              {:noreply, %{s | snapshot: new_ss, count: s.count + count}}

            {:error, reason} ->
              {:stop, reason, %{s | snapshot: nil}}
          end

        :telemetry.execute(
          [
            :hume,
            :projection,
            :catch_up,
            :stop
          ],
          %{},
          %{module: __MODULE__, streams: streams}
        )

        result
      end

      @impl true
      def handle_info({:hint, stream, _last_seq}, %{snapshot: ss} = s) do
        case catch_up(stream |> List.wrap(), ss, strict: @strict_online) do
          {:ok, {seq, state}, count} ->
            GenServer.cast(self(), :on_caught_up)
            {:noreply, %{s | snapshot: {seq, state}, count: s.count + count}}

          {:error, reason} ->
            {:stop, reason, %{s | snapshot: nil}}
        end
      end

      def handle_info(:tick_snapshot, %{count: count} = s)
          when count < @snapshot_every do
        Process.send_after(self(), :tick_snapshot, @snapshot_after)
        {:noreply, s}
      end

      def handle_info(:tick_snapshot, %{projection: proj, snapshot: snapshot} = s) do
        {take_snap_ms, snap_result} =
          :timer.tc(fn -> persist_snapshot(proj, snapshot) end, :millisecond)

        :telemetry.execute(
          [
            :hume,
            :projection,
            :snapshot
          ],
          %{duration: take_snap_ms},
          %{module: __MODULE__, projection: proj, snapshot: snapshot, result: snap_result}
        )

        case snap_result do
          :ok ->
            Process.send_after(self(), :tick_snapshot, @snapshot_after)
            {:noreply, %{s | count: 0}}

          {:error, reason} ->
            Logger.error("Failed to take snapshot: #{inspect(reason)}")
            Process.send_after(self(), :tick_snapshot, @snapshot_after)
            {:noreply, %{s | count: 0}}
        end
      end

      def handle_info(:tick_catch_up, %{streams: streams, snapshot: ss} = s) do
        case catch_up(streams, ss, strict: @strict_online) do
          {:ok, new_ss, count} ->
            Process.send_after(self(), :tick_catch_up, @catch_up_after)
            GenServer.cast(self(), :on_caught_up)
            {:noreply, %{s | snapshot: new_ss, count: s.count + count}}

          {:error, reason} ->
            {:stop, reason, %{s | snapshot: nil}}
        end
      end

      @impl true
      def handle_call(:snapshot, _from, %{snapshot: snapshot} = s) do
        {:reply, snapshot, s}
      end

      def handle_call(:take_snapshot, _from, %{projection: proj, snapshot: snapshot} = s) do
        snap_result = persist_snapshot(proj, snapshot)

        :telemetry.execute(
          [
            :hume,
            :projection,
            :snapshot,
            :manual
          ],
          %{},
          %{module: __MODULE__, projection: proj, snapshot: snapshot, result: snap_result}
        )

        case snap_result do
          :ok ->
            {:reply, :ok, %{s | count: 0}}

          {:error, reason} ->
            {:reply, {:error, reason}, s}
        end
      end

      def handle_call(:catch_up, _from, %{streams: streams, snapshot: ss} = s) do
        :telemetry.execute(
          [
            :hume,
            :projection,
            :catch_up,
            :manual,
            :start
          ],
          %{},
          %{module: __MODULE__, streams: streams}
        )

        result =
          case catch_up(streams, ss, strict: @strict_online) do
            {:ok, new_ss, count} ->
              GenServer.cast(self(), :on_caught_up)
              {:reply, :ok, %{s | snapshot: new_ss, count: s.count + count}}

            {:error, reason} ->
              {:stop, reason, %{s | snapshot: nil}}
          end

        :telemetry.execute(
          [
            :hume,
            :projection,
            :catch_up,
            :manual,
            :stop
          ],
          %{},
          %{module: __MODULE__, streams: streams}
        )

        result
      end

      @impl true
      def handle_cast(:on_caught_up, %{projection: proj, snapshot: snapshot} = s) do
        :telemetry.execute(
          [:hume, :projection, :on_caught_up],
          %{},
          %{module: __MODULE__, projection: proj, snapshot: snapshot}
        )

        on_caught_up(snapshot)

        {:noreply, s}
      end

      @impl true
      def on_caught_up(_snapshot), do: :ok

      def store, do: @store

      defp events(streams, from) do
        streams
        |> Enum.reduce(EventOrder.ensure_ordered([]), fn stream, acc ->
          EventOrder.merge_ordered(acc, @store.events(stream, from))
        end)
      end

      defp catch_up(streams, {since, state} = last_snapshot, opts) do
        strict = Keyword.get(opts, :strict, true)

        {events_ms, events} =
          :timer.tc(
            fn -> events(streams, since) end,
            :millisecond
          )

        :timer.tc(
          fn -> Hume.Projection.replay(__MODULE__, last_snapshot, events, strict: strict) end,
          :millisecond
        )
        |> case do
          {replay_ms, {:ok, {seq, state}}} ->
            {:ok, {seq, state}, events |> EventOrder.len()}

          {replay_ms, {:error, reason}} ->
            {:error, reason}
        end
      end

      @before_compile {Hume.Projection, :add_handle_event_fallback}

      defoverridable on_caught_up: 1, on_init: 1
    end
  end

  defp impl_default(opts) when is_list(opts) do
    if Keyword.get(opts, :use_ets, false) do
      impl_ets_default()
    end
  end

  defp impl_ets_default() do
    quote location: :keep do
      @hume_snapshot_table Hume.Projection.ETSOwner.table()

      @impl true
      def last_snapshot(proj) do
        case :ets.lookup(@hume_snapshot_table, {proj, :snapshot}) do
          [{{^proj, :snapshot}, snapshot}] -> snapshot
          _ -> nil
        end
      end

      @impl true
      def persist_snapshot(proj, snapshot) do
        true = :ets.insert(@hume_snapshot_table, {{proj, :snapshot}, snapshot})
        :ok
      end
    end
  end

  @doc false
  defmacro add_handle_event_fallback(_env) do
    quote do
      @impl true
      def handle_event(_, _), do: {:error, :unknown_event}
    end
  end

  @doc """
  Evolves the state by applying a single event.

  ## Parameters
    - mod: The module implementing the `Hume.Projection` behaviour.
    - event: The event to be applied.
    - snapshot: A tuple containing the current offset and state.

  ## Returns
    - `{:ok, snapshot}` if the event is applied successfully.
    - `{:error, reason}` if an error occurs during event handling or persistence.
  """
  @spec evolve(mod :: module(), event(), snapshot()) ::
          {:ok, snapshot()} | {:error, term()}
  def evolve(mod, event, snapshot, opts \\ []) do
    start = System.monotonic_time()
    result = do_evolve(mod, event, snapshot, opts)
    stop = System.monotonic_time()

    :telemetry.execute(
      [
        :hume,
        :projection,
        :evolve
      ],
      %{duration: stop - start},
      %{module: mod, event: event, snapshot: snapshot, result: result}
    )

    result
  end

  defp do_evolve(_, {next, _}, {seq, _}, _) when next <= seq do
    {:error, :stale_event}
  end

  defp do_evolve(mod, {next, event}, {_seq, state}, opts) do
    strict = Keyword.get(opts, :strict, true)

    apply(mod, :handle_event, [event, state])
    |> case do
      {:ok, new_state} ->
        {:ok, {next, new_state}}

      {:error, :unknown_event} when not strict ->
        Logger.warning("Ignoring unknown event: #{inspect({next, event})}")
        {:ok, {next, state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Replays a list of events starting from a given snapshot.

  ## Parameters
    - mod: The module implementing the `Hume.Projection` behaviour.
    - snapshot: A tuple containing the offset and the state to start replaying from.
    - events: A ordered list of events to be replayed.

  ## Returns
    - `{:ok, snapshot}` if all events are replayed successfully.
    - `{:error, reason}` if an error occurs during event handling.
  """
  @spec replay(mod :: module(), snapshot(), events :: EventOrder.ordered()) ::
          {:ok, snapshot()} | {:error, term()}
  def replay(mod, snapshot, {:ordered, events}, opts \\ []) do
    strict = Keyword.get(opts, :strict, true)
    start = System.monotonic_time()

    result =
      events
      |> Enum.reduce_while(snapshot, fn event, ss ->
        case evolve(mod, event, ss, strict: strict) do
          {:ok, new_ss} -> {:cont, new_ss}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:error, reason} -> {:error, reason}
        ok -> {:ok, ok}
      end

    stop = System.monotonic_time()

    :telemetry.execute(
      [
        :hume,
        :projection,
        :replay
      ],
      %{duration: stop - start},
      %{module: mod, events_count: length(events), result: result}
    )

    result
  end

  @doc """
  Requests the state machine to take a snapshot of its current state.

  ## Parameters
    - server: The PID or name of the state machine process.
    - timeout: The maximum time to wait for a response (default is 5000 ms).

  ## Returns
    - `:ok` if the snapshot was taken successfully.
    - `{:error, reason}` if there was an error taking the snapshot.
  """
  @spec take_snapshot(GenServer.server(), timeout :: non_neg_integer()) ::
          :ok | {:error, term()}
  def take_snapshot(server, timeout \\ 5_000) do
    GenServer.call(server, :take_snapshot, timeout)
  end

  @doc """
  Requests the state machine to catch up by processing any new events.

  ## Parameters
    - server: The PID or name of the state machine process.
    - timeout: The maximum time to wait for a response (default is 5000 ms).

  ## Returns
    - `:ok` if the catch-up was successful.
    - `{:error, reason}` if there was an error during catch-up.
  """
  @spec catch_up(GenServer.server(), timeout :: non_neg_integer()) ::
          :ok | {:error, term()}
  def catch_up(server, timeout \\ 5_000) do
    GenServer.call(server, :catch_up, timeout)
  end

  @doc """
  Retrieves the current snapshot of the state machine.

  ## Parameters
    - machine: The PID or name of the state machine process.
    - timeout: The maximum time to wait for a response (default is 5000 ms).
  ## Returns
    - `snapshot`: The current snapshot of the state machine.
  """
  @spec snapshot(GenServer.server(), timeout()) :: Hume.Projection.snapshot()
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
  @spec state(GenServer.server(), timeout()) :: Hume.Projection.state()
  def state(machine, timeout \\ 5_000) do
    GenServer.call(machine, :snapshot, timeout)
    |> elem(1)
  end

  @doc false
  @spec parse_options(keyword()) ::
          {:ok, {opts :: map(), rest :: keyword()}}
          | {:error, term()}
  def parse_options(opts) do
    with {:ok, {map, rest}} <- do_parse_options(opts, %{}, []),
         {:ok, map} <- put_optional(map),
         {:ok, map} <- validate_options(map) do
      {:ok, {map, rest}}
    end
  end

  defp do_parse_options([{:stream, stream} | tail], map, rest) do
    do_parse_options(tail, Map.put(map, :streams, List.wrap(stream)), rest)
  end

  defp do_parse_options([{:projection, proj} | tail], map, rest) do
    do_parse_options(tail, Map.put(map, :projection, proj), rest)
  end

  defp do_parse_options([h | t], map, rest) do
    do_parse_options(t, map, [h | rest])
  end

  defp do_parse_options([], map, rest) do
    {:ok, {map, rest}}
  end

  defp put_optional(map) do
    opts =
      map
      |> Map.put_new(:projection, __MODULE__)

    {:ok, opts}
  end

  defp validate_options(map) do
    cond do
      map[:streams] == nil ->
        {:error, :missing_stream}

      map[:projection] == nil ->
        {:error, :missing_projection}

      true ->
        {:ok, map}
    end
  end

  @doc """
  Retrieves the event store module used by the projection.

  ## Parameters
    - mod: The module implementing the `Hume.Projection` behaviour.

  ## Returns
    - `store`: The event store module.
  """
  @spec store(module()) :: module()
  def store(mod) do
    mod.store()
  end

  @doc """
  Validates that the given module implements the `Hume.Projection` behaviour.

  ## Parameters
    - mod: The module to be validated.

  ## Returns
    - `:ok` if the module implements the `Hume.Projection` behaviour.
    - `{:error, reason}` if the module does not implement the behaviour.
  """
  @spec validate(module()) :: :ok | {:error, :invalid_module}
  def validate(mod) do
    functions = [
      {:init_state, 1},
      {:handle_event, 2},
      {:last_snapshot, 1},
      {:persist_snapshot, 2}
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

  @spec start_link(module(), [option()]) :: {:ok, pid()} | {:error, term()}
  def start_link(mod, opts) do
    with :ok <- validate(mod),
         {:ok, {opts, rest}} <- parse_options(opts) do
      GenServer.start_link(mod, opts, rest)
    end
  end

  @spec start(module(), [option()]) :: {:ok, pid()} | {:error, term()}
  def start(mod, opts) do
    with :ok <- validate(mod),
         {:ok, {opts, rest}} <- parse_options(opts) do
      GenServer.start(mod, opts, rest)
    end
  end
end
