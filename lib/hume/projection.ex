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

  ## Telemetry
  This module emits telemetry events for various operations, including:
    - `[:hume, :projection, :init]`
    - `[:hume, :projection, :catch_up, :start]`
    - `[:hume, :projection, :catch_up, :stop]`
    - `[:hume, :projection, :snapshot]`
    - `[:hume, :projection, :evolve]`
    - `[:hume, :projection, :replay]`
    - `[:hume, :projection, :on_caught_up]`

  ## Shutdown
  On `:normal` termination, the projection will automatically persist its current snapshot.
  """

  alias Hume.Bus
  alias Hume.TaskSupervisor

  require Logger

  @type stream :: term()

  @type projection :: term()

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
      def init(%{stream: stream} = opts) do
        Bus.subscribe(@store, stream)

        state =
          opts
          |> put_in([:count], 0)
          |> put_in([:snapshot], nil)
          |> put_in([:catch_up_task], nil)
          |> put_in([:take_snapshot_task], nil)
          |> put_in([:waiters], [])

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

        {:ok, state, {:continue, :warm_up}}
      end

      @impl true
      def on_init(_projection), do: :ok

      @impl true
      def handle_continue(:warm_up, %{stream: stream, projection: proj} = s) do
        {last_snapshot_ms, ss} =
          :timer.tc(
            fn -> last_snapshot(proj) || {0, init_state(proj)} end,
            :millisecond
          )

        Process.send_after(self(), :tick_snapshot, @snapshot_after)

        send(self(), :tick_catch_up)

        {:noreply, %{s | snapshot: ss}}
      end

      @impl true
      def handle_info({:hint, _stream, _last_seq}, s) do
        send(self(), :tick_catch_up)
        {:noreply, s}
      end

      # take snapshot if enough events have been processed
      def handle_info(
            :tick_snapshot,
            %{count: count, take_snapshot_task: nil} = s
          )
          when count < @snapshot_every do
        task =
          Task.Supervisor.async_nolink(TaskSupervisor, fn ->
            {take_snap_ms, snap_result} =
              :timer.tc(fn -> persist_snapshot(s.projection, s.snapshot) end, :millisecond)

            :telemetry.execute(
              [
                :hume,
                :projection,
                :snapshot
              ],
              %{duration: take_snap_ms},
              %{
                module: __MODULE__,
                projection: s.projection,
                snapshot: s.snapshot,
                result: snap_result
              }
            )

            snap_result
          end)

        {:noreply, %{s | take_snapshot_task: task}}
      end

      # ignore if a snapshot task is already running
      def handle_info(:tick_snapshot, s) do
        Process.send_after(self(), :tick_snapshot, @snapshot_after)
        {:noreply, s}
      end

      # start catch-up task if none is running
      def handle_info(
            :tick_catch_up,
            %{catch_up_task: nil} = s
          ) do
        task =
          Task.Supervisor.async_nolink(TaskSupervisor, fn ->
            :telemetry.execute(
              [
                :hume,
                :projection,
                :catch_up,
                :start
              ],
              %{},
              %{module: __MODULE__, stream: s.stream}
            )

            result = do_catch_up(s.stream, s.snapshot, strict: @strict_online)

            :telemetry.execute(
              [
                :hume,
                :projection,
                :catch_up,
                :stop
              ],
              %{},
              %{module: __MODULE__, stream: s.stream}
            )

            result
          end)

        {:noreply, %{s | catch_up_task: task}}
      end

      # ignore if a catch-up task is already running
      def handle_info(:tick_catch_up, s) do
        {:noreply, s}
      end

      # handle completion of catch-up task
      def handle_info({ref, result}, %{catch_up_task: task} = s)
          when ref == task.ref do
        case result do
          {:ok, ss, count} ->
            Process.send_after(self(), :tick_catch_up, @catch_up_after)
            GenServer.cast(self(), :on_caught_up)
            for from <- s.waiters, do: GenServer.reply(from, ss)

            {:noreply,
             %{
               s
               | snapshot: ss,
                 count: s.count + count,
                 catch_up_task: nil,
                 waiters: []
             }}

          {:error, reason} ->
            {:stop, reason, %{s | snapshot: nil}}
        end
      end

      # handle completion of take-snapshot task
      def handle_info({ref, result}, %{take_snapshot_task: task} = s)
          when ref == task.ref do
        case result do
          :ok ->
            Process.send_after(self(), :tick_snapshot, @snapshot_after)
            {:noreply, %{s | count: 0, take_snapshot_task: nil}}

          {:error, reason} ->
            Logger.error("Failed to take snapshot: #{inspect(reason)}")
            Process.send_after(self(), :tick_snapshot, @snapshot_after)
            {:noreply, %{s | count: 0, take_snapshot_task: nil}}
        end
      end

      # ignore other messages from tasks
      def handle_info({_ref, _result}, s) do
        {:noreply, s}
      end

      # handle DOWN messages from tasks
      def handle_info(
            {:DOWN, ref, :process, _pid, _reason},
            %{take_snapshot_task: task} = s
          )
          when ref == task.ref do
        {:noreply, %{s | take_snapshot_task: nil}}
      end

      def handle_info(
            {:DOWN, ref, :process, _pid, _reason},
            %{catch_up_task: task} = s
          )
          when ref == task.ref do
        {:noreply, %{s | catch_up_task: nil}}
      end

      def handle_info({:DOWN, _ref, :process, _pid, _reason}, s) do
        {:noreply, s}
      end

      @impl true
      def handle_call({:snapshot, :dirty_read}, _from, s) do
        {:reply, s.snapshot, s}
      end

      def handle_call(:snapshot, from, %{catch_up_task: task} = s) when task != nil do
        {:noreply, %{s | waiters: [from | s.waiters]}}
      end

      def handle_call(:snapshot, _from, s) do
        {:reply, s.snapshot, s}
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

      def handle_cast(:take_snapshot, s) do
        send(self(), :tick_snapshot)
        {:noreply, s}
      end

      def handle_cast(:catch_up, s) do
        send(self(), :tick_catch_up)
        {:noreply, s}
      end

      @impl true
      def terminate(:normal, %{projection: proj, snapshot: snapshot} = s) do
        persist_snapshot(proj, snapshot)
        :ok
      end

      def terminate(_, _) do
        :ok
      end

      @impl true
      def on_caught_up(_snapshot), do: :ok

      def store, do: @store

      defp do_catch_up(stream, {since, state} = last_snapshot, opts) do
        strict = Keyword.get(opts, :strict, true)

        {events_ms, events} =
          :timer.tc(
            fn -> @store.events(stream, since) end,
            :millisecond
          )

        :timer.tc(
          fn -> Hume.Projection.replay(__MODULE__, last_snapshot, events, strict: strict) end,
          :millisecond
        )
        |> case do
          {replay_ms, {:ok, {seq, state}, count}} ->
            {:ok, {seq, state}, count}

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

    case apply(mod, :handle_event, [event, state]) do
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
  @spec replay(mod :: module(), snapshot(), events :: Enumerable.t()) ::
          {:ok, snapshot(), count :: pos_integer()} | {:error, term()}
  def replay(mod, snapshot, events, opts \\ []) do
    strict = Keyword.get(opts, :strict, true)
    start = System.monotonic_time()

    result =
      events
      |> Enum.reduce_while({snapshot, 0}, fn event, {ss, count} ->
        case evolve(mod, event, ss, strict: strict) do
          {:ok, new_ss} -> {:cont, {new_ss, count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:error, reason} -> {:error, reason}
        {ss, count} -> {:ok, ss, count}
      end

    stop = System.monotonic_time()

    :telemetry.execute(
      [
        :hume,
        :projection,
        :replay
      ],
      %{duration: stop - start},
      %{module: mod, result: result}
    )

    result
  end

  @doc """
  Requests the state machine to take a snapshot of its current state.

  ## Parameters
    - server: The PID or name of the state machine process.

  ## Returns
    - `:ok`: The snapshot request has been sent.
  """
  @spec take_snapshot(GenServer.server()) :: :ok
  def take_snapshot(server) do
    GenServer.cast(server, :take_snapshot)
  end

  @doc """
  Requests the state machine to catch up by processing any new events.

  ## Parameters
    - server: The PID or name of the state machine process.

  ## Returns
    - `:ok` The catch-up request has been sent.
  """
  @spec catch_up(GenServer.server()) :: :ok
  def catch_up(server) do
    GenServer.cast(server, :catch_up)
  end

  @doc """
  Retrieves the current snapshot of the state machine.

  ## Parameters
    - machine: The PID or name of the state machine process.
    - opts: Options for the call (default is an empty list).
      - `:timeout`: The maximum time to wait for a response (default is 5000 ms).
      - `:dirty`: If specified, allows a dirty read of the snapshot.
  ## Returns
    - `snapshot`: The current snapshot of the state machine.
  """
  @spec snapshot(GenServer.server(), [{:timeout, timeout()} | :dirty]) ::
          Hume.Projection.snapshot()
  def snapshot(machine, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    call_type = if :dirty in opts, do: :dirty_read, else: :snapshot

    case call_type do
      :dirty_read -> GenServer.call(machine, {:snapshot, :dirty_read}, timeout)
      :snapshot -> GenServer.call(machine, :snapshot, timeout)
    end
  end

  @doc """
  Retrieves the current state of the state machine.

  ## Parameters
    - machine: The PID or name of the state machine process.
    - opts: Options for the call (default is an empty list).
      - `:timeout`: The maximum time to wait for a response (default is 5000 ms).
      - `:dirty`: If specified, allows a dirty read of the snapshot.

  ## Returns
    - `state`: The current state of the state machine.
  """
  @spec state(GenServer.server(), [{:timeout, timeout()} | :dirty]) :: Hume.Projection.state()
  def state(machine, opts \\ []) do
    {_offset, state} = snapshot(machine, opts)
    state
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
    do_parse_options(tail, Map.put(map, :stream, stream), rest)
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
      map[:stream] == nil ->
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
