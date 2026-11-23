defmodule Jido.Assembly.ChatStorage do
  @moduledoc """
  Assembly-owned SQLite storage for the Jido Chat V3 Runtime.

  The process owns one SQLite connection and serializes all storage changes.
  Each Runtime capability has a dedicated table. Values use the inspectable
  Jido JSON codec, and a command batch uses one SQLite transaction.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias Jido.Assembly.AgentRuns
  alias Jido.Assembly.ReleaseNotes
  alias Jido.Assembly.Seeds
  alias Jido.Chat.Runtime.Room.Membership
  alias Jido.Chat.Runtime.Storage

  alias Jido.Chat.Runtime.Storage.{
    Bindings,
    Commit,
    Connections,
    Engine,
    History,
    Links,
    Memberships,
    Outbox,
    Reactions,
    RoomDeclarations,
    Rooms
  }

  use Storage.Adapter,
    capabilities: [
      Links,
      Outbox,
      Reactions,
      Rooms,
      RoomDeclarations,
      Memberships,
      History,
      Connections,
      Bindings,
      Commit
    ]

  @schema_version 10
  @default_path "data/jido_assembly_v3.sqlite3"
  @default_name __MODULE__
  @deliveries_topic "assembly:bridge-deliveries"
  @agent_runs_topic "assembly:agent-runs"
  @automatic_delivery_attempts 3
  @default_retry_delay_ms 1_000

  @agent_run_columns """
  runs.id, runs.room_id, runs.trigger_id, runs.thread_id, runs.status, runs.reply, runs.error,
    handoffs.agent_id, handoffs.scope, handoffs.parent_run_id, results.payload, handoffs.peer_context,
    retries.reason, handoffs.rollout_required
  """
  @agent_run_from """
  FROM assembly_agent_runs AS runs
  LEFT JOIN assembly_agent_handoffs AS handoffs ON handoffs.run_id = runs.id
  LEFT JOIN assembly_agent_results AS results ON results.run_id = runs.id
  LEFT JOIN assembly_agent_retries AS retries ON retries.run_id = runs.id
  """

  @tables [
    "assembly_chat_links",
    "assembly_chat_outbox",
    "assembly_chat_rooms",
    "assembly_chat_room_declarations",
    "assembly_chat_memberships",
    "assembly_chat_history",
    "assembly_chat_reactions",
    "assembly_chat_connections",
    "assembly_chat_bindings"
  ]

  @type option :: {:path, Path.t()} | {:name, GenServer.name()} | {:id, term()}

  @doc "Starts the Assembly SQLite storage resource."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc "Returns the configured V3 database path."
  @spec path(GenServer.server()) :: {:ok, Path.t()}
  def path(server \\ @default_name), do: GenServer.call(server, :path)

  @doc "Counts stored replies by thread root for one room."
  def thread_reply_counts(server \\ @default_name, room_id) do
    GenServer.call(server, {:thread_reply_counts, room_id})
  end

  @doc false
  def list_agent_runs(server \\ @default_name, room_id),
    do: GenServer.call(server, {:list_agent_runs, room_id})

  @doc false
  def agent_runs_for_trigger(room_id, message_id),
    do: GenServer.call(@default_name, {:agent_runs_for_trigger, room_id, message_id})

  @doc false
  def subscribe_agent_runs, do: Phoenix.PubSub.subscribe(Jido.Assembly.PubSub, @agent_runs_topic)

  @doc false
  def get_agent_run(id), do: GenServer.call(@default_name, {:get_agent_run, id})

  @doc false
  def next_agent_run(allow_inference?),
    do: GenServer.call(@default_name, {:next_agent_run, allow_inference?})

  @doc false
  def update_agent_run(server \\ @default_name, id, expected_status, changes),
    do: GenServer.call(server, {:update_agent_run, id, expected_status, changes})

  @doc false
  def retry_agent_run(id, reason, delay_ms),
    do: GenServer.call(@default_name, {:retry_agent_run, id, reason, delay_ms})

  @doc false
  def interrupt_agent_runs(server \\ @default_name),
    do: GenServer.call(server, :interrupt_agent_runs)

  @doc false
  def ready_release_steps, do: GenServer.call(@default_name, :ready_release_steps)

  @doc false
  def defer_release_step(id), do: GenServer.call(@default_name, {:defer_release_step, id})

  @doc false
  def defer_bridge_reply(reply), do: GenServer.call(@default_name, {:defer_bridge_reply, reply})

  @doc false
  def pending_bridge_reply(account, external_room, external_id),
    do:
      GenServer.call(@default_name, {:pending_bridge_reply, account, external_room, external_id})

  @doc false
  def ready_bridge_replies, do: GenServer.call(@default_name, :ready_bridge_replies)

  @doc false
  def settle_bridge_reply(id, outcome),
    do: GenServer.call(@default_name, {:settle_bridge_reply, id, outcome})

  @doc false
  def message_deliveries(message_id),
    do: GenServer.call(@default_name, {:message_deliveries, message_id})

  @doc false
  def retry_message_delivery(message_id, account, external_room),
    do:
      GenServer.call(@default_name, {:retry_message_delivery, message_id, account, external_room})

  @doc false
  def record_delivery_rate_limit(id, result),
    do: GenServer.call(@default_name, {:record_delivery_rate_limit, id, result})

  @doc false
  def due_delivery_retries, do: GenServer.call(@default_name, :due_delivery_retries)

  @doc false
  def resume_delivery_retry(id), do: GenServer.call(@default_name, {:resume_delivery_retry, id})

  @doc false
  def subscribe_deliveries, do: Phoenix.PubSub.subscribe(Jido.Assembly.PubSub, @deliveries_topic)

  @doc "Reads one Assembly metadata value."
  @spec get_metadata(GenServer.server(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def get_metadata(server \\ @default_name, key) when is_binary(key),
    do: GenServer.call(server, {:get_metadata, key})

  @doc "Writes one Assembly metadata value."
  @spec put_metadata(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def put_metadata(server \\ @default_name, key, value)
      when is_binary(key) and is_binary(value),
      do: GenServer.call(server, {:put_metadata, key, value})

  @impl Links
  def put_link(server, link), do: command(server, {:put_link, link})

  @impl Links
  def link_for_local(server, account_id, local_message_id),
    do: query(server, {:link_for_local, account_id, local_message_id})

  @impl Links
  def links_for_local(server, account_id, local_message_id),
    do: query(server, {:links_for_local, account_id, local_message_id})

  @impl Links
  def link_for_external(server, account_id, external_room_id, external_message_id),
    do: query(server, {:link_for_external, account_id, external_room_id, external_message_id})

  @impl Outbox
  def put_work(server, work), do: command(server, {:put_work, work})

  @impl Outbox
  def get_work(server, id), do: query(server, {:get_work, id})

  @impl Outbox
  def list_work(server, account_id, opts \\ []),
    do: query(server, {:list_work, account_id, opts})

  @impl Outbox
  def update_work(server, id, expected_status, changes),
    do: command(server, {:update_work, id, expected_status, changes})

  @impl Rooms
  def insert_room(server, record), do: command(server, {:insert_room, record})

  @impl Rooms
  def get_room(server, id), do: query(server, {:get_room, id})

  @impl Rooms
  def list_rooms(server, opts \\ []), do: query(server, {:list_rooms, opts})

  @impl Rooms
  def update_room(server, id, revision, record),
    do: command(server, {:update_room, id, revision, record})

  @impl Rooms
  def delete_room(server, id, revision),
    do: command(server, {:delete_room, id, revision})

  @impl RoomDeclarations
  def insert_room_declaration(server, value),
    do: command(server, {:insert_room_declaration, value})

  @impl RoomDeclarations
  def get_room_declaration(server, id),
    do: query(server, {:get_room_declaration, id})

  @impl RoomDeclarations
  def list_room_declarations(server), do: query(server, :list_room_declarations)

  @impl RoomDeclarations
  def update_room_declaration(server, id, revision, value),
    do: command(server, {:update_room_declaration, id, revision, value})

  @impl RoomDeclarations
  def delete_room_declaration(server, id, revision),
    do: command(server, {:delete_room_declaration, id, revision})

  @impl Memberships
  def insert_membership(server, value), do: command(server, {:insert_membership, value})

  @impl Memberships
  def get_membership(server, room_id, member_key),
    do: query(server, {:get_membership, room_id, member_key})

  @impl Memberships
  def list_memberships(server, room_id, opts \\ []),
    do: query(server, {:list_memberships, room_id, opts})

  @impl Memberships
  def update_membership(server, room_id, member_key, revision, value),
    do: command(server, {:update_membership, room_id, member_key, revision, value})

  @impl History
  def insert_history(server, value), do: command(server, {:insert_history, value})

  @impl History
  def get_history(server, room_id, message_id),
    do: query(server, {:get_history, room_id, message_id})

  @impl History
  def list_history(server, room_id, opts \\ []),
    do: query(server, {:list_history, room_id, opts})

  @impl History
  def last_history_sequence(server, room_id),
    do: query(server, {:last_history_sequence, room_id})

  @impl Reactions
  def insert_reaction(server, value), do: command(server, {:insert_reaction, value})

  @impl Reactions
  def get_reaction(server, room_id, message_id, reaction, actor_key),
    do: query(server, {:get_reaction, room_id, message_id, reaction, actor_key})

  @impl Reactions
  def list_reactions(server, room_id, opts \\ []),
    do: query(server, {:list_reactions, room_id, opts})

  @impl Reactions
  def update_reaction(server, room_id, message_id, reaction, actor_key, revision, value),
    do:
      command(
        server,
        {:update_reaction, room_id, message_id, reaction, actor_key, revision, value}
      )

  @impl Connections
  def insert_connection(server, value), do: command(server, {:insert_connection, value})

  @impl Connections
  def get_connection(server, account_id), do: query(server, {:get_connection, account_id})

  @impl Connections
  def list_connections(server), do: query(server, :list_connections)

  @impl Connections
  def update_connection(server, account_id, revision, value),
    do: command(server, {:update_connection, account_id, revision, value})

  @impl Bindings
  def insert_binding(server, value), do: command(server, {:insert_binding, value})

  @impl Bindings
  def get_binding(server, account_id, external_room_id),
    do: query(server, {:get_binding, account_id, external_room_id})

  @impl Bindings
  def list_bindings(server, account_id, opts \\ []),
    do: query(server, {:list_bindings, account_id, opts})

  @impl Bindings
  def update_binding(server, account_id, external_room_id, revision, value),
    do: command(server, {:update_binding, account_id, external_room_id, revision, value})

  @impl Commit
  def commit(server, commands) when is_list(commands),
    do: GenServer.call(server, {:commit, commands})

  @impl true
  def init(opts) do
    path = opts |> Keyword.get(:path, configured_path()) |> normalize_path()

    with :ok <- ensure_parent(path),
         {:ok, db} <- Sqlite3.open(path),
         :ok <- Sqlite3.set_busy_timeout(db, 5_000),
         :ok <- migrate(db),
         :ok <- check_workspace_mode(db, Keyword.get(opts, :mode)),
         :ok <- migrate_agent_handoffs(db),
         :ok <- index_outbox_messages(db),
         {:ok, engine} <- load_engine(db) do
      {:ok, %{db: db, path: path, engine: engine}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp check_workspace_mode(_db, nil), do: :ok

  defp check_workspace_mode(db, mode) do
    mode = Atom.to_string(mode)

    with :ok <-
           run(
             db,
             """
             INSERT INTO assembly_chat_metadata(key, value)
               SELECT 'workspace_mode', ?1
               WHERE ?1 = 'demo' OR NOT EXISTS (SELECT 1 FROM assembly_chat_rooms)
               ON CONFLICT(key) DO NOTHING
             """,
             [mode]
           ),
         {:ok, [[^mode]]} <-
           query_all(
             db,
             "SELECT value FROM assembly_chat_metadata WHERE key = 'workspace_mode'",
             []
           ) do
      :ok
    else
      {:ok, _rows} -> {:error, :workspace_database_mode_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def handle_call(:path, _from, state), do: {:reply, {:ok, state.path}, state}

  def handle_call({:thread_reply_counts, room_id}, _from, state) do
    result =
      with {:ok, rows} <-
             query_all(
               state.db,
               """
               SELECT thread_id, COUNT(*) FROM assembly_chat_history
               WHERE room_id = ?1 AND thread_id IS NOT NULL
               GROUP BY thread_id
               """,
               [room_id]
             ) do
        {:ok, Map.new(rows, fn [root, count] -> {root, count} end)}
      end

    {:reply, result, state}
  end

  def handle_call({:get_metadata, key}, _from, state) do
    result =
      case query_all(
             state.db,
             "SELECT value FROM assembly_chat_metadata WHERE key = ?1 LIMIT 1",
             [key]
           ) do
        {:ok, [[value]]} -> {:ok, value}
        {:ok, []} -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call({:list_agent_runs, room_id}, _from, state) do
    result =
      with {:ok, rows} <-
             query_all(
               state.db,
               """
               SELECT #{@agent_run_columns}
               #{@agent_run_from}
               WHERE runs.room_id = ?1 ORDER BY runs.rowid
               """,
               [room_id]
             ) do
        {:ok, Enum.map(rows, &agent_run/1)}
      end

    {:reply, result, state}
  end

  def handle_call({:agent_runs_for_trigger, room_id, message_id}, _from, state) do
    result =
      with {:ok, rows} <-
             query_all(
               state.db,
               """
               SELECT runs.id, COALESCE(handoffs.agent_id, 'agent:triage'), handoffs.scope,
                      handoffs.parent_run_id, runs.status
               FROM assembly_agent_runs AS runs
               LEFT JOIN assembly_agent_handoffs AS handoffs ON handoffs.run_id = runs.id
               WHERE runs.room_id = ?1 AND runs.trigger_id = ?2 ORDER BY runs.rowid
               """,
               [room_id, message_id]
             ) do
        {:ok,
         Enum.map(rows, fn [id, agent_id, scope, parent_run_id, status] ->
           %{
             id: id,
             agent_id: agent_id,
             scope: scope,
             parent_run_id: parent_run_id,
             status: status
           }
         end)}
      end

    {:reply, result, state}
  end

  def handle_call({:next_agent_run, allow_inference?}, _from, state) do
    result =
      case query_all(
             state.db,
             """
             SELECT #{@agent_run_columns}
             #{@agent_run_from}
             WHERE runs.status = 'ready' OR (
               runs.status = 'queued' AND ?1 = 1 AND COALESCE(retries.available_at, 0) <= ?2 AND (
                 handoffs.scope IS NULL OR handoffs.scope != 'impact_and_rollout'
                 OR handoffs.peer_context = 0 OR EXISTS (
                   SELECT 1 FROM assembly_agent_runs AS bridge
                   WHERE bridge.id = handoffs.parent_run_id || ':provider_delivery'
                     AND bridge.status IN ('completed', 'failed')
                 )
               )
             )
             ORDER BY runs.status = 'ready' DESC, runs.rowid LIMIT 1
             """,
             [bool(allow_inference?), System.system_time(:millisecond)]
           ) do
        {:ok, [row]} -> {:ok, agent_run(row)}
        {:ok, []} -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call({:get_agent_run, id}, _from, state) do
    {:reply, fetch_agent_run(state.db, id), state}
  end

  def handle_call({:update_agent_run, id, expected, changes}, _from, state) do
    result =
      case changes do
        %{result: _data} ->
          transaction(state.db, fn -> save_agent_result(state.db, id, expected, changes) end)

        %{status: "failed"} ->
          transaction(state.db, fn ->
            with :ok <- set_agent_run_status(state.db, id, expected, changes),
                 {:ok, run} <- fetch_agent_run(state.db, id) do
              settle_failed_handoff(state.db, run, nil)
            end
          end)

        _ordinary ->
          set_agent_run_status(state.db, id, expected, changes)
      end

    if result == :ok, do: notify_agent_run(state.db, id)
    {:reply, result, state}
  end

  def handle_call({:retry_agent_run, id, reason, delay_ms}, _from, state) do
    available_at = System.system_time(:millisecond) + delay_ms

    result =
      transaction(state.db, fn ->
        with :ok <- set_agent_run_status(state.db, id, "running", %{status: "queued"}) do
          checked_update(
            state.db,
            """
            INSERT INTO assembly_agent_retries (run_id, reason, available_at)
            VALUES (?1, ?2, ?3) ON CONFLICT(run_id) DO NOTHING
            """,
            [id, reason, available_at]
          )
        end
      end)

    if result == :ok, do: notify_agent_run(state.db, id)
    {:reply, result, state}
  end

  def handle_call(:interrupt_agent_runs, _from, state) do
    result =
      with {:ok, rows} <-
             query_all(
               state.db,
               "SELECT #{@agent_run_columns} #{@agent_run_from} WHERE runs.status = 'running'",
               []
             ),
           runs = Enum.map(rows, &agent_run/1),
           :ok <- transaction(state.db, fn -> interrupt_inference(state.db, runs) end) do
        runs |> Enum.map(& &1.trigger_id) |> Enum.uniq() |> Enum.each(&notify_agent_trigger/1)
      end

    {:reply, result, state}
  end

  def handle_call(:ready_release_steps, _from, state) do
    result =
      with {:ok, rows} <-
             query_all(
               state.db,
               """
               SELECT input_id FROM assembly_release_steps
               WHERE available_at <= ?1 ORDER BY available_at, rowid LIMIT 20
               """,
               [System.system_time(:millisecond)]
             ) do
        {:ok, Enum.map(rows, fn [id] -> id end)}
      end

    {:reply, result, state}
  end

  def handle_call({:defer_release_step, id}, _from, state) do
    result =
      run(
        state.db,
        "UPDATE assembly_release_steps SET available_at = ?2 WHERE input_id = ?1",
        [id, System.system_time(:millisecond) + 1_000]
      )

    {:reply, result, state}
  end

  def handle_call({:defer_bridge_reply, reply}, _from, state) do
    result =
      run(
        state.db,
        """
        INSERT INTO assembly_bridge_replies
          (account_id, external_room_id, external_message_id, room_id, parent_id, root_id, payload)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ON CONFLICT(account_id, external_room_id, external_message_id) DO NOTHING
        """,
        [
          reply.account_id,
          reply.external_room_id,
          reply.external_message_id,
          reply.room_id,
          reply.parent_id,
          reply.root_id,
          encode!(reply)
        ]
      )

    {:reply, result, state}
  end

  def handle_call({:pending_bridge_reply, account, room, id}, _from, state) do
    result =
      case query_all(
             state.db,
             """
             SELECT room_id, parent_id, root_id FROM assembly_bridge_replies
             WHERE account_id = ?1 AND external_room_id = ?2 AND external_message_id = ?3
             """,
             [account, room, id]
           ) do
        {:ok, [[room_id, parent, root]]} -> {:ok, %{room_id: room_id, parent: parent, root: root}}
        {:ok, []} -> {:ok, nil}
        {:error, _reason} = error -> error
      end

    {:reply, result, state}
  end

  def handle_call(:ready_bridge_replies, _from, state) do
    result =
      with {:ok, rows} <-
             query_all(
               state.db,
               """
               SELECT pending.payload
               FROM assembly_bridge_replies pending
               JOIN assembly_chat_bindings binding
                 ON binding.account_id = pending.account_id
                 AND binding.external_room_id = pending.external_room_id
                 AND binding.room_id = pending.room_id
                 AND binding.enabled = 1
                 AND binding.direction IN ('inbound', 'both')
               LEFT JOIN assembly_chat_links parent
                 ON parent.account_id = pending.account_id
                 AND parent.external_room_id = pending.external_room_id
                 AND parent.external_message_id = pending.parent_id
               LEFT JOIN assembly_chat_links root
                 ON root.account_id = pending.account_id
                 AND root.external_room_id = pending.external_room_id
                 AND root.external_message_id = pending.root_id
               WHERE pending.retry_after <= ?1
                 AND (pending.parent_id IS NULL OR parent.local_message_id IS NOT NULL)
                 AND (pending.root_id IS NULL OR root.local_message_id IS NOT NULL)
               ORDER BY pending.retry_after, pending.rowid LIMIT 20
               """,
               [System.system_time(:millisecond)]
             ) do
        decode_rows(rows)
      end

    {:reply, result, state}
  end

  def handle_call({:settle_bridge_reply, reply, outcome}, _from, state) do
    key = [reply.account_id, reply.external_room_id, reply.external_message_id]
    predicate = "account_id = ?1 AND external_room_id = ?2 AND external_message_id = ?3"

    result =
      case outcome do
        :dispatched ->
          run(state.db, "DELETE FROM assembly_bridge_replies WHERE " <> predicate, key)

        :retry ->
          run(
            state.db,
            "UPDATE assembly_bridge_replies SET retry_after = ?4 WHERE " <> predicate,
            key ++ [System.system_time(:millisecond) + 1_000]
          )
      end

    {:reply, result, state}
  end

  def handle_call({:message_deliveries, message_id}, _from, state) do
    {:reply, outbound_work(state.db, message_id), state}
  end

  def handle_call({:retry_message_delivery, message_id, account, target}, _from, state) do
    with {:ok, work} <- outbound_work(state.db, message_id),
         {:ok, previous} <- retry_candidate(work, account, target),
         :ok <- active_retry_binding(state.engine, previous) do
      persist_command(state, {:put_work, new_delivery_attempt(previous)})
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:record_delivery_rate_limit, id, result}, _from, state) do
    case Engine.query(state.engine, {:get_work, id}) do
      {:ok, %{kind: :outbound, status: :submitted}} ->
        delay = result["retry_after_ms"] || @default_retry_delay_ms
        retry_at = min(System.system_time(:millisecond) + delay, 9_223_372_036_854_775_807)

        error =
          result
          |> Map.take(["code", "outcome", "retry_after_ms"])
          |> Map.put("retry_at", retry_at)

        persist_command(
          state,
          {:update_work, id, :submitted, %{status: :failed, last_error: error}}
        )

      {:ok, %{status: :failed, last_error: %{"code" => "rate_limited"}} = work} ->
        {:reply, {:ok, work}, state}

      _invalid ->
        {:reply, {:error, :invalid_rate_limited_delivery}, state}
    end
  end

  def handle_call(:due_delivery_retries, _from, state) do
    result =
      query_all(
        state.db,
        """
        SELECT retry.work_id
        FROM assembly_bridge_delivery_retries AS retry
        JOIN assembly_chat_outbox AS previous ON previous.id = retry.work_id
        JOIN assembly_chat_bindings AS binding
          ON binding.account_id = previous.account_id
          AND binding.external_room_id = retry.external_room_id
          AND binding.enabled = 1 AND binding.direction IN ('both', 'outbound')
        JOIN assembly_chat_history AS history
          ON history.room_id = binding.room_id AND history.message_id = previous.local_message_id
        LEFT JOIN assembly_chat_outbox AS next ON next.id = retry.next_id
        WHERE retry.retry_at <= ?1 AND (next.status IS NULL OR next.status = 'pending')
        ORDER BY retry.retry_at, retry.work_id
        """,
        [System.system_time(:millisecond)]
      )

    {:reply, result, state}
  end

  def handle_call({:resume_delivery_retry, id}, _from, state) do
    with {:ok, %{status: :failed, last_error: %{"retry_at" => retry_at}} = work} <-
           Engine.query(state.engine, {:get_work, id}),
         true <- Map.get(work, :attempt, 1) < @automatic_delivery_attempts,
         true <- retry_at <= System.system_time(:millisecond),
         :ok <- active_retry_binding(state.engine, work) do
      next = new_delivery_attempt(work)

      case Engine.query(state.engine, {:get_work, next.id}) do
        {:ok, nil} -> persist_command(state, {:put_work, next})
        {:ok, %{status: :pending} = existing} -> {:reply, {:ok, existing}, state}
        _settled -> {:reply, {:error, :delivery_already_retried}, state}
      end
    else
      _unavailable -> {:reply, {:error, :delivery_retry_unavailable}, state}
    end
  end

  def handle_call({:put_metadata, key, value}, _from, state) do
    result =
      run(
        state.db,
        """
        INSERT INTO assembly_chat_metadata(key, value) VALUES (?1, ?2)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
        [key, value]
      )

    {:reply, result, state}
  end

  def handle_call({:command, command}, _from, state) do
    case Engine.command(state.engine, command) do
      {:ok, result, engine} -> persist_reply(state, [command], [result], engine, result)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:commit, commands}, _from, state) do
    case Engine.commit(state.engine, commands) do
      {:ok, results, engine} -> persist_reply(state, commands, results, engine, results)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:query, storage_query}, _from, state),
    do: {:reply, Engine.query(state.engine, storage_query), state}

  @impl true
  def terminate(_reason, state) do
    _ = Sqlite3.close(state.db)
    :ok
  end

  defp command(server, value), do: GenServer.call(server, {:command, value})
  defp query(server, value), do: GenServer.call(server, {:query, value})

  defp normalize_path(":memory:"), do: ":memory:"
  defp normalize_path(path), do: Path.expand(path)

  defp ensure_parent(":memory:"), do: :ok
  defp ensure_parent(path), do: File.mkdir_p(Path.dirname(path))

  defp persist_reply(state, commands, results, engine, reply) do
    case persist_batch(state.db, Enum.zip(commands, results)) do
      :ok ->
        notify_delivery_changes(results)
        {:reply, {:ok, reply}, %{state | engine: engine}}

      {:error, reason} ->
        {:reply, {:error, {:storage_write_failed, reason}}, state}
    end
  end

  defp persist_command(state, command) do
    case Engine.command(state.engine, command) do
      {:ok, result, engine} -> persist_reply(state, [command], [result], engine, result)
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp notify_delivery_changes(results) do
    for %{kind: :outbound, local_message_id: message_id, status: status} <- results,
        status in [:completed, :failed, :unknown],
        Process.whereis(Jido.Assembly.PubSub) do
      Phoenix.PubSub.broadcast(
        Jido.Assembly.PubSub,
        @deliveries_topic,
        {:bridge_delivery_changed, message_id}
      )
    end
  end

  defp notify_agent_run(db, id) do
    case query_all(db, "SELECT trigger_id FROM assembly_agent_runs WHERE id = ?1", [id]) do
      {:ok, [[trigger_id]]} -> notify_agent_trigger(trigger_id)
      _unavailable -> :ok
    end
  end

  defp notify_agent_trigger(trigger_id) do
    if Process.whereis(Jido.Assembly.PubSub) do
      Phoenix.PubSub.broadcast(
        Jido.Assembly.PubSub,
        @agent_runs_topic,
        {:agent_run_changed, trigger_id}
      )
    end
  end

  defp outbound_work(db, message_id) do
    with {:ok, rows} <-
           query_all(
             db,
             "SELECT payload FROM assembly_chat_outbox WHERE local_message_id = ?1 ORDER BY id",
             [message_id]
           ),
         {:ok, work} <- decode_rows(rows) do
      {:ok, Enum.filter(work, &(&1[:kind] == :outbound))}
    end
  end

  defp retry_candidate(work, account, target) do
    work
    |> Enum.filter(&(&1.account_id == account and &1[:external_room_id] == target))
    |> Enum.max_by(&Map.get(&1, :attempt, 1), fn -> nil end)
    |> case do
      %{status: :failed, signal: %Jido.Signal{}, last_error: %{"outcome" => outcome}} = candidate
      when outcome in ["rejected", "not_attempted"] ->
        case candidate.last_error["retry_at"] do
          nil -> {:ok, candidate}
          retry_at -> delivery_retry_at(candidate, retry_at)
        end

      nil ->
        {:error, :delivery_not_found}

      %{status: :completed} ->
        {:error, :delivery_already_completed}

      %{status: :unknown} ->
        {:error, :delivery_unconfirmed}

      %{status: :failed} ->
        {:error, :delivery_not_retryable}

      _active ->
        {:error, :delivery_in_progress}
    end
  end

  defp delivery_retry_at(candidate, retry_at) do
    if retry_at <= System.system_time(:millisecond),
      do: {:ok, candidate},
      else: {:error, {:delivery_retry_after, retry_at}}
  end

  defp active_retry_binding(engine, work) do
    with {:ok, %{enabled: true, direction: direction, room_id: room_id}}
         when direction in [:both, :outbound] <-
           Engine.query(engine, {:get_binding, work.account_id, work.external_room_id}),
         {:ok, %_{}} <- Engine.query(engine, {:get_history, room_id, work.local_message_id}) do
      :ok
    else
      _inactive -> {:error, :delivery_binding_inactive}
    end
  end

  defp new_delivery_attempt(work) do
    attempt = Map.get(work, :attempt, 1) + 1
    original_id = Map.get(work, :original_id, work.id)
    id = next_delivery_id(work)
    signal = %{work.signal | id: id, data: Map.put(work.signal.data, "request_id", id)}

    work
    |> Map.drop([:lease_owner, :lease_expires_at, :result, :last_error])
    |> Map.merge(%{
      id: id,
      original_id: original_id,
      attempt: attempt,
      status: :pending,
      signal: signal
    })
  end

  defp next_delivery_id(work) do
    original_id = Map.get(work, :original_id, work.id)
    "#{original_id}/retry/#{Map.get(work, :attempt, 1) + 1}"
  end

  defp persist_batch(_db, []), do: :ok

  defp persist_batch(db, entries), do: transaction(db, fn -> persist_entries(db, entries) end)

  defp transaction(db, persist) do
    with :ok <- exec(db, "BEGIN IMMEDIATE"),
         :ok <- persist.(),
         :ok <- exec(db, "COMMIT") do
      :ok
    else
      {:error, reason} ->
        _ = exec(db, "ROLLBACK")
        {:error, reason}
    end
  end

  defp persist_entries(db, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case persist_entry(db, entry) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_entry(db, {{:put_link, _link}, result}) do
    upsert(
      db,
      "assembly_chat_links",
      ["account_id", "local_message_id", "external_room_id", "external_message_id", "payload"],
      [
        result.account_id,
        result.local_message_id,
        result.external_room_id,
        result.external_message_id,
        encode!(result)
      ],
      ["account_id", "local_message_id", "external_room_id"]
    )
  end

  defp persist_entry(db, {{:put_work, _work}, result}) do
    upsert(
      db,
      "assembly_chat_outbox",
      ["id", "account_id", "status", "payload", "local_message_id"],
      [
        result.id,
        result.account_id,
        Atom.to_string(result.status),
        encode!(result),
        result[:local_message_id]
      ],
      ["id"]
    )
  end

  defp persist_entry(db, {{:update_work, id, expected, _changes}, result}) do
    with :ok <-
           checked_update(
             db,
             "UPDATE assembly_chat_outbox SET account_id = ?1, status = ?2, payload = ?3, local_message_id = ?4 WHERE id = ?5 AND status = ?6",
             [
               result.account_id,
               Atom.to_string(result.status),
               encode!(result),
               result[:local_message_id],
               id,
               Atom.to_string(expected)
             ]
           ),
         :ok <- clear_dispatched_retry(db, result) do
      schedule_delivery_retry(db, result)
    end
  end

  defp persist_entry(db, {{:insert_room, _record}, result}) do
    upsert(
      db,
      "assembly_chat_rooms",
      ["id", "kind", "inserted_at", "revision", "payload"],
      [
        result.id,
        Atom.to_string(result.kind),
        DateTime.to_iso8601(result.inserted_at),
        result.revision,
        encode!(result)
      ],
      ["id"]
    )
  end

  defp persist_entry(db, {{:update_room, id, expected, _record}, result}) do
    checked_update(
      db,
      "UPDATE assembly_chat_rooms SET kind = ?1, inserted_at = ?2, revision = ?3, payload = ?4 WHERE id = ?5 AND revision = ?6",
      [
        Atom.to_string(result.kind),
        DateTime.to_iso8601(result.inserted_at),
        result.revision,
        encode!(result),
        id,
        expected
      ]
    )
  end

  defp persist_entry(db, {{:delete_room, id, expected}, :ok}),
    do: checked_delete(db, "assembly_chat_rooms", "id = ?1 AND revision = ?2", [id, expected])

  defp persist_entry(db, {{:insert_room_declaration, _value}, result}) do
    upsert(
      db,
      "assembly_chat_room_declarations",
      ["room_id", "desired", "revision", "payload"],
      [result.room_id, Atom.to_string(result.desired), result.revision, encode!(result)],
      ["room_id"]
    )
  end

  defp persist_entry(db, {{:update_room_declaration, id, expected, _value}, result}) do
    checked_update(
      db,
      "UPDATE assembly_chat_room_declarations SET desired = ?1, revision = ?2, payload = ?3 WHERE room_id = ?4 AND revision = ?5",
      [Atom.to_string(result.desired), result.revision, encode!(result), id, expected]
    )
  end

  defp persist_entry(db, {{:delete_room_declaration, id, expected}, :ok}),
    do:
      checked_delete(
        db,
        "assembly_chat_room_declarations",
        "room_id = ?1 AND revision = ?2",
        [id, expected]
      )

  defp persist_entry(db, {{:insert_membership, _value}, result}) do
    upsert(
      db,
      "assembly_chat_memberships",
      ["room_id", "member_key", "status", "revision", "payload"],
      [
        result.room_id,
        result.member_key,
        Atom.to_string(result.status),
        result.revision,
        encode!(result)
      ],
      ["room_id", "member_key"]
    )
  end

  defp persist_entry(
         db,
         {{:update_membership, room_id, member_key, expected, _value}, result}
       ) do
    checked_update(
      db,
      "UPDATE assembly_chat_memberships SET status = ?1, revision = ?2, payload = ?3 WHERE room_id = ?4 AND member_key = ?5 AND revision = ?6",
      [
        Atom.to_string(result.status),
        result.revision,
        encode!(result),
        room_id,
        member_key,
        expected
      ]
    )
  end

  defp persist_entry(db, {{:insert_history, _value}, result}) do
    step = ReleaseNotes.workflow_step(result)

    with :ok <- ensure_release_step_open(db, result, step),
         :ok <-
           upsert(
             db,
             "assembly_chat_history",
             ["room_id", "message_id", "sequence", "thread_id", "inserted_at", "payload"],
             [
               result.room_id,
               result.message_id,
               result.sequence,
               result.thread_id,
               DateTime.to_iso8601(result.inserted_at),
               encode!(result)
             ],
             ["room_id", "message_id"]
           ),
         :ok <- enqueue_agent_run(db, AgentRuns.trigger(result)),
         :ok <- persist_agent_reply(db, result, AgentRuns.reply(result)) do
      persist_release_step(db, result, step)
    end
  end

  defp persist_entry(db, {{:insert_reaction, _value}, result}) do
    upsert(
      db,
      "assembly_chat_reactions",
      ["id", "room_id", "message_id", "reaction", "actor_key", "status", "revision", "payload"],
      [
        result.id,
        result.room_id,
        result.message_id,
        result.reaction,
        result.actor_key,
        Atom.to_string(result.status),
        result.revision,
        encode!(result)
      ],
      ["room_id", "message_id", "reaction", "actor_key"]
    )
  end

  defp persist_entry(
         db,
         {{:update_reaction, room_id, message_id, reaction, actor_key, expected, _value}, result}
       ) do
    checked_update(
      db,
      "UPDATE assembly_chat_reactions SET id = ?1, status = ?2, revision = ?3, payload = ?4 WHERE room_id = ?5 AND message_id = ?6 AND reaction = ?7 AND actor_key = ?8 AND revision = ?9",
      [
        result.id,
        Atom.to_string(result.status),
        result.revision,
        encode!(result),
        room_id,
        message_id,
        reaction,
        actor_key,
        expected
      ]
    )
  end

  defp persist_entry(db, {{:insert_connection, _value}, result}) do
    upsert(
      db,
      "assembly_chat_connections",
      ["account_id", "desired", "revision", "payload"],
      [result.account_id, Atom.to_string(result.desired), result.revision, encode!(result)],
      ["account_id"]
    )
  end

  defp persist_entry(db, {{:update_connection, account_id, expected, _value}, result}) do
    checked_update(
      db,
      "UPDATE assembly_chat_connections SET desired = ?1, revision = ?2, payload = ?3 WHERE account_id = ?4 AND revision = ?5",
      [Atom.to_string(result.desired), result.revision, encode!(result), account_id, expected]
    )
  end

  defp persist_entry(db, {{:insert_binding, _value}, result}) do
    upsert(
      db,
      "assembly_chat_bindings",
      [
        "account_id",
        "external_room_id",
        "room_id",
        "direction",
        "enabled",
        "revision",
        "payload"
      ],
      [
        result.account_id,
        result.external_room_id,
        result.room_id,
        Atom.to_string(result.direction),
        bool(result.enabled),
        result.revision,
        encode!(result)
      ],
      ["account_id", "external_room_id"]
    )
  end

  defp persist_entry(
         db,
         {{:update_binding, account_id, external_room_id, expected, _value}, result}
       ) do
    checked_update(
      db,
      "UPDATE assembly_chat_bindings SET room_id = ?1, direction = ?2, enabled = ?3, revision = ?4, payload = ?5 WHERE account_id = ?6 AND external_room_id = ?7 AND revision = ?8",
      [
        result.room_id,
        Atom.to_string(result.direction),
        bool(result.enabled),
        result.revision,
        encode!(result),
        account_id,
        external_room_id,
        expected
      ]
    )
  end

  defp persist_entry(_db, _entry), do: {:error, :unsupported_storage_command}

  defp clear_dispatched_retry(db, %{status: :submitted, attempt: _number, id: id}) do
    run(db, "DELETE FROM assembly_bridge_delivery_retries WHERE next_id = ?1", [id])
  end

  defp clear_dispatched_retry(_db, _work), do: :ok

  defp schedule_delivery_retry(
         db,
         %{kind: :outbound, status: :failed, last_error: %{"retry_at" => retry_at}} = work
       ) do
    if Map.get(work, :attempt, 1) < @automatic_delivery_attempts do
      upsert(
        db,
        "assembly_bridge_delivery_retries",
        ["work_id", "next_id", "external_room_id", "retry_at"],
        [work.id, next_delivery_id(work), work.external_room_id, retry_at],
        ["work_id"]
      )
    else
      :ok
    end
  end

  defp schedule_delivery_retry(_db, _work), do: :ok

  defp checked_delete(db, table, predicate, params) do
    with :ok <- run(db, "DELETE FROM #{table} WHERE #{predicate}", params),
         :ok <- one_change(db) do
      :ok
    end
  end

  defp checked_update(db, sql, params) do
    with :ok <- run(db, sql, params),
         :ok <- one_change(db) do
      :ok
    end
  end

  defp upsert(db, table, columns, values, conflict_columns) do
    positions = 1..length(columns) |> Enum.map_join(", ", &"?#{&1}")

    updates =
      columns
      |> Enum.reject(&(&1 in conflict_columns))
      |> Enum.map_join(", ", &"#{&1} = excluded.#{&1}")

    sql = """
    INSERT INTO #{table}(#{Enum.join(columns, ", ")}) VALUES (#{positions})
    ON CONFLICT(#{Enum.join(conflict_columns, ", ")}) DO UPDATE SET #{updates}
    """

    run(db, sql, values)
  end

  defp one_change(db) do
    case query_all(db, "SELECT changes()", []) do
      {:ok, [[1]]} -> :ok
      {:ok, [[0]]} -> {:error, :storage_conflict}
      {:ok, [[count]]} -> {:error, {:unexpected_change_count, count}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_engine(db) do
    with {:ok, values} <- load_values(db),
         commands <- load_commands(values),
         {:ok, _results, engine} <- Engine.commit(Engine.new(), commands) do
      {:ok, engine}
    end
  end

  defp load_values(db) do
    Enum.reduce_while(@tables, {:ok, %{}}, fn table, {:ok, values} ->
      case query_all(db, "SELECT payload FROM #{table} ORDER BY rowid", []) do
        {:ok, rows} ->
          case decode_rows(rows) do
            {:ok, decoded} -> {:cont, {:ok, Map.put(values, table, decoded)}}
            {:error, reason} -> {:halt, {:error, {:storage_decode_failed, table, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:storage_load_failed, table, reason}}}
      end
    end)
  end

  defp decode_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [payload], {:ok, values} ->
        case Jido.Persistence.Codec.JSON.decode(payload, []) do
          {:ok, value} -> {:cont, {:ok, [value | values]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _row, _result ->
        {:halt, {:error, :invalid_storage_row}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp load_commands(values) do
    [
      commands(values, "assembly_chat_links", :put_link),
      commands(values, "assembly_chat_outbox", :put_work),
      commands(values, "assembly_chat_rooms", :insert_room),
      commands(values, "assembly_chat_room_declarations", :insert_room_declaration),
      commands(values, "assembly_chat_memberships", :insert_membership),
      commands(values, "assembly_chat_history", :insert_history),
      commands(values, "assembly_chat_reactions", :insert_reaction),
      commands(values, "assembly_chat_connections", :insert_connection),
      commands(values, "assembly_chat_bindings", :insert_binding)
    ]
    |> List.flatten()
  end

  defp commands(values, table, operation),
    do: Enum.map(Map.fetch!(values, table), &{operation, &1})

  defp encode!(value) do
    case Jido.Persistence.Codec.JSON.encode(value) do
      {:ok, encoded} -> encoded
      {:error, reason} -> throw({:storage_encode_failed, reason})
    end
  end

  defp enqueue_agent_run(_db, nil), do: :ok

  defp enqueue_agent_run(db, trigger) do
    case ensure_release_thread_open(db, trigger.room_id, trigger.thread_id) do
      :ok -> insert_agent_run(db, trigger)
      {:error, :release_run_cancelled} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp insert_agent_run(db, trigger) do
    with :ok <-
           run(
             db,
             """
             INSERT INTO assembly_agent_runs (id, room_id, trigger_id, thread_id, status)
             SELECT ?1, ?2, ?3, ?4, 'queued'
             WHERE ?6 IS NOT NULL OR EXISTS (
               SELECT 1 FROM assembly_chat_memberships
               WHERE room_id = ?2 AND member_key = ?5 AND status = 'active'
             )
             ON CONFLICT(id) DO NOTHING
             """,
             [
               trigger.id,
               trigger.room_id,
               trigger.trigger_id,
               trigger.thread_id,
               Membership.key(trigger.agent_id),
               trigger.parent_run_id
             ]
           ) do
      record_handoff_scope(db, trigger)
    end
  end

  defp record_handoff_scope(_db, %{scope: nil}), do: :ok

  defp record_handoff_scope(db, run) do
    run(
      db,
      """
      INSERT INTO assembly_agent_handoffs
        (run_id, agent_id, scope, parent_run_id, peer_context, rollout_required)
      SELECT id, ?2, ?3, ?4, ?5, ?6 FROM assembly_agent_runs WHERE id = ?1
      ON CONFLICT(run_id) DO NOTHING
      """,
      [
        run.id,
        run.agent_id,
        run.scope,
        run.parent_run_id,
        bool(run.peer_context),
        bool(run.rollout_required)
      ]
    )
  end

  defp persist_agent_reply(_db, _message, nil), do: :ok

  defp persist_agent_reply(db, message, %{scope: nil}),
    do: ensure_release_thread_open(db, message.room_id, message.thread_id)

  defp persist_agent_reply(db, message, reply) do
    with {:ok, [row]} <-
           query_all(
             db,
             """
             SELECT #{@agent_run_columns}
             #{@agent_run_from}
             WHERE runs.id = ?1 AND runs.room_id = ?2 AND runs.thread_id = ?3 AND runs.trigger_id = ?3
               AND runs.status = 'ready' AND handoffs.scope = ?4 AND handoffs.agent_id = ?5
             """,
             [reply.id, message.room_id, message.thread_id, reply.scope, reply.agent_id]
           ),
         run = agent_run(row),
         true <- reply.reply_to == AgentRuns.reply_parent(run) do
      settle_agent_reply(db, run)
    else
      {:error, _reason} = error -> error
      _mismatch -> {:error, :agent_handoff_reply_unavailable}
    end
  end

  defp settle_agent_reply(db, %{error: error} = run) when is_binary(error) do
    with :ok <- set_agent_run_status(db, run.id, "ready", %{status: "failed", error: error}) do
      settle_failed_handoff(db, run, AgentRuns.blocked_synthesis(run))
    end
  end

  defp settle_agent_reply(db, %{scope: "release_plan"} = run) do
    with :ok <- set_agent_run_status(db, run.id, "ready", %{status: "waiting"}) do
      enqueue_agent_handoffs(db, AgentRuns.handoffs(run))
    end
  end

  defp settle_agent_reply(db, %{scope: "release_synthesis"} = run) do
    with :ok <- set_agent_run_status(db, run.id, "ready", %{status: "completed"}) do
      set_agent_run_status(db, run.parent_run_id, "waiting", %{status: "completed"})
    end
  end

  defp settle_agent_reply(db, run) do
    with :ok <- set_agent_run_status(db, run.id, "ready", %{status: "completed"}) do
      queue_synthesis(db, run)
    end
  end

  defp settle_failed_handoff(
         db,
         %{scope: "impact_and_rollout", rollout_required: false} = run,
         _blocked
       ),
       do: queue_synthesis(db, run)

  defp settle_failed_handoff(_db, %{parent_run_id: nil}, _blocked), do: :ok

  defp settle_failed_handoff(db, run, blocked) do
    with :ok <- queue_blocked_synthesis(db, blocked) do
      run(
        db,
        "UPDATE assembly_agent_runs SET status = 'failed', error = ?2 WHERE id = ?1 AND status = 'waiting'",
        [run.parent_run_id, run.error]
      )
    end
  end

  defp queue_synthesis(db, run) do
    [bridge, runbook] = AgentRuns.finding_run_ids(run.parent_run_id)

    case query_all(
           db,
           """
           SELECT COUNT(*) FROM assembly_agent_runs AS child
           JOIN assembly_agent_handoffs AS handoff ON handoff.run_id = child.id
           JOIN assembly_agent_runs AS parent ON parent.id = handoff.parent_run_id
           WHERE child.id IN (?1, ?2) AND (
               child.status = 'completed' OR
               (child.id = ?2 AND child.status = 'failed' AND handoff.rollout_required = 0)
             )
             AND parent.id = ?3 AND parent.status = 'waiting'
             AND child.room_id = ?4 AND child.thread_id = ?5 AND child.trigger_id = ?6
           """,
           [bridge, runbook, run.parent_run_id, run.room_id, run.thread_id, run.trigger_id]
         ) do
      {:ok, [[2]]} -> enqueue_agent_run(db, AgentRuns.synthesis(run))
      {:ok, _pending} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp queue_blocked_synthesis(_db, nil), do: :ok

  defp queue_blocked_synthesis(db, {run, changes}) do
    case query_all(db, "SELECT status FROM assembly_agent_runs WHERE id = ?1", [run.parent_run_id]) do
      {:ok, [["waiting"]]} ->
        with :ok <- enqueue_agent_run(db, run) do
          save_agent_result(db, run.id, "queued", changes)
        end

      {:ok, _closed} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_agent_run(db, id) do
    case query_all(db, "SELECT #{@agent_run_columns} #{@agent_run_from} WHERE runs.id = ?1", [id]) do
      {:ok, [row]} -> {:ok, agent_run(row)}
      {:ok, []} -> {:error, :agent_run_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp interrupt_inference(db, runs) do
    changes = %{status: "failed", error: "inference_interrupted"}

    Enum.reduce_while(runs, :ok, fn run, :ok ->
      result =
        with :ok <- set_agent_run_status(db, run.id, "running", changes) do
          settle_failed_handoff(db, %{run | error: changes.error}, nil)
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp enqueue_agent_handoffs(db, handoffs) do
    Enum.reduce_while(handoffs, :ok, fn handoff, :ok ->
      case enqueue_agent_run(db, handoff) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp set_agent_run_status(db, id, expected, changes) do
    checked_update(
      db,
      """
      UPDATE assembly_agent_runs
      SET status = ?1, reply = COALESCE(?2, reply), error = ?3
      WHERE id = ?4 AND status = ?5
      """,
      [changes.status, changes[:reply], changes[:error], id, expected]
    )
  end

  defp save_agent_result(db, id, expected, %{result: data} = changes) do
    with :ok <- set_agent_run_status(db, id, expected, changes) do
      run(
        db,
        "INSERT INTO assembly_agent_results (run_id, payload) VALUES (?1, ?2)",
        [id, Jason.encode!(data)]
      )
    end
  end

  defp agent_run([
         id,
         room_id,
         trigger_id,
         thread_id,
         status,
         reply,
         error,
         agent,
         scope,
         parent,
         data,
         peer_context,
         retry_reason,
         rollout_required
       ]) do
    %{
      id: id,
      room_id: room_id,
      trigger_id: trigger_id,
      thread_id: thread_id,
      status: status,
      reply: reply,
      error: error,
      agent_id: agent || "agent:triage",
      scope: scope,
      parent_run_id: parent,
      result: data && Jason.decode!(data),
      peer_context: peer_context != 0,
      retry_reason: retry_reason,
      rollout_required: rollout_required != 0
    }
  end

  defp ensure_release_step_open(db, %{room_id: room, thread_id: root}, {kind, _step})
       when kind in [:queue, :complete],
       do: ensure_release_thread_open(db, room, root)

  defp ensure_release_step_open(_db, _record, _step), do: :ok

  defp ensure_release_thread_open(db, room, root) do
    if room == Seeds.release_room_id() and is_binary(root) do
      check_release_cancellation(db, room, root)
    else
      :ok
    end
  end

  defp check_release_cancellation(db, room, root) do
    case query_all(
           db,
           "SELECT 1 FROM assembly_chat_history WHERE room_id = ?1 AND message_id = ?2",
           [room, ReleaseNotes.cancellation_id(root)]
         ) do
      {:ok, []} -> :ok
      {:ok, [_row]} -> {:error, :release_run_cancelled}
      {:error, _reason} = error -> error
    end
  end

  defp persist_release_step(db, _record, {:queue, %{id: id}}) do
    run(
      db,
      "INSERT INTO assembly_release_steps (input_id) VALUES (?1) ON CONFLICT(input_id) DO NOTHING",
      [id]
    )
  end

  defp persist_release_step(db, _record, {:complete, id}),
    do: run(db, "DELETE FROM assembly_release_steps WHERE input_id = ?1", [id])

  defp persist_release_step(db, %{room_id: room, thread_id: root}, {:cancel, step}) do
    with {:ok, [[payload]]} <-
           query_all(
             db,
             "SELECT payload FROM assembly_chat_history WHERE room_id = ?1 AND message_id = ?2",
             [room, root]
           ),
         {:ok, request} <- Jido.Persistence.Codec.JSON.decode(payload, []),
         true <- ReleaseNotes.cancellation_owner?(request, step.person),
         {:ok, []} <-
           query_all(
             db,
             """
             SELECT 1 FROM assembly_chat_history WHERE room_id = ?1 AND thread_id = ?2
               AND message_id GLOB 'release:publish:approval:*' LIMIT 1
             """,
             [room, root]
           ),
         :ok <-
           run(
             db,
             """
             UPDATE assembly_agent_runs SET status = 'cancelled', error = NULL
             WHERE room_id = ?1 AND thread_id = ?2 AND status IN ('queued', 'running', 'ready', 'waiting')
             """,
             [room, root]
           ) do
      run(db, "DELETE FROM assembly_release_steps WHERE input_id IN (?1, ?2)", step.input_ids)
    else
      {:error, _reason} = error -> error
      _mismatch -> {:error, :release_cancellation_unavailable}
    end
  end

  defp persist_release_step(_db, _record, nil), do: :ok

  defp migrate(db) do
    statements = [
      "PRAGMA foreign_keys = ON",
      "PRAGMA journal_mode = WAL",
      "CREATE TABLE IF NOT EXISTS assembly_chat_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_links (account_id TEXT NOT NULL, local_message_id TEXT NOT NULL, external_room_id TEXT NOT NULL, external_message_id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (account_id, local_message_id, external_room_id), UNIQUE (account_id, external_room_id, external_message_id))",
      "CREATE INDEX IF NOT EXISTS assembly_chat_links_local_idx ON assembly_chat_links(account_id, local_message_id, external_room_id)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_outbox (id TEXT PRIMARY KEY, account_id TEXT NOT NULL, status TEXT NOT NULL, payload TEXT NOT NULL, local_message_id TEXT)",
      "CREATE INDEX IF NOT EXISTS assembly_chat_outbox_account_idx ON assembly_chat_outbox(account_id, status, id)",
      "CREATE TABLE IF NOT EXISTS assembly_bridge_delivery_retries (work_id TEXT PRIMARY KEY, next_id TEXT NOT NULL UNIQUE, external_room_id TEXT NOT NULL, retry_at INTEGER NOT NULL)",
      "CREATE INDEX IF NOT EXISTS assembly_bridge_delivery_retries_due_idx ON assembly_bridge_delivery_retries(retry_at)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_rooms (id TEXT PRIMARY KEY, kind TEXT NOT NULL, inserted_at TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL)",
      "CREATE INDEX IF NOT EXISTS assembly_chat_rooms_cursor_idx ON assembly_chat_rooms(inserted_at, id)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_room_declarations (room_id TEXT PRIMARY KEY, desired TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_memberships (room_id TEXT NOT NULL, member_key TEXT NOT NULL, status TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (room_id, member_key))",
      "CREATE INDEX IF NOT EXISTS assembly_chat_memberships_query_idx ON assembly_chat_memberships(room_id, status, member_key)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_history (room_id TEXT NOT NULL, message_id TEXT NOT NULL, sequence INTEGER NOT NULL, thread_id TEXT, inserted_at TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (room_id, message_id), UNIQUE (room_id, sequence))",
      "CREATE INDEX IF NOT EXISTS assembly_chat_history_query_idx ON assembly_chat_history(room_id, thread_id, sequence)",
      "CREATE TABLE IF NOT EXISTS assembly_agent_runs (id TEXT PRIMARY KEY, room_id TEXT NOT NULL, trigger_id TEXT NOT NULL, thread_id TEXT NOT NULL, status TEXT NOT NULL, reply TEXT, error TEXT)",
      "CREATE INDEX IF NOT EXISTS assembly_agent_runs_room_idx ON assembly_agent_runs(room_id)",
      "CREATE INDEX IF NOT EXISTS assembly_agent_runs_trigger_idx ON assembly_agent_runs(room_id, trigger_id)",
      "CREATE INDEX IF NOT EXISTS assembly_agent_runs_pending_idx ON assembly_agent_runs(status) WHERE status IN ('queued', 'ready')",
      "CREATE TABLE IF NOT EXISTS assembly_agent_handoffs (run_id TEXT PRIMARY KEY REFERENCES assembly_agent_runs(id), agent_id TEXT NOT NULL, scope TEXT NOT NULL, parent_run_id TEXT REFERENCES assembly_agent_runs(id), peer_context INTEGER NOT NULL DEFAULT 1, rollout_required INTEGER NOT NULL DEFAULT 1)",
      "CREATE TABLE IF NOT EXISTS assembly_agent_results (run_id TEXT PRIMARY KEY REFERENCES assembly_agent_runs(id), payload TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS assembly_agent_retries (run_id TEXT PRIMARY KEY REFERENCES assembly_agent_runs(id), reason TEXT NOT NULL, available_at INTEGER NOT NULL)",
      "CREATE TABLE IF NOT EXISTS assembly_release_steps (input_id TEXT PRIMARY KEY, available_at INTEGER NOT NULL DEFAULT 0)",
      "CREATE INDEX IF NOT EXISTS assembly_release_steps_due_idx ON assembly_release_steps(available_at)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_reactions (id TEXT NOT NULL UNIQUE, room_id TEXT NOT NULL, message_id TEXT NOT NULL, reaction TEXT NOT NULL, actor_key TEXT NOT NULL, status TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (room_id, message_id, reaction, actor_key))",
      "CREATE INDEX IF NOT EXISTS assembly_chat_reactions_query_idx ON assembly_chat_reactions(room_id, message_id, status, id)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_connections (account_id TEXT PRIMARY KEY, desired TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_bindings (account_id TEXT NOT NULL, external_room_id TEXT NOT NULL, room_id TEXT NOT NULL, direction TEXT NOT NULL, enabled INTEGER NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (account_id, external_room_id))",
      "CREATE INDEX IF NOT EXISTS assembly_chat_bindings_query_idx ON assembly_chat_bindings(account_id, enabled, direction, external_room_id)",
      "CREATE TABLE IF NOT EXISTS assembly_bridge_replies (account_id TEXT NOT NULL, external_room_id TEXT NOT NULL, external_message_id TEXT NOT NULL, room_id TEXT NOT NULL, parent_id TEXT, root_id TEXT, retry_after INTEGER NOT NULL DEFAULT 0, payload TEXT NOT NULL, PRIMARY KEY (account_id, external_room_id, external_message_id))",
      "CREATE INDEX IF NOT EXISTS assembly_bridge_replies_ready_idx ON assembly_bridge_replies(retry_after)"
    ]

    Enum.reduce_while(statements, :ok, fn statement, :ok ->
      case exec(db, statement) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:storage_migration_failed, reason}}}
      end
    end)
  end

  defp migrate_agent_handoffs(db) do
    transaction(db, fn ->
      with {:ok, columns} <- query_all(db, "PRAGMA table_info(assembly_agent_handoffs)", []),
           :ok <- ensure_agent_peer_context(db, columns),
           :ok <- ensure_agent_rollout_policy(db, columns) do
        exec(db, "PRAGMA user_version = #{@schema_version}")
      end
    end)
  end

  defp ensure_agent_rollout_policy(db, columns) do
    if Enum.any?(columns, &match?([_, "rollout_required" | _], &1)) do
      :ok
    else
      exec(
        db,
        "ALTER TABLE assembly_agent_handoffs ADD COLUMN rollout_required INTEGER NOT NULL DEFAULT 1"
      )
    end
  end

  defp ensure_agent_peer_context(db, columns) do
    if Enum.any?(columns, &match?([_, "peer_context" | _], &1)) do
      :ok
    else
      with :ok <-
             exec(
               db,
               "ALTER TABLE assembly_agent_handoffs ADD COLUMN peer_context INTEGER NOT NULL DEFAULT 1"
             ) do
        run(
          db,
          """
          UPDATE assembly_agent_runs SET status = 'waiting'
          WHERE status = 'completed' AND id IN (
            SELECT handoffs.parent_run_id FROM assembly_agent_handoffs AS handoffs
            JOIN assembly_agent_runs AS child ON child.id = handoffs.run_id
            WHERE child.status IN ('queued', 'running', 'ready')
          )
          """,
          []
        )
      end
    end
  end

  defp index_outbox_messages(db) do
    with {:ok, columns} <- query_all(db, "PRAGMA table_info(assembly_chat_outbox)", []),
         :ok <- ensure_outbox_message_column(db, columns) do
      exec(
        db,
        "CREATE INDEX IF NOT EXISTS assembly_chat_outbox_message_idx ON assembly_chat_outbox(local_message_id, id)"
      )
    end
  end

  defp ensure_outbox_message_column(db, columns) do
    if Enum.any?(columns, &match?([_, "local_message_id" | _], &1)) do
      :ok
    else
      with :ok <- exec(db, "BEGIN IMMEDIATE"),
           :ok <- exec(db, "ALTER TABLE assembly_chat_outbox ADD COLUMN local_message_id TEXT"),
           {:ok, rows} <- query_all(db, "SELECT payload FROM assembly_chat_outbox", []),
           {:ok, work} <- decode_rows(rows),
           :ok <- backfill_outbox_messages(db, work),
           :ok <- exec(db, "COMMIT") do
        :ok
      else
        {:error, _reason} = error ->
          _ = exec(db, "ROLLBACK")
          error
      end
    end
  end

  defp backfill_outbox_messages(db, work) do
    Enum.reduce_while(work, :ok, fn
      %{id: id, local_message_id: message_id}, :ok ->
        case run(db, "UPDATE assembly_chat_outbox SET local_message_id = ?1 WHERE id = ?2", [
               message_id,
               id
             ]) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      _other, :ok ->
        {:cont, :ok}
    end)
  end

  defp exec(db, sql) do
    case Sqlite3.execute(db, sql) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(db, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, params) do
          case Sqlite3.step(db, statement) do
            :done -> :ok
            {:row, _row} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end
      after
        _ = Sqlite3.release(db, statement)
      end
    end
  end

  defp query_all(db, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, params) do
          collect_rows(db, statement, [])
        end
      after
        _ = Sqlite3.release(db, statement)
      end
    end
  end

  defp collect_rows(db, statement, rows) do
    case Sqlite3.step(db, statement) do
      {:row, row} -> collect_rows(db, statement, [row | rows])
      :done -> {:ok, Enum.reverse(rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp configured_path do
    Application.get_env(:jido_assembly, :sqlite_path, @default_path)
  end

  defp bool(true), do: 1
  defp bool(false), do: 0
end
