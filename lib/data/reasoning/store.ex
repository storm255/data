defmodule Data.Reasoning.Store do
  @moduledoc """
  Caches materialized `ExDatalog.Knowledge` per named reasoning group, so
  repeated queries against the same facts don't repeat fixpoint evaluation.

  Each name is an independent group: materializing or refreshing one never
  touches another, and nothing is recomputed until `materialize/4` or
  `refresh/4` is called again for that name. To reason across groups, merge
  their catalogs with `Data.Reasoning.Catalog.merge/2` and materialize the
  result under its own name — the source groups stay cached and untouched.

  Supervised once under `Data.Application` as a singleton, the same way
  `Data.Repo` is.
  """

  use GenServer

  alias Data.Reasoning.Catalog
  alias ExDatalog.Knowledge

  @doc """
  Starts the store. Intended to be supervised (see `Data.Application`);
  only one instance is expected to run, registered as `#{inspect(__MODULE__)}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Builds an `ExDatalog.Program` from `catalog` and `facts`, materializes it,
  and caches the resulting `Knowledge` under `name`, replacing whatever was
  previously cached there. `opts` is passed through to
  `ExDatalog.materialize/2` (e.g. `:storage`, `:explain`).

  Returns `{:ok, knowledge}` or `{:error, reason}`; on error, the
  previously cached value for `name` (if any) is left in place.
  """
  @spec materialize(atom(), Catalog.t(), [{String.t(), [term()]}], keyword()) ::
          {:ok, Knowledge.t()} | {:error, term()}
  def materialize(name, catalog, facts, opts \\ []) when is_atom(name) do
    GenServer.call(__MODULE__, {:materialize, name, catalog, facts, opts})
  end

  @doc """
  Re-materializes an existing group. An alias for `materialize/4`, named
  for the call site: use this when you already have a group and know its
  underlying facts changed, rather than when setting one up for the first
  time.
  """
  @spec refresh(atom(), Catalog.t(), [{String.t(), [term()]}], keyword()) ::
          {:ok, Knowledge.t()} | {:error, term()}
  def refresh(name, catalog, facts, opts \\ []), do: materialize(name, catalog, facts, opts)

  @doc """
  Returns the cached `Knowledge` for `name`, or `:error` if nothing has
  been materialized under that name (yet).
  """
  @spec get(atom()) :: {:ok, Knowledge.t()} | :error
  def get(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  @doc "Drops the cached knowledge for `name`, if any. Always returns `:ok`."
  @spec drop(atom()) :: :ok
  def drop(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:drop, name})
  end

  @doc false
  @impl true
  def init(state), do: {:ok, state}

  @doc false
  @impl true
  def handle_call({:materialize, name, catalog, facts, opts}, _from, state) do
    case catalog |> Catalog.build_program(facts) |> ExDatalog.materialize(opts) do
      {:ok, knowledge} = ok -> {:reply, ok, Map.put(state, name, knowledge)}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:get, name}, _from, state) do
    {:reply, Map.fetch(state, name), state}
  end

  def handle_call({:drop, name}, _from, state) do
    {:reply, :ok, Map.delete(state, name)}
  end
end
