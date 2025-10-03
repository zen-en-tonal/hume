defmodule Hume.Machine do
  @moduledoc """
  Behaviour and macros for defining event-sourced state machines.

  This module provides a behaviour that can be implemented by modules to define
  event-sourced state machines. It also includes macros to automatically generate
  boilerplate code for managing state, handling events, taking snapshots, and
  persisting events.

  ## Usage

  To define a state machine, create a module that uses `Hume.Machine` and
  implements the required callbacks. You can choose to use an ETS-based
  event store by passing `:use_ets` to the `use` macro.
  """

  @type state :: term()
  @type event :: {seq(), term()}
  @type seq :: integer()
  @type offset :: seq()
  @type snapshot :: {offset(), state() | nil}

  @doc """
  Initial state of the machine.

  ## Parameters
    - name: The name or identifier of the machine.

  ## Returns
    - The initial state of the machine.
  """
  @callback init_state(name :: term()) :: state()

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
  @callback last_snapshot(name :: term()) :: snapshot() | nil

  @doc """
  Takes a snapshot of the current state.

  ## Parameters
    - snapshot: A tuple containing the offset and the current state.

  ## Returns
    - `:ok` if the snapshot was taken successfully.
    - `{:error, reason}` if an error occurred while taking the snapshot.
  """
  @callback take_snapshot(name :: term(), snapshot()) :: :ok | {:error, term()}

  @doc """
  Retireves events starting from a given offset.

  ## Parameters
    - offset: The offset from which to retrieve events.

  ## Returns
    - A list of events, where each event is a tuple containing the sequence number and event data.
  """
  @callback events(name :: term(), offset()) :: [event()]

  @doc """
  Persists an event to the event store.

  ## Parameters
    - event: The event to be persisted.

  ## Returns
    - `:ok` if the event was persisted successfully.
    - `{:error, reason}` if an error occurred while persisting the event.
  """
  @callback persist_event(name :: term(), event()) :: :ok | {:error, term()}

  @doc """
  Generates the next sequence number for an event.

  ## Returns
    - The next sequence number as an integer.
  """
  @callback next_sequence(name :: term()) :: seq()

  defmacro __using__(opts) do
    quote do
      unquote(impl_genserver())
      unquote(impl_default(opts))
    end
  end

  defp impl_genserver() do
    quote [:generated] do
      use GenServer

      @behaviour Hume.Machine

      @snapshot_every 100
      @snapshot_after :timer.seconds(30)

      def init(opts) do
        {:ok, %{snapshot: nil, name: find_name(opts), count: 0}, {:continue, :replay}}
      end

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, opts)
      end

      def handle_continue(:replay, %{name: name} = s) do
        {since, state} = ss = last_snapshot(name) || {0, init_state(name)}

        ss
        |> replay(events(name, since) |> Hume.EventOrder.ensure_ordered())
        |> case do
          {:ok, {seq, state}} ->
            Process.send_after(self(), :tick_snapshot, @snapshot_after)
            {:noreply, %{s | snapshot: {seq, state}}}

          {:error, reason} ->
            {:stop, reason, %{s | napshot: nil}}
        end
      end

      def handle_call({:event, event}, _from, %{snapshot: snapshot, name: name, count: count} = s) do
        seq = next_sequence(name)

        with {:ok, new_snapshot} <- evolve({seq, event}, snapshot),
             :ok <- persist_event(name, {seq, event}) do
          {:reply, {:ok, new_snapshot}, %{s | snapshot: new_snapshot, count: count + 1}}
        else
          {:error, reason} -> {:reply, {:error, reason}, s}
        end
      end

      def handle_call(:snapshot, _from, %{snapshot: snapshot} = s) do
        {:reply, snapshot, s}
      end

      def handle_info(:tick_snapshot, %{count: count} = s) when count < @snapshot_every do
        Process.send_after(self(), :tick_snapshot, @snapshot_after)
        {:noreply, s}
      end

      def handle_info(:tick_snapshot, %{name: name, snapshot: snapshot} = s) do
        case take_snapshot(name, snapshot) do
          :ok ->
            Process.send_after(self(), :tick_snapshot, @snapshot_after)
            {:noreply, %{s | count: 0}}

          {:error, reason} ->
            {:stop, reason, %{status: :error, snapshot: nil}}
        end
      end

      def next_sequence(_) do
        System.system_time()
      end

      def evolve(event, snapshot) do
        Hume.evolve(__MODULE__, event, snapshot)
      end

      def replay(snapshot, events) do
        Hume.replay(__MODULE__, snapshot, events)
      end

      defoverridable(next_sequence: 1)
    end
  end

  defp impl_default(:use_ets) do
    quote [:generated] do
      defp find_name(opt) do
        name = Keyword.get(opt, :name, __MODULE__)

        table_from =
          if Keyword.get(opt, :use_heir, true) do
            :heir
          else
            :new
          end

        tid = prepare_ets(name, table_from)

        {:ets, tid}
      end

      def prepare_ets(name, :heir) do
        case Hume.Heir.request_take(name, self()) do
          {:ok, tid} ->
            tid

          {:error, :not_found} ->
            :ets.new(name, [
              :ordered_set,
              {:read_concurrency, false},
              {:heir, Process.whereis(Hume.Heir), name}
            ])
        end
      end

      def prepare_ets(name, :new) do
        :ets.new(name, [
          :ordered_set,
          {:read_concurrency, false}
        ])
      end

      def last_snapshot({:ets, tid}) do
        case :ets.lookup(tid, :snapshot) do
          [{:snapshot, snapshot}] -> snapshot
          [] -> nil
        end
      end

      def take_snapshot({:ets, tid}, snapshot) do
        true = :ets.insert(tid, {:snapshot, snapshot})
        :ok
      end

      def events({:ets, tid}, offset) do
        :ets.select(tid, [
          {
            {{:event, :"$1"}, :"$2"},
            [{:>, :"$1", offset}],
            [:"$2"]
          }
        ])
        |> Enum.sort_by(fn {seq, _} -> seq end)
      end

      def persist_event({:ets, tid}, {seq, _evt} = event) do
        true = :ets.insert(tid, {{:event, seq}, event})
        :ok
      end

      def handle_info({:"ETS-TRANSFER", _, _, _}, s) do
        {:noreply, s}
      end
    end
  end

  defp impl_default(_) do
    quote [:generated] do
      defp find_name(opt) do
        Keyword.get(opt, :name, __MODULE__)
      end
    end
  end
end
