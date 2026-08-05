defmodule Jido.Assembly.Pages.Assembly do
  use Hologram.Page

  alias Hologram.JS

  alias Jido.Assembly.Components.Assembly.{
    ChatPanel,
    DeveloperInspectorPanel,
    Rail,
    Sidebar,
    ThreadPanel
  }

  alias Jido.Assembly.{Agents, Chat}
  alias Jido.Assembly.Layouts.App
  alias Jido.Assembly.Pages.Assembly.{Commands, State}

  @initial_presence_delay_ms 250
  @presence_heartbeat_ms Jido.Assembly.Presence.heartbeat_interval_ms()

  route "/"

  layout App

  def init(_params, component, server) do
    component =
      component
      |> State.apply_snapshot(Chat.snapshot())
      |> put_state(State.initial_ui_state())
      |> put_state(:agent_demo, Agents.snapshot())
      |> schedule_presence_heartbeat(@initial_presence_delay_ms)

    server = put_subscription(server, {:workspace, Chat.workspace_id()})

    {component, server}
  end

  def action(:select_room, params, component) do
    component
    |> State.select_room(params.id)
    |> queue_presence_touch()
  end

  def action(:rail_workspace, _params, component) do
    focus_rail_target(:workspace)

    component
    |> State.select_room(Chat.default_room_id())
    |> queue_presence_touch()
  end

  def action(:rail_channels, _params, component) do
    focus_rail_target(:channels)

    component
    |> put_state(:rail_target, "channels")
    |> State.select_first_room(component.state.channels)
    |> queue_presence_touch()
  end

  def action(:rail_direct_messages, _params, component) do
    focus_rail_target(:direct_messages)

    component
    |> put_state(:rail_target, "direct_messages")
    |> State.select_first_room(component.state.direct_messages)
    |> queue_presence_touch()
  end

  def action(:rail_search, _params, component) do
    focus_rail_target(:search)
    put_state(component, :rail_target, "search")
  end

  def action(:rail_users, _params, component) do
    focus_rail_target(:users)
    put_state(component, :rail_target, "users")
  end

  def action(:select_user, params, component) do
    put_command(component, :load_snapshot,
      user_id: params.id,
      active_room_id: component.state.active_room_id
    )
  end

  def action(:snapshot_loaded, params, component) do
    component
    |> State.apply_snapshot(params.snapshot)
    |> put_state(:thread_open, false)
    |> put_state(:thread_root, nil)
    |> put_state(:thread_messages, [])
    |> queue_presence_touch()
    |> schedule_presence_heartbeat()
  end

  def action(:presence_heartbeat, _params, component) do
    component
    |> queue_presence_touch()
    |> schedule_presence_heartbeat()
  end

  def action(:presence_changed, params, component) do
    signal = map_value(params, :signal, nil)

    if signal do
      component
      |> State.put_active_developer_context(
        State.developer_event(
          "Presence synced",
          "Phoenix Presence + Jido Signal",
          signal_detail(params, presence_detail(component))
        )
      )
      |> queue_snapshot_load()
    else
      component
    end
  end

  def action(:draft_changed, params, component) do
    put_state(component, :draft, event_value(params))
  end

  def action(:send_message, params, component) do
    draft = params |> submitted_form_value(:body, component.state.draft) |> String.trim()

    if draft == "" do
      put_state(component, :error, "Type a message first.")
    else
      component
      |> put_state(:draft, "")
      |> put_state(:send_pending, true)
      |> put_state(:error, nil)
      |> put_command(:persist_message,
        room_id: component.state.active_room_id,
        body: draft,
        sender_id: component.state.current_user.id
      )
    end
  end

  def action(:agent_safety_changed, params, component) do
    put_state(component, :agent_safety_enabled, event_checked(params))
  end

  def action(:agent_inter_agent_changed, params, component) do
    put_state(component, :agent_inter_agent_enabled, event_checked(params))
  end

  def action(:agent_prompt_changed, params, component) do
    put_state(component, :agent_prompt_draft, event_value(params))
  end

  def action(:run_agent_round, _params, component) do
    cond do
      !component.state.agent_safety_enabled ->
        put_state(component, :agent_error, Agents.error_to_string(:safety_required))

      true ->
        component
        |> put_state(:agent_round_pending, true)
        |> put_state(:agent_error, nil)
        |> put_command(:run_agent_round,
          room_id: component.state.active_room_id,
          safety_enabled: component.state.agent_safety_enabled,
          inter_agent_enabled: component.state.agent_inter_agent_enabled
        )
    end
  end

  def action(:prompt_agent_round, params, component) do
    prompt =
      params
      |> submitted_form_value(:agent_prompt, component.state.agent_prompt_draft)
      |> String.trim()

    cond do
      prompt == "" ->
        put_state(component, :agent_error, "Ask a question first.")

      !component.state.agent_safety_enabled ->
        put_state(component, :agent_error, Agents.error_to_string(:safety_required))

      true ->
        component
        |> put_state(:agent_prompt_draft, "")
        |> put_state(:agent_round_pending, true)
        |> put_state(:agent_error, nil)
        |> put_command(:prompt_agent_round,
          room_id: component.state.active_room_id,
          body: prompt,
          sender_id: component.state.current_user.id,
          safety_enabled: component.state.agent_safety_enabled,
          inter_agent_enabled: component.state.agent_inter_agent_enabled
        )
    end
  end

  def action(:reply_draft_changed, params, component) do
    put_state(component, :reply_draft, event_value(params))
  end

  def action(:send_reply, params, component) do
    draft = params |> submitted_form_value(:reply, component.state.reply_draft) |> String.trim()

    cond do
      !component.state.thread_root ->
        put_state(component, :reply_error, "Open a thread first.")

      draft == "" ->
        put_state(component, :reply_error, "Type a reply first.")

      true ->
        component
        |> put_state(:reply_draft, "")
        |> put_state(:reply_pending, true)
        |> put_state(:reply_error, nil)
        |> put_command(:persist_reply,
          room_id: component.state.active_room_id,
          root_message_id: component.state.thread_root.id,
          body: draft,
          sender_id: component.state.current_user.id
        )
    end
  end

  def action(:message_saved, params, component) do
    message = State.personalize_message(params.message, component.state.current_user.id)
    room_id = message.room_id

    component =
      if Map.get(message, :is_reply, false) do
        State.put_thread_reply(component, room_id, message)
      else
        State.put_timeline_message(component, room_id, message)
      end

    rooms =
      State.touch_room(
        component.state.rooms,
        room_id,
        component.state.active_room_id,
        message.own,
        message.mentions_current_user
      )

    component
    |> State.put_rooms(rooms)
    |> put_state(
      :connector_snapshot,
      map_value(params, :connector_snapshot, component.state.connector_snapshot)
    )
    |> put_state(:send_pending, false)
    |> put_state(:reply_pending, false)
    |> put_state(:error, nil)
    |> put_state(:reply_error, nil)
    |> State.put_active_developer_context(
      State.developer_event(
        if(Map.get(message, :is_reply, false), do: "Reply stored", else: "Message stored"),
        "Jido Signal",
        signal_detail(params, "#{message.author} in #{State.room_label(component, room_id)}")
      )
    )
  end

  def action(:send_failed, params, component) do
    component
    |> put_state(:send_pending, false)
    |> put_state(:reply_pending, false)
    |> put_state(:error, params.error)
  end

  def action(:toggle_reaction, params, component) do
    put_command(component, :persist_reaction,
      message_id: params.message_id,
      emoji: params.emoji,
      user_id: component.state.current_user.id
    )
  end

  def action(:reaction_saved, params, component) do
    message = State.personalize_message(params.message, component.state.current_user.id)

    component
    |> State.update_message_everywhere(message)
    |> State.put_active_developer_context(
      State.developer_event(
        "Reaction stored",
        "Jido Signal",
        signal_detail(
          params,
          "#{message.author} in #{State.room_label(component, message.room_id)}"
        )
      )
    )
  end

  def action(:open_thread, params, component) do
    root = Enum.find(component.state.messages, &(&1.id == params.message_id))
    thread_messages = State.get_thread_messages(component, root && root.id)

    component
    |> put_state(:thread_open, true)
    |> put_state(:thread_root, root)
    |> put_state(:thread_messages, thread_messages)
    |> put_state(:reply_draft, "")
    |> put_state(:reply_error, nil)
    |> State.put_active_developer_context(
      State.developer_event(
        "Thread opened",
        "Hologram action",
        if(root, do: root.author, else: "missing message")
      )
    )
  end

  def action(:close_thread, _params, component) do
    component
    |> put_state(:thread_open, false)
    |> put_state(:thread_root, nil)
    |> put_state(:thread_messages, [])
    |> put_state(:reply_draft, "")
    |> put_state(:reply_error, nil)
    |> State.put_active_developer_context(
      State.developer_event(
        "Thread closed",
        "Hologram action",
        component.state.active_room_name
      )
    )
  end

  def action(:search_changed, params, component) do
    query = event_value(params)

    component =
      component
      |> put_state(:search_query, query)
      |> put_state(:search_results, [])

    if String.trim(query) == "" do
      component
    else
      put_command(component, :run_search,
        query: query,
        user_id: component.state.current_user.id
      )
    end
  end

  def action(:search_loaded, params, component) do
    put_state(component, :search_results, params.results)
  end

  def action(:select_search_result, params, component) do
    component = State.select_room(component, params.room_id)

    if params.thread_id do
      component =
        component
        |> put_state(:search_query, "")
        |> put_state(:search_results, [])

      action(:open_thread, %{message_id: params.thread_id}, component)
    else
      component
      |> put_state(:search_query, "")
      |> put_state(:search_results, [])
    end
  end

  def action(:toggle_room_form, _params, component) do
    put_state(component, :room_form_open, !component.state.room_form_open)
  end

  def action(:new_room_name_changed, params, component) do
    put_state(component, :new_room_name, event_value(params))
  end

  def action(:new_room_topic_changed, params, component) do
    put_state(component, :new_room_topic, event_value(params))
  end

  def action(:create_channel, _params, component) do
    name = String.trim(component.state.new_room_name)

    if name == "" do
      put_state(component, :new_room_error, "Name the group chat first.")
    else
      component
      |> put_state(:new_room_pending, true)
      |> put_state(:new_room_error, nil)
      |> put_command(:persist_channel,
        name: name,
        topic: component.state.new_room_topic
      )
    end
  end

  def action(:room_created, params, component) do
    room = params.room

    messages =
      Enum.map(
        params.messages || [],
        &State.personalize_message(&1, component.state.current_user.id)
      )

    rooms = State.upsert_room(component.state.rooms, room)
    messages_by_room = Map.put(component.state.messages_by_room, room.id, messages)
    threads_by_room = Map.put(component.state.threads_by_room, room.id, %{})

    contracts_by_room =
      Map.put(
        component.state.developer_contract_by_room,
        room.id,
        State.chat_contract(room)
      )

    component
    |> State.put_rooms(rooms)
    |> put_state(:messages_by_room, messages_by_room)
    |> put_state(:threads_by_room, threads_by_room)
    |> put_state(:developer_contract_by_room, contracts_by_room)
    |> put_state(:room_form_open, false)
    |> put_state(:new_room_name, "")
    |> put_state(:new_room_topic, "")
    |> put_state(:new_room_pending, false)
    |> put_state(:new_room_error, nil)
    |> State.put_active_developer_context(
      State.developer_event(
        "Room created",
        "Jido Signal",
        signal_detail(params, "#{room.prefix}#{room.name}")
      )
    )
  end

  def action(:room_create_failed, params, component) do
    component
    |> put_state(:new_room_pending, false)
    |> put_state(:new_room_error, params.error)
  end

  def action(:agent_round_finished, params, component) do
    messages =
      Enum.map(
        params.messages || [],
        &State.personalize_message(&1, component.state.current_user.id)
      )

    component =
      Enum.reduce(messages, component, fn message, acc ->
        acc = State.put_timeline_message(acc, message.room_id, message)

        rooms =
          State.touch_room(
            acc.state.rooms,
            message.room_id,
            acc.state.active_room_id,
            message.own,
            message.mentions_current_user
          )

        State.put_rooms(acc, rooms)
      end)

    component
    |> put_state(:agent_round_pending, false)
    |> put_state(:agent_error, nil)
    |> put_state(:agent_demo, map_value(params, :agent_demo, component.state.agent_demo))
    |> State.put_active_developer_context(
      State.developer_event(
        "Agent round stored",
        "Jido AI + Jido Messaging",
        signal_detail(params, "#{Enum.count(messages)} agent messages")
      )
    )
  end

  def action(:agent_round_failed, params, component) do
    component
    |> put_state(:agent_round_pending, false)
    |> put_state(:agent_error, params.error)
    |> put_state(:agent_demo, map_value(params, :agent_demo, component.state.agent_demo))
  end

  def command(name, params, server), do: Commands.command(name, params, server)

  def template do
    ~HOLO"""
    <main class="h-screen min-h-[680px] bg-[var(--assembly-bg)] text-[var(--assembly-ink)]">
      <div class="grid h-full grid-cols-[minmax(0,1fr)] overflow-hidden md:grid-cols-[72px_292px_minmax(0,1fr)] xl:grid-cols-[72px_292px_minmax(0,1fr)_360px]">
        <Rail current_user={@current_user} rail_target={@rail_target} />
        <Sidebar
          active_room_id={@active_room_id}
          channels={@channels}
          current_user={@current_user}
          demo_users={@demo_users}
          direct_messages={@direct_messages}
          new_room_error={@new_room_error}
          new_room_name={@new_room_name}
          new_room_pending={@new_room_pending}
          new_room_topic={@new_room_topic}
          rail_target={@rail_target}
          room_form_open={@room_form_open}
          search_query={@search_query}
          search_results={@search_results}
          connector_snapshot={@connector_snapshot}
          workspace={@workspace}
        />
        <ChatPanel
          active_room_id={@active_room_id}
          active_room_name={@active_room_name}
          active_room_prefix={@active_room_prefix}
          active_topic={@active_topic}
          agent_demo={@agent_demo}
          agent_error={@agent_error}
          agent_inter_agent_enabled={@agent_inter_agent_enabled}
          agent_prompt_draft={@agent_prompt_draft}
          agent_round_pending={@agent_round_pending}
          agent_safety_enabled={@agent_safety_enabled}
          connector_snapshot={@connector_snapshot}
          current_user={@current_user}
          draft={@draft}
          error={@error}
          member_count_label={@member_count_label}
          messages={@messages}
          rooms={@rooms}
          send_pending={@send_pending}
          workspace={@workspace}
        />
        <ThreadPanel
          active_room_name={@active_room_name}
          active_room_prefix={@active_room_prefix}
          reply_draft={@reply_draft}
          reply_error={@reply_error}
          reply_pending={@reply_pending}
          thread_messages={@thread_messages}
          thread_open={@thread_open}
          thread_root={@thread_root}
        />
        <DeveloperInspectorPanel
          active_room_name={@active_room_name}
          active_room_prefix={@active_room_prefix}
          developer_capabilities={@developer_capabilities}
          developer_contract={@developer_contract}
          developer_message_inspector={@developer_message_inspector}
          developer_room_metrics={@developer_room_metrics}
          developer_stack={@developer_stack}
          connector_snapshot={@connector_snapshot}
          last_event={@last_event}
          thread_open={@thread_open}
        />
      </div>
    </main>
    """
  end

  defp event_value(%{event: %{value: value}}), do: value
  defp event_value(%{value: value}), do: value
  defp event_value(%{"event" => %{"value" => value}}), do: value
  defp event_value(%{"value" => value}), do: value
  defp event_value(_params), do: ""

  defp event_checked(%{event: %{checked: checked}}), do: truthy?(checked)
  defp event_checked(%{checked: checked}), do: truthy?(checked)
  defp event_checked(%{"event" => %{"checked" => checked}}), do: truthy?(checked)
  defp event_checked(%{"checked" => checked}), do: truthy?(checked)
  defp event_checked(params), do: truthy?(event_value(params))

  defp truthy?(value) when value in [true, "true", "on", "1", 1], do: true
  defp truthy?(_value), do: false

  defp submitted_form_value(params, key, fallback) do
    case form_value(params, key) do
      nil -> fallback
      value -> value
    end
  end

  defp form_value(params, key) when is_map(params) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp form_value(_params, _key), do: nil

  defp queue_presence_touch(component) do
    current_user = Map.get(component.state, :current_user, %{})
    user_id = Map.get(current_user, :id)
    room_id = Map.get(component.state, :active_room_id)

    if user_id && room_id do
      put_command(component, :touch_presence, user_id: user_id, room_id: room_id)
    else
      component
    end
  end

  defp queue_snapshot_load(component) do
    current_user = Map.get(component.state, :current_user, %{})
    user_id = Map.get(current_user, :id)
    room_id = Map.get(component.state, :active_room_id)

    if user_id && room_id do
      put_command(component, :load_snapshot, user_id: user_id, active_room_id: room_id)
    else
      component
    end
  end

  defp schedule_presence_heartbeat(component, delay \\ @presence_heartbeat_ms) do
    put_action(component, name: :presence_heartbeat, delay: delay)
  end

  defp presence_detail(component) do
    online_count =
      component.state
      |> Map.get(:presence, %{})
      |> map_value(:online_user_ids, [])
      |> Enum.count()

    "#{online_count} online"
  end

  defp signal_detail(%{signal: %{type: type}}, fallback), do: "#{type} | #{fallback}"
  defp signal_detail(%{"signal" => %{"type" => type}}, fallback), do: "#{type} | #{fallback}"
  defp signal_detail(_params, fallback), do: fallback

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_value(_map, _key, default), do: default

  defp focus_rail_target(:workspace) do
    JS.exec("""
    document.getElementById("assembly-workspace-heading")?.scrollIntoView({ block: "nearest" });
    """)
  end

  defp focus_rail_target(:channels) do
    JS.exec("""
    const target = document.getElementById("assembly-channels-section");
    target?.scrollIntoView({ block: "nearest" });
    target?.focus({ preventScroll: true });
    """)
  end

  defp focus_rail_target(:direct_messages) do
    JS.exec("""
    const target = document.getElementById("assembly-direct-messages-section");
    target?.scrollIntoView({ block: "nearest" });
    target?.focus({ preventScroll: true });
    """)
  end

  defp focus_rail_target(:search) do
    JS.exec("""
    const target = document.getElementById("assembly-search-input");
    target?.scrollIntoView({ block: "nearest" });
    target?.focus();
    """)
  end

  defp focus_rail_target(:users) do
    JS.exec("""
    const target = document.getElementById("assembly-demo-users");
    target?.scrollIntoView({ block: "nearest" });
    target?.focus({ preventScroll: true });
    """)
  end
end
