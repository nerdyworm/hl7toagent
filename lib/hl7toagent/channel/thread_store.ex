defmodule Hl7toagent.Channel.ThreadStore do
  @moduledoc """
  SQLite-backed conversation thread store. Persists agent conversation
  context so that replies (e.g. email replies) can continue a thread.
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Public API ---

  def create_thread(channel_name, messages) do
    GenServer.call(__MODULE__, {:create, channel_name, messages})
  end

  def get_thread(thread_id) do
    GenServer.call(__MODULE__, {:get, thread_id})
  end

  def update_thread(thread_id, messages) do
    GenServer.call(__MODULE__, {:update, thread_id, messages})
  end

  def add_ref(thread_id, ref) do
    GenServer.call(__MODULE__, {:add_ref, thread_id, ref})
  end

  def find_by_ref(ref) do
    GenServer.call(__MODULE__, {:find_by_ref, ref})
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    project_dir = Keyword.get(opts, :project_dir) ||
      Application.get_env(:hl7toagent, :project_dir, File.cwd!())

    db_path = Path.join(project_dir, "threads.db")
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)

    create_tables(conn)

    {:ok, %{conn: conn}}
  end

  @impl true
  def handle_call({:create, channel_name, messages}, _from, state) do
    thread_id = generate_id()
    now = System.system_time(:second)
    messages_json = Jason.encode!(messages)

    exec(state.conn,
      "INSERT INTO threads (id, channel_name, messages, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)",
      [thread_id, channel_name, messages_json, now, now]
    )

    {:reply, {:ok, thread_id}, state}
  end

  def handle_call({:get, thread_id}, _from, state) do
    case query_one(state.conn,
      "SELECT channel_name, messages FROM threads WHERE id = ?1", [thread_id]) do
      {:ok, [channel_name, messages_json]} ->
        messages = Jason.decode!(messages_json)
        {:reply, {:ok, %{channel_name: channel_name, messages: messages}}, state}

      :none ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:update, thread_id, messages}, _from, state) do
    now = System.system_time(:second)
    messages_json = Jason.encode!(messages)

    exec(state.conn,
      "UPDATE threads SET messages = ?1, updated_at = ?2 WHERE id = ?3",
      [messages_json, now, thread_id]
    )

    {:reply, :ok, state}
  end

  def handle_call({:add_ref, thread_id, ref}, _from, state) do
    exec(state.conn,
      "INSERT OR IGNORE INTO thread_refs (ref, thread_id) VALUES (?1, ?2)",
      [ref, thread_id]
    )

    {:reply, :ok, state}
  end

  def handle_call({:find_by_ref, ref}, _from, state) do
    case query_one(state.conn,
      "SELECT thread_id FROM thread_refs WHERE ref = ?1", [ref]) do
      {:ok, [thread_id]} ->
        {:reply, {:ok, thread_id}, state}

      :none ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # --- Helpers ---

  defp create_tables(conn) do
    :ok = Exqlite.Sqlite3.execute(conn, """
    CREATE TABLE IF NOT EXISTS threads (
      id TEXT PRIMARY KEY,
      channel_name TEXT NOT NULL,
      messages TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
    """)

    :ok = Exqlite.Sqlite3.execute(conn, """
    CREATE TABLE IF NOT EXISTS thread_refs (
      ref TEXT PRIMARY KEY,
      thread_id TEXT NOT NULL REFERENCES threads(id)
    )
    """)

    :ok = Exqlite.Sqlite3.execute(conn, """
    CREATE INDEX IF NOT EXISTS idx_thread_refs_thread_id ON thread_refs(thread_id)
    """)
  end

  defp exec(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    :done = Exqlite.Sqlite3.step(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)
    :ok
  end

  defp query_one(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)

    result =
      case Exqlite.Sqlite3.step(conn, stmt) do
        {:row, row} -> {:ok, row}
        :done -> :none
      end

    :ok = Exqlite.Sqlite3.release(conn, stmt)
    result
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
