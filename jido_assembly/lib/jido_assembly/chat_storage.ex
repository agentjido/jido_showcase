defmodule Jido.Assembly.ChatStorage do
  @moduledoc """
  Assembly-owned SQLite storage for the Jido Chat V3 Runtime.

  The process owns one SQLite connection and serializes all storage changes.
  Each Runtime capability has a dedicated table. Values use the inspectable
  Jido JSON codec, and a command batch uses one SQLite transaction.
  """

  use GenServer

  alias Exqlite.Sqlite3
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

  @schema_version 1
  @default_path "data/jido_assembly_v3.sqlite3"
  @default_name __MODULE__

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
         {:ok, engine} <- load_engine(db) do
      {:ok, %{db: db, path: path, engine: engine}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:path, _from, state), do: {:reply, {:ok, state.path}, state}

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
      :ok -> {:reply, {:ok, reply}, %{state | engine: engine}}
      {:error, reason} -> {:reply, {:error, {:storage_write_failed, reason}}, state}
    end
  end

  defp persist_batch(_db, []), do: :ok

  defp persist_batch(db, entries) do
    with :ok <- exec(db, "BEGIN IMMEDIATE"),
         :ok <- persist_entries(db, entries),
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
      ["id", "account_id", "status", "payload"],
      [result.id, result.account_id, Atom.to_string(result.status), encode!(result)],
      ["id"]
    )
  end

  defp persist_entry(db, {{:update_work, id, expected, _changes}, result}) do
    checked_update(
      db,
      "UPDATE assembly_chat_outbox SET account_id = ?1, status = ?2, payload = ?3 WHERE id = ?4 AND status = ?5",
      [
        result.account_id,
        Atom.to_string(result.status),
        encode!(result),
        id,
        Atom.to_string(expected)
      ]
    )
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
    )
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

  defp migrate(db) do
    statements = [
      "PRAGMA foreign_keys = ON",
      "PRAGMA journal_mode = WAL",
      "CREATE TABLE IF NOT EXISTS assembly_chat_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_links (account_id TEXT NOT NULL, local_message_id TEXT NOT NULL, external_room_id TEXT NOT NULL, external_message_id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (account_id, local_message_id, external_room_id), UNIQUE (account_id, external_room_id, external_message_id))",
      "CREATE INDEX IF NOT EXISTS assembly_chat_links_local_idx ON assembly_chat_links(account_id, local_message_id, external_room_id)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_outbox (id TEXT PRIMARY KEY, account_id TEXT NOT NULL, status TEXT NOT NULL, payload TEXT NOT NULL)",
      "CREATE INDEX IF NOT EXISTS assembly_chat_outbox_account_idx ON assembly_chat_outbox(account_id, status, id)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_rooms (id TEXT PRIMARY KEY, kind TEXT NOT NULL, inserted_at TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL)",
      "CREATE INDEX IF NOT EXISTS assembly_chat_rooms_cursor_idx ON assembly_chat_rooms(inserted_at, id)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_room_declarations (room_id TEXT PRIMARY KEY, desired TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_memberships (room_id TEXT NOT NULL, member_key TEXT NOT NULL, status TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (room_id, member_key))",
      "CREATE INDEX IF NOT EXISTS assembly_chat_memberships_query_idx ON assembly_chat_memberships(room_id, status, member_key)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_history (room_id TEXT NOT NULL, message_id TEXT NOT NULL, sequence INTEGER NOT NULL, thread_id TEXT, inserted_at TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (room_id, message_id), UNIQUE (room_id, sequence))",
      "CREATE INDEX IF NOT EXISTS assembly_chat_history_query_idx ON assembly_chat_history(room_id, thread_id, sequence)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_reactions (id TEXT NOT NULL UNIQUE, room_id TEXT NOT NULL, message_id TEXT NOT NULL, reaction TEXT NOT NULL, actor_key TEXT NOT NULL, status TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (room_id, message_id, reaction, actor_key))",
      "CREATE INDEX IF NOT EXISTS assembly_chat_reactions_query_idx ON assembly_chat_reactions(room_id, message_id, status, id)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_connections (account_id TEXT PRIMARY KEY, desired TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS assembly_chat_bindings (account_id TEXT NOT NULL, external_room_id TEXT NOT NULL, room_id TEXT NOT NULL, direction TEXT NOT NULL, enabled INTEGER NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (account_id, external_room_id))",
      "CREATE INDEX IF NOT EXISTS assembly_chat_bindings_query_idx ON assembly_chat_bindings(account_id, enabled, direction, external_room_id)",
      "PRAGMA user_version = #{@schema_version}"
    ]

    Enum.reduce_while(statements, :ok, fn statement, :ok ->
      case exec(db, statement) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:storage_migration_failed, reason}}}
      end
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
