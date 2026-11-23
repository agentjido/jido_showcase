defmodule Jido.Assembly.Pages.Assembly do
  use Hologram.Page

  alias Hologram.JS

  alias Jido.Assembly.Components.Assembly.{
    ChatPanel,
    DeveloperInspectorPanel,
    ReleaseWork,
    RunDetails,
    Sidebar
  }

  alias Jido.Assembly.{Agents, Chat, Pilot}
  alias Jido.Assembly.Layouts.App
  alias Jido.Assembly.Pages.Assembly.{Commands, State}

  @initial_presence_delay_ms 250
  @presence_heartbeat_ms Jido.Assembly.Presence.heartbeat_interval_ms()

  route "/"

  layout App

  def init(_params, component, server) do
    room_id = Map.get(server.query, "room", Chat.default_room_id())
    user_id = Commands.viewer_id(server)
    snapshot = Chat.snapshot(user_id, room_id)

    component =
      component
      |> State.apply_snapshot(snapshot)
      |> put_state(State.initial_ui_state())
      |> put_state(:pilot, Pilot.enabled?())
      |> put_state(:show_agents, not Pilot.enabled?() or Pilot.agents_enabled?())
      |> put_state(:agent_demo, Agents.snapshot())
      |> open_permalink(room_id, Map.get(server.query, "message"), user_id)
      |> schedule_presence_heartbeat(@initial_presence_delay_ms)

    server =
      server
      |> put_subscription({:workspace, Chat.workspace_id()})
      |> Commands.subscribe_direct_rooms(snapshot)

    {component, server}
  end

  def action(:select_room, params, component) do
    component
    |> State.select_room(params.id)
    |> queue_room_history_load()
  end

  def action(:room_history_loaded, params, component) do
    if params.room_id == component.state.active_room_id and
         params.user_id == component.state.current_user.id do
      component
      |> State.load_history_page(params.page, params.requested_before)
      |> State.merge_linked_history(params.linked)
      |> apply_release_work(params)
      |> open_focused_thread()
      |> queue_presence_touch()
    else
      component
    end
  end

  def action(:load_older_history, _params, component) do
    before = Map.get(component.state.history_cursors, component.state.active_room_id)
    if before, do: queue_room_history_load(component, before), else: component
  end

  def action(:room_access_denied, _params, component) do
    put_state(component, :error, "You do not have access to this room.")
  end

  def action(:rail_workspace, _params, component) do
    focus_rail_target(:workspace)

    component
    |> State.select_room(Chat.default_room_id())
    |> queue_room_history_load()
  end

  def action(:rail_channels, _params, component) do
    focus_rail_target(:channels)

    component
    |> put_state(:rail_target, "channels")
    |> State.select_first_room(component.state.channels)
    |> queue_room_history_load()
  end

  def action(:rail_direct_messages, _params, component) do
    focus_rail_target(:direct_messages)

    component
    |> put_state(:rail_target, "direct_messages")
    |> State.select_first_room(component.state.direct_messages)
    |> queue_room_history_load()
  end

  def action(:rail_search, _params, component) do
    focus_rail_target(:search)
    put_state(component, :rail_target, "search")
  end

  def action(:rail_users, _params, component) do
    focus_rail_target(:users)
    put_state(component, :rail_target, "users")
  end

  def action(:show_workspace_view, %{view: view}, component) do
    JS.exec(
      "requestAnimationFrame(() => document.getElementById('assembly-view-heading')?.focus());"
    )

    put_state(component, :workspace_view, view)
  end

  def action(:select_viewer, params, component) do
    action(:select_user, %{id: event_value(params)}, component)
  end

  def action(:mention_triage, _params, component) do
    draft = component.state.draft
    separator = if draft == "" or String.ends_with?(draft, " "), do: "", else: " "

    JS.exec("""
    requestAnimationFrame(() => {
      const input = document.querySelector('[data-assembly-composer="message"] input');
      input?.focus();
      input?.setSelectionRange(input.value.length, input.value.length);
    });
    """)

    put_state(component, :draft, draft <> separator <> "@triage ")
  end

  def action(:select_user, params, component) do
    component
    |> put_state(:mobile_panel, "")
    |> put_command(:switch_demo_user,
      id: params.id,
      active_room_id: component.state.active_room_id
    )
  end

  def action(:open_mobile_panel, params, component) do
    panel = if params.panel == "inspector", do: "inspector", else: "workspace"

    JS.exec(
      "requestAnimationFrame(() => document.getElementById('assembly-mobile-panel')?.focus());"
    )

    put_state(component, :mobile_panel, panel)
  end

  def action(:close_mobile_panel, _params, component) do
    focus_mobile_trigger(component.state.mobile_panel)
    put_state(component, :mobile_panel, "")
  end

  def action(:snapshot_loaded, params, component) do
    component
    |> refresh_snapshot(params.snapshot)
    |> put_state(:mobile_panel, "")
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
    draft = submitted_form_value(params, :body, component.state.draft)
    body = String.trim(draft)

    cond do
      component.state.send_pending ->
        component

      body == "" ->
        put_state(component, :error, "Type a message first.")

      true ->
        component = begin_submission(component, :message, draft)

        put_command(component, :persist_message,
          room_id: component.state.active_room_id,
          body: body,
          sender_id: component.state.current_user.id,
          submission_id: component.state.submission_id
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
    draft = submitted_form_value(params, :reply, component.state.reply_draft)
    body = String.trim(draft)

    cond do
      component.state.reply_pending ->
        component

      !component.state.thread_root ->
        put_state(component, :reply_error, "Open a thread first.")

      body == "" ->
        put_state(component, :reply_error, "Type a reply first.")

      true ->
        component = begin_submission(component, :reply, draft)

        put_command(component, :persist_reply,
          room_id: component.state.active_room_id,
          root_message_id: component.state.thread_root.id,
          body: body,
          sender_id: component.state.current_user.id,
          submission_id: component.state.submission_id
        )
    end
  end

  def action(:message_saved, params, component) do
    message = State.personalize_message(params.message, component.state.current_user.id)
    room_id = message.room_id

    rooms =
      if State.message_present?(component, message) do
        component.state.rooms
      else
        State.touch_room(
          component.state.rooms,
          room_id,
          component.state.active_room_id,
          message.own,
          message.mentions_current_user
        )
      end

    component
    |> State.update_message_everywhere(message)
    |> State.put_rooms(rooms)
    |> put_state(
      :connector_snapshot,
      map_value(params, :connector_snapshot, component.state.connector_snapshot)
    )
    |> finish_submission(params, :ok)
    |> State.put_active_developer_context(
      State.developer_event(
        if(Map.get(message, :is_reply, false), do: "Reply stored", else: "Message stored"),
        "Jido Signal",
        signal_detail(params, "#{message.author} in #{State.room_label(component, room_id)}")
      )
    )
    |> refresh_release_work(message)
  end

  def action(:send_failed, %{submission_id: _id, error: error} = params, component),
    do: finish_submission(component, params, {:error, error})

  def action(:send_failed, params, component), do: put_state(component, :error, params.error)

  def action(:release_work_loaded, params, component) do
    if params.user_id == component.state.current_user.id,
      do: State.put_release_work(component, params.user_id, params.work),
      else: component
  end

  def action(:answer_release_decision, params, component) do
    queue_release_action(component, "decide", params.target, %{choice: params.choice})
  end

  def action(:revise_release_artifact, params, component) do
    target = submitted_form_value(params, :target, "")
    body = submitted_form_value(params, :revision, "")
    queue_release_action(component, "revise", target, %{body: body})
  end

  def action(:approve_release_artifact, params, component) do
    queue_release_action(component, "review", params.target, %{})
  end

  def action(:propose_release_publication, params, component) do
    queue_release_action(component, "propose_publish", params.target, %{})
  end

  def action(:approve_release_publication, params, component) do
    queue_release_action(component, "approve_publish", params.target, %{})
  end

  def action(:revoke_release_publication, params, component) do
    queue_release_action(component, "revoke_publish", params.target, %{})
  end

  def action(:cancel_release_run, params, component) do
    queue_release_action(component, "cancel_release", params.target, %{})
  end

  def action(:release_action_failed, params, component) do
    component = put_state(component, :release_error, params.error)

    if Map.get(params, :refresh),
      do: queue_room_history_load(component, nil, refresh_release_work: true),
      else: component
  end

  def action(:set_reaction, params, component) do
    put_command(component, :persist_reaction,
      message_id: params.message_id,
      emoji: params.emoji,
      active: params.active
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

  def action(action, %{message: message}, component)
      when action in [:bridge_delivery_saved, :agent_run_saved] do
    message = State.personalize_message(message, component.state.current_user.id)
    State.update_message_everywhere(component, message)
  end

  def action(:open_thread, params, component) do
    root = Enum.find(component.state.messages, &(&1.id == params.message_id))
    thread_messages = State.get_thread_messages(component, root && root.id)

    component
    |> put_state(:thread_open, not is_nil(root))
    |> put_state(:thread_root, root)
    |> put_state(:thread_messages, thread_messages)
    |> put_state(:focused_message_id, nil)
    |> reset_reply_if_changed(component.state.thread_root, root)
    |> put_state(:release_error, nil)
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
    |> put_state(:focused_message_id, nil)
    |> State.reset_reply()
    |> put_state(:release_error, nil)
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
      |> put_state(:focused_message_id, nil)

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
    component =
      component
      |> State.select_room(params.room_id)
      |> put_state(:search_query, "")
      |> put_state(:search_results, [])

    if component.state.active_room_id == params.room_id do
      component
      |> put_state(:focused_message_id, params.message_id)
      |> open_focused_thread()
      |> queue_room_history_load()
    else
      action(:room_access_denied, %{}, component)
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
    |> put_state(:mobile_panel, "")
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
        "Jido AI + Jido Chat",
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
    <div class="assembly-app">
      <header class="assembly-topbar">
        <button type="button" class="assembly-brand" $click={:show_workspace_view, view: "threads"}>
          <span class="assembly-mark" aria-hidden="true"><i></i><i></i><i></i><i></i></span>
          Assembly
        </button>
        <div class="assembly-top-tools">
          {%if !@pilot}<span class="assembly-demo-label">{@connector_snapshot.headline}</span>{/if}
          {%if @pilot}
            <span data-assembly-viewer={@current_user.id}>{@current_user.name}</span>
            <a class="assembly-sign-out" href="/sign-out">Sign out</a>
          {%else}
            <label class="assembly-viewer">
              <span>View as</span>
              <select aria-label="View as" id="assembly-demo-users" data-assembly-viewer={@current_user.id} $change="select_viewer">
                {%for user <- @demo_users}
                  <option value={user.id} selected={user.id == @current_user.id}>{user.name}</option>
                {/for}
              </select>
            </label>
          {/if}
          <button type="button" class="assembly-inspector-trigger" id="assembly-mobile-inspector-trigger" aria-label="Open developer inspector" title="Developer inspector" $click={:open_mobile_panel, panel: "inspector"}>
            <span class="hero-command-line size-4"></span>
          </button>
        </div>
      </header>
      <div class="assembly-shell">
        <Sidebar
          active_room_id={@active_room_id}
          channels={@channels}
          direct_messages={@direct_messages}
          new_room_error={@new_room_error}
          new_room_name={@new_room_name}
          new_room_pending={@new_room_pending}
          new_room_topic={@new_room_topic}
          pilot={@pilot}
          release_work={@release_work}
          room_form_open={@room_form_open}
          search_query={@search_query}
          search_results={@search_results}
          workspace={@workspace}
          workspace_view={@workspace_view}
        />
        <main class="assembly-main">
          {%if @workspace_view == "chat"}
            <header class="assembly-channel-head">
              <h1><span aria-hidden="true" class="assembly-muted">{@active_room_prefix}</span> {@active_room_name}</h1>
              {%if @show_agents}<a class="assembly-text-link" href="#assembly-run-details">Run details</a>{/if}
            </header>
            <div class="assembly-conversation-grid" data-show-agents={if @show_agents do "true" else "false" end}>
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
                current_user={@current_user}
                draft={@draft}
                error={@error}
                focused_message_id={@focused_message_id}
                history_before={Map.get(@history_cursors, @active_room_id)}
                messages={@messages}
                pilot={@pilot}
                send_pending={!is_nil(@send_pending)}
                show_agents={@show_agents}
                thread_root={@thread_root}
                thread_messages={@thread_messages}
                reply_draft={@reply_draft}
                reply_error={@reply_error}
                reply_pending={!is_nil(@reply_pending)}
                release_error={@release_error}
              />
              {%if @show_agents}<RunDetails room_name={@active_room_name} room_prefix={@active_room_prefix} root={@thread_root} replies={@thread_messages} />{/if}
            </div>
          {%else}
            <ReleaseWork work={@release_work} view={@workspace_view} channels={@channels} />
          {/if}
        </main>
      </div>
      {%if @mobile_panel == "inspector"}
        <div class="assembly-overlay">
          <button type="button" class="assembly-overlay-backdrop" aria-label="Close inspector" tabindex="-1" $click="close_mobile_panel"></button>
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
            presence={@presence}
          />
        </div>
      {/if}
    </div>
    """
  end

  defp queue_release_action(component, operation, target, params) do
    case component.state.thread_root do
      %{id: root_id} ->
        attrs = Map.merge(params, %{operation: operation, root: root_id, target: target})

        component
        |> put_state(:release_error, nil)
        |> put_command(:submit_release_action, attrs)

      nil ->
        component
    end
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
    value = form_value(params, key) || form_value(form_value(params, :event), key)

    case value do
      nil -> fallback
      value -> value
    end
  end

  defp form_value(params, key) when is_map(params) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp form_value(_params, _key), do: nil

  defp begin_submission(component, composer, draft) do
    {draft_key, pending_key, error_key} = composer_keys(composer)
    id = component.state.submission_id + 1

    component
    |> put_state(:submission_id, id)
    |> put_state(draft_key, draft)
    |> put_state(pending_key, %{id: id, draft: draft})
    |> put_state(error_key, nil)
  end

  defp finish_submission(component, %{composer: composer, submission_id: id}, result) do
    {draft_key, pending_key, error_key} = composer_keys(composer)

    case Map.get(component.state, pending_key) do
      %{id: ^id, draft: draft} ->
        component = put_state(component, pending_key, nil)

        case result do
          :ok ->
            if Map.get(component.state, draft_key) == draft,
              do: put_state(component, draft_key, ""),
              else: component

          {:error, error} ->
            put_state(component, error_key, error)
        end

      _other ->
        component
    end
  end

  defp finish_submission(component, _params, _result), do: component

  defp composer_keys(:message), do: {:draft, :send_pending, :error}
  defp composer_keys(:reply), do: {:reply_draft, :reply_pending, :reply_error}

  defp reset_reply_if_changed(component, %{id: id}, %{id: id}), do: component
  defp reset_reply_if_changed(component, _previous, _next), do: State.reset_reply(component)

  defp refresh_release_work(component, %{metadata: %{"assembly_release_note" => _event}}) do
    if component.state.release_work,
      do: put_command(component, :load_release_work, []),
      else: component
  end

  defp refresh_release_work(component, _message), do: component

  defp apply_release_work(component, %{user_id: user_id, release_work: work}),
    do: State.put_release_work(component, user_id, work)

  defp apply_release_work(component, _params), do: component

  defp open_permalink(component, _room_id, nil, _user_id), do: component

  defp open_permalink(component, room_id, message_id, user_id) do
    with true <- component.state.active_room_id == room_id,
         {:ok, _history} = linked <- Chat.linked_history(room_id, message_id, user_id) do
      component
      |> State.merge_linked_history(linked)
      |> put_state(:focused_message_id, message_id)
      |> open_focused_thread()
    else
      _error -> put_state(component, :error, "This message is unavailable.")
    end
  end

  defp open_focused_thread(%{state: %{focused_message_id: nil}} = component), do: component
  defp open_focused_thread(%{state: %{thread_open: true}} = component), do: component

  defp open_focused_thread(component) do
    state = component.state
    message_id = state.focused_message_id
    threads = Map.get(state.threads_by_room, state.active_room_id, %{})

    case Enum.find(threads, fn {_root, replies} -> Enum.any?(replies, &(&1.id == message_id)) end) do
      {root, _replies} ->
        component
        |> then(&action(:open_thread, %{message_id: root}, &1))
        |> put_state(:focused_message_id, message_id)

      nil ->
        component
    end
  end

  defp refresh_snapshot(component, snapshot) do
    state = component.state
    refreshed = State.apply_snapshot(component, snapshot)

    if state.current_user.id == snapshot.current_user.id and
         state.active_room_id == snapshot.active_room_id do
      room_id = state.active_room_id
      cached_threads = Map.get(state.threads_by_room, room_id, %{})
      refreshed_threads = Map.get(snapshot.threads_by_room, room_id, %{})
      cursors = Map.merge(snapshot.history_cursors, Map.take(state.history_cursors, [room_id]))

      refreshed
      |> put_state(:messages, state.messages)
      |> put_state(:threads_by_room, Map.put(snapshot.threads_by_room, room_id, cached_threads))
      |> put_state(:history_cursors, cursors)
      |> State.merge_room_history(snapshot.messages, refreshed_threads)
    else
      refreshed
      |> State.reset_composers()
      |> put_state(:thread_open, false)
      |> put_state(:thread_root, nil)
      |> put_state(:thread_messages, [])
      |> put_state(:focused_message_id, nil)
    end
  end

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

  defp queue_room_history_load(component, before \\ nil, extra \\ []) do
    params = [
      room_id: component.state.active_room_id,
      before: before,
      focused_message_id: component.state.focused_message_id
    ]

    put_command(component, :load_room_history, params ++ extra)
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

  defp focus_mobile_trigger("inspector") do
    JS.exec("document.getElementById('assembly-mobile-inspector-trigger')?.focus();")
  end

  defp focus_mobile_trigger(_panel) do
    JS.exec("document.getElementById('assembly-mobile-workspace-trigger')?.focus();")
  end
end
