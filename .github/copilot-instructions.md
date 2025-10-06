# Hume: AI Coding Agent Instructions

## Project Overview
Hume is an Elixir library for building event-sourced state machines. It provides:
- State machines defined via `Hume.Projection` (or `Hume.Machine` for lower-level use)
- Event persistence (in-memory or ETS-based event stores)
- Snapshots for efficient recovery
- PubSub for event notification (`Phoenix.PubSub`)
- ETS table ownership transfer via a dedicated "heir" process

## Key Components
- `lib/hume/projection.ex`: Main macro/behaviour for defining state machines. Implements GenServer lifecycle, event replay, snapshotting, and event store integration.
- `lib/hume/event_store.ex` & `lib/hume/event_store/ets.ex`: Event store behaviour and ETS-based implementation.
- `lib/hume/event_order.ex`: Utilities for ordered event sequences (merge, check, sort).
- `lib/hume/bus.ex`: PubSub notification for event streams.
- `lib/hume/heir.ex`: Manages ETS table ownership transfer.
- `lib/hume/application.ex`: Application supervision tree (starts PubSub, Heir, and ETS event store).

## Developer Workflows
- **Build:** `mix compile`
- **Test:** `mix test` (property-based tests: `test/hume/projection_prop_test.exs`)
- **Lint:** `mix credo`
- **Docs:** `mix docs` (generates with ExDoc)
- **CI:** See `.github/workflows/ci.yml` (runs on push/PR, tests, and publishes on tag)

## Defining a State Machine
Example (see also `README.md`):
```elixir
defmodule MyProjection do
	use Hume.Projection, use_ets: true, store: Hume.EventStore.ETS

	@impl true
	def init_state(_), do: %{}

	@impl true
	def handle_event({:add, key, value}, state), do: {:ok, Map.put(state || %{}, key, value)}
	@impl true
	def handle_event({:remove, key}, state), do: {:ok, Map.delete(state || %{}, key)}
end
```

## Project Conventions & Patterns
- **State machines** must implement `init_state/1`, `handle_event/2`, and snapshot callbacks.
- **Event stores** must implement the `Hume.EventStore` behaviour.
- **ETS snapshotting** is enabled with `use_ets: true` and supports heir-based table transfer.
- **Event ordering** is enforced; see `Hume.EventOrder` for merge/sort utilities.
- **PubSub** is used for event notification; see `Hume.Bus`.
- **Testing** uses ExUnit and ExUnitProperties for property-based tests.
- **Formatting:** `mix format` (see `.formatter.exs`)
- **Linting:** `mix credo` (see `.credo.exs`)

## Integration Points
- **Phoenix.PubSub**: Used for event notification (see `lib/hume/bus.ex`).
- **Telemetry**: Emitted for key lifecycle events (init, snapshot, transfer).
- **ExDoc**: For documentation generation.

## Examples & References
- See `test/hume_test.exs` and `test/hume/projection_prop_test.exs` for usage patterns and property-based tests.
- See `README.md` for quickstart and usage.

---
If any section is unclear or missing, please request clarification or provide feedback for improvement.
