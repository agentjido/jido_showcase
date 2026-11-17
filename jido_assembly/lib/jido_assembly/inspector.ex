defmodule Jido.Assembly.Inspector do
  @moduledoc """
  Read model for the Assembly developer inspector.

  This is intentionally outside the chat domain. It explains which Jido layer the
  demo is exercising without leaking UI commentary into command handlers.
  """

  alias Jido.Chat.Post

  @workspace_id "jido"

  @stack [
    %{
      name: "Hologram",
      badge: "UI",
      role: "Client actions, server commands, and realtime broadcasts."
    },
    %{
      name: "Jido Chat Runtime",
      badge: "runtime",
      role: "Managed Rooms, provider accounts, bindings, history, and reactions."
    },
    %{
      name: "Jido Signal",
      badge: "events",
      role: "CloudEvents-compatible jido.chat.* commands and committed facts."
    },
    %{
      name: "SQLite",
      badge: "durable",
      role: "Small local persistence adapter backing the demo process."
    },
    %{
      name: "Jido Chat Adapters",
      badge: "contract",
      role: "Typed adapter contracts for Telegram, Discord, and future providers."
    },
    %{
      name: "Jido",
      badge: "agents",
      role: "Native ops agents participate as room members when an LLM key is present."
    }
  ]

  @capabilities [
    %{feature: "Channels", status: "implemented", detail: "Durable Jido Chat Room records."},
    %{feature: "DMs", status: "implemented", detail: "Direct rooms with demo participants."},
    %{feature: "Threads", status: "implemented", detail: "Root message plus reply records."},
    %{feature: "Reactions", status: "implemented", detail: "Stored on message reaction maps."},
    %{feature: "Search", status: "implemented", detail: "Simple workspace scan for the demo."},
    %{
      feature: "Signals",
      status: "implemented",
      detail: "Write commands expose committed Jido Signal CloudEvent metadata."
    },
    %{feature: "Telegram bridge", status: "optional", detail: "Live when env vars are present."},
    %{feature: "Discord bridge", status: "optional", detail: "Live when env vars are present."},
    %{
      feature: "Workflow cards",
      status: "implemented",
      detail: "Structured metadata on normal messages."
    },
    %{
      feature: "Jido agents",
      status: "implemented",
      detail: "Ops agents require ANTHROPIC_API_KEY for live actions."
    }
  ]

  def snapshot(active_room, messages, threads_by_root, rooms) do
    %{
      stack: @stack,
      capabilities: @capabilities,
      contracts_by_room: Map.new(rooms, &{&1.id, chat_contract(&1)}),
      chat_contract: chat_contract(active_room),
      message_inspector: message_inspector(List.last(messages)),
      room_metrics: room_metrics(active_room, length(messages), map_size(threads_by_root || %{})),
      last_event: %{
        title: "Workspace loaded",
        layer: "Hologram init",
        detail: room_label(active_room)
      }
    }
  end

  defp message_inspector(nil) do
    inspector = %{
      title: "No message selected",
      provider_payload: %{},
      normalized_message: %{},
      persisted_record: %{},
      delivery: %{}
    }

    put_inspector_text(inspector)
  end

  defp message_inspector(message) do
    body = Map.get(message, :body, "")

    inspector = %{
      title: "#{Map.get(message, :source_label, "Local")}: #{String.slice(body, 0, 46)}",
      provider_payload: Map.get(message, :provider_payload, %{}) || %{},
      normalized_message: %{
        id: message.id,
        room_id: message.room_id,
        sender_id: message.sender_id,
        source: Map.get(message, :source, "local"),
        channel: Map.get(message, :channel, "assembly"),
        text: body
      },
      persisted_record: %{
        id: message.id,
        room_id: message.room_id,
        thread_id: message.thread_id,
        reply_to_id: message.reply_to_id,
        status: message.status
      },
      delivery: Map.get(message, :delivery, %{}) || %{}
    }

    put_inspector_text(inspector)
  end

  defp put_inspector_text(inspector) do
    inspector
    |> Map.put(
      :provider_payload_text,
      inspect(inspector.provider_payload, pretty: true, limit: 20)
    )
    |> Map.put(
      :normalized_message_text,
      inspect(inspector.normalized_message, pretty: true, limit: 20)
    )
    |> Map.put(
      :persisted_record_text,
      inspect(inspector.persisted_record, pretty: true, limit: 20)
    )
    |> Map.put(:delivery_text, inspect(inspector.delivery, pretty: true, limit: 20))
  end

  defp chat_contract(nil), do: []

  defp chat_contract(room) do
    post =
      Post.text("Message #{room_label(room)}",
        metadata: %{"workspace_id" => @workspace_id, "room_id" => room.id}
      )

    [
      %{
        label: "Room",
        value: "#{room.kind} #{room.id}",
        detail: "Jido.Chat.Runtime.Room.Record"
      },
      %{
        label: "Payload",
        value: Post.fallback_text(post),
        detail: "Jido.Chat.Post"
      },
      %{
        label: "Write path",
        value: "Jido.call",
        detail: "SQLite commit plus jido.chat.room.message fact"
      }
    ]
  end

  defp room_metrics(nil, _message_count, _thread_count), do: []

  defp room_metrics(room, message_count, thread_count) do
    [
      %{label: "Room", value: room_label(room)},
      %{label: "Type", value: room.kind},
      %{label: "Messages", value: Integer.to_string(message_count)},
      %{label: "Threads", value: Integer.to_string(thread_count)},
      %{label: "Durability", value: "SQLite"}
    ]
  end

  defp room_label(nil), do: "No Room"
  defp room_label(room), do: "#{room.prefix}#{room.name}"
end
