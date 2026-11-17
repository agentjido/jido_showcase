defmodule Jido.Assembly.Seeds do
  @moduledoc """
  Demo workspace seed data and startup seeding for Assembly.

  The showcase boots directly into an ops workflow Room. Every visible item is
  a durable Jido Chat V3 fact. Stable IDs make startup retries idempotent.
  """

  use GenServer

  alias Jido.Assembly.{ChatRuntime, ChatStorage}
  alias Jido.Chat.{Actor, Post}
  alias Jido.Chat.Runtime.Signal.Room.{AddReaction, Join}
  alias Jido.Chat.Runtime.Signal.Room.Post, as: PostSignal

  @seed_version "1"
  @room_definition "assembly.room.v1"

  @workspace_id "jido"
  @workspace_name "Jido Assembly"
  @current_user_id "user:you"
  @system_user_id "system:assembly"
  @default_room_id "room:ops-workflow"

  @reaction_options [
    %{key: "+1", glyph: "👍", label: "Agree"},
    %{key: "ship", glyph: "🚀", label: "Approve"},
    %{key: "seen", glyph: "👀", label: "Seen"}
  ]

  @reaction_metadata Map.new(@reaction_options, fn option ->
                       {option.key, Map.take(option, [:glyph, :label])}
                     end)

  @people [
    %{
      id: "user:you",
      name: "You",
      handle: "you",
      initials: "YO",
      presence: :online,
      title: "Workspace owner",
      tone: "bg-[var(--assembly-accent)] text-stone-950"
    },
    %{
      id: "user:maggie",
      name: "Maggie",
      handle: "maggie",
      initials: "MH",
      presence: :online,
      title: "Adapter lead",
      tone: "bg-rose-200 text-rose-950"
    },
    %{
      id: "user:nolan",
      name: "Nolan",
      handle: "nolan",
      initials: "NO",
      presence: :online,
      title: "Runtime",
      tone: "bg-indigo-200 text-indigo-950"
    },
    %{
      id: "user:priya",
      name: "Priya",
      handle: "priya",
      initials: "PR",
      presence: :away,
      title: "Product design",
      tone: "bg-violet-200 text-violet-950"
    },
    %{
      id: "agent:triage",
      name: "Triage Agent",
      handle: "triage",
      initials: "TA",
      presence: :online,
      title: "Impact and severity",
      type: :agent,
      capabilities: [:text, :ai],
      tone: "bg-cyan-200 text-cyan-950"
    },
    %{
      id: "agent:bridge",
      name: "Bridge Agent",
      handle: "bridge",
      initials: "BA",
      presence: :online,
      title: "Connector and delivery state",
      type: :agent,
      capabilities: [:text, :ai],
      tone: "bg-lime-200 text-lime-950"
    },
    %{
      id: "agent:runbook",
      name: "Runbook Agent",
      handle: "runbook",
      initials: "RA",
      presence: :online,
      title: "Next actions and approvals",
      type: :agent,
      capabilities: [:text, :ai],
      tone: "bg-amber-200 text-amber-950"
    },
    %{
      id: "provider:telegram",
      name: "Telegram Ops",
      handle: "telegram",
      initials: "TG",
      presence: :online,
      title: "Telegram connector",
      type: :system,
      capabilities: [:text],
      tone: "bg-sky-200 text-sky-950"
    },
    %{
      id: "provider:discord",
      name: "Discord Engineering",
      handle: "discord",
      initials: "DC",
      presence: :online,
      title: "Discord connector",
      type: :system,
      capabilities: [:text],
      tone: "bg-indigo-200 text-indigo-950"
    },
    %{
      id: "workflow:deploy",
      name: "Deploy Workflow",
      handle: "workflow",
      initials: "WF",
      presence: :online,
      title: "Jido workflow event",
      type: :system,
      capabilities: [:text],
      tone: "bg-emerald-200 text-emerald-950"
    },
    %{
      id: @system_user_id,
      name: "Assembly",
      handle: "assembly",
      initials: "JA",
      presence: :online,
      title: "System",
      type: :system,
      tone: "bg-stone-800 text-stone-100"
    }
  ]

  @seed_channels [
    %{
      id: "room:ops-workflow",
      name: "ops-workflow",
      topic:
        "One canonical room where humans, agents, workflow events, Telegram, and Discord meet.",
      position: 10,
      agent_room: true
    },
    %{
      id: "room:runtime",
      name: "runtime",
      topic: "Jido Chat Runtime persistence, Signals, and Hologram state.",
      position: 20
    },
    %{
      id: "room:connector-lab",
      name: "connector-lab",
      topic: "Focused notes for optional Telegram and Discord connector setup.",
      position: 30
    }
  ]

  @seed_dms [
    %{id: "dm:maggie", participant_id: "user:maggie", position: 110},
    %{id: "dm:nolan", participant_id: "user:nolan", position: 120},
    %{id: "dm:priya", participant_id: "user:priya", position: 130},
    %{id: "dm:triage", participant_id: "agent:triage", position: 210},
    %{id: "dm:bridge", participant_id: "agent:bridge", position: 220},
    %{id: "dm:runbook", participant_id: "agent:runbook", position: 230}
  ]

  @seed_messages %{
    "room:ops-workflow" => [
      %{
        id: "msg:ops-telegram-symptom",
        sender_id: "provider:telegram",
        role: :user,
        body:
          "[Telegram #customer-ops] EU checkout latency is over 4s for the third minute. Two customers reported payment retries.",
        metadata: %{
          source: "adapter",
          channel: :telegram,
          bridge_id: "assembly:telegram",
          external_message_id: "tg-demo-1001",
          external_room_id: "telegram-demo-ops",
          provider_payload: %{
            "chat_id" => "telegram-demo-ops",
            "message_id" => "tg-demo-1001",
            "username" => "customer_ops"
          }
        },
        reactions: %{"seen" => ["user:you", "user:maggie"]}
      },
      %{
        id: "msg:ops-discord-context",
        sender_id: "provider:discord",
        role: :user,
        body:
          "[Discord #eng-oncall] Deploy 2026.06.01.4 changed the pricing cache TTL. Error rate is still flat, but p95 latency moved.",
        metadata: %{
          source: "adapter",
          channel: :discord,
          bridge_id: "assembly:discord",
          external_message_id: "dc-demo-2201",
          external_room_id: "discord-demo-eng",
          provider_payload: %{
            "channel_id" => "discord-demo-eng",
            "message_id" => "dc-demo-2201",
            "author" => "eng-oncall"
          }
        },
        reactions: %{"seen" => ["user:nolan"]}
      },
      %{
        id: "msg:ops-triage-summary",
        sender_id: "agent:triage",
        role: :assistant,
        body:
          "Impact is customer-visible checkout latency in EU, severity looks elevated but not outage-level. Open question: whether pricing cache TTL increased remote calls during checkout.",
        metadata: %{
          source: "jido",
          agent_id: "agent:triage",
          agent_name: "Triage Agent",
          agent_round_id: "seeded-ops-round",
          agent_prompt_message_id: "msg:ops-telegram-symptom",
          seeded: true
        }
      },
      %{
        id: "msg:ops-workflow-approval",
        sender_id: "workflow:deploy",
        role: :system,
        body:
          "Approval requested: roll back pricing cache TTL from 15m to 2m for EU checkout. Requires one engineer acknowledgement.",
        metadata: %{
          source: "workflow",
          workflow_event_type: "approval_requested",
          workflow_run_id: "wf-eu-checkout-rollback",
          severity: "high",
          state: "waiting_for_approval",
          actions: ["approve", "hold", "open_runbook"],
          external_refs: ["deploy:2026.06.01.4", "runbook:checkout-cache"]
        },
        reactions: %{"ship" => ["user:maggie"], "+1" => ["user:you"]}
      },
      %{
        id: "msg:ops-thread-root",
        sender_id: "user:nolan",
        role: :user,
        body:
          "I am opening a diagnosis thread on the TTL change. First check: compare cache miss rate before and after deploy.",
        metadata: %{source: "seed", thread_topic: "Pricing cache diagnosis"},
        reactions: %{"seen" => ["agent:runbook"]}
      },
      %{
        id: "msg:ops-thread-runbook",
        sender_id: "agent:runbook",
        role: :assistant,
        body:
          "Runbook step: if cache miss rate increased more than 20%, roll back TTL and watch checkout p95 for two windows.",
        thread_id: "msg:ops-thread-root",
        reply_to_id: "msg:ops-thread-root",
        metadata: %{
          source: "jido",
          agent_id: "agent:runbook",
          agent_name: "Runbook Agent",
          seeded: true
        }
      },
      %{
        id: "msg:ops-bridge-note",
        sender_id: "agent:bridge",
        role: :assistant,
        body:
          "Connector state is canonical: Telegram and Discord messages land in this room through room bindings, and local messages broadcast to every configured live bridge.",
        metadata: %{
          source: "jido",
          agent_id: "agent:bridge",
          agent_name: "Bridge Agent",
          seeded: true
        }
      }
    ],
    "room:runtime" => [
      {"user:nolan",
       "Treat realtime as a notification layer, then read canonical records from Jido Chat storage."},
      {"user:maggie",
       "Room declarations, provider connections, bindings, and messages use the Jido Chat Runtime."}
    ],
    "room:connector-lab" => [
      {"system:assembly",
       "Set TELEGRAM_BOT_TOKEN plus TELEGRAM_TEST_CHAT_ID or DISCORD_BOT_TOKEN plus DISCORD_TEST_CHANNEL_ID, then restart Assembly."},
      {"user:you",
       "Without credentials, this room still shows provider-shaped demo traffic in #ops-workflow."}
    ],
    "dm:maggie" => [
      {"user:maggie",
       "The ops room should prove the bridge path without turning into admin CRUD."},
      {"user:you", "Agreed. Setup is automatic; the UI shows status and evidence."}
    ],
    "dm:nolan" => [
      {"user:nolan", "SQLite durability is enough for the developer showcase."}
    ],
    "dm:priya" => [
      {"user:priya",
       "Drop directly into the chat experience. Setup can stay as a small status surface."}
    ],
    "dm:triage" => [
      {"agent:triage",
       "Mention me in the ops room when you need impact, severity, and unresolved questions."}
    ],
    "dm:bridge" => [
      {"agent:bridge", "I can explain connector state, delivery attempts, and room bindings."}
    ],
    "dm:runbook" => [
      {"agent:runbook", "I turn an ops signal into ordered checks and approval steps."}
    ]
  }

  def workspace_id, do: @workspace_id
  def workspace_name, do: @workspace_name
  def current_user_id, do: @current_user_id
  def system_user_id, do: @system_user_id
  def default_room_id, do: @default_room_id
  def people, do: @people
  def reaction_options, do: @reaction_options

  def agent_people do
    Enum.filter(@people, &(Map.get(&1, :type) == :agent))
  end

  def demo_users do
    @people
    |> Enum.reject(&Map.get(&1, :type))
    |> Enum.map(&person_view_from_seed/1)
  end

  def demo_user_ids do
    @people
    |> Enum.reject(&Map.get(&1, :type))
    |> Enum.map(& &1.id)
  end

  def person_seed(person_id) do
    Enum.find(@people, &(&1.id == person_id)) || fallback_person(person_id)
  end

  def reaction_metadata(emoji) do
    Map.get(@reaction_metadata, emoji, %{glyph: emoji, label: emoji})
  end

  def available_reaction_options(reactions) do
    reaction_keys = Enum.map(reactions, & &1.emoji)
    Enum.reject(@reaction_options, &(&1.key in reaction_keys))
  end

  def ensure_seeded! do
    case Process.whereis(__MODULE__) do
      nil -> seed_all()
      pid when pid == self() -> seed_all()
      _pid -> GenServer.call(__MODULE__, :ensure_seeded, 30_000)
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case seed_all() do
      :ok -> {:ok, %{seed_version: @seed_version}}
      {:error, reason} -> {:stop, {:seed_failed, reason}}
    end
  end

  @impl true
  def handle_call(:ensure_seeded, _from, state), do: {:reply, :ok, state}

  defp seed_all do
    with {:ok, _version} <- ChatStorage.get_metadata("seed_version"),
         :ok <- seed_rooms(),
         :ok <- seed_messages(),
         :ok <- seed_reactions(),
         :ok <- ChatStorage.put_metadata("seed_version", @seed_version) do
      :ok
    end
  end

  defp seed_rooms do
    Enum.reduce_while(room_specs(), :ok, fn spec, :ok ->
      case ensure_room(spec) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp room_specs do
    channels =
      Enum.map(@seed_channels, fn channel ->
        members = channel_member_ids(channel)

        %{
          id: channel.id,
          kind: :channel,
          name: channel.name,
          members: members,
          metadata: %{
            "workspace_id" => @workspace_id,
            "assembly_kind" => "channel",
            "topic" => channel.topic,
            "member_ids" => members,
            "position" => channel.position,
            "source_key" => "seed/room/#{channel.id}"
          }
        }
      end)

    dms =
      Enum.map(@seed_dms, fn dm ->
        person = person_seed(dm.participant_id)
        members = [@current_user_id, dm.participant_id]

        %{
          id: dm.id,
          kind: :direct,
          name: person.name,
          members: members,
          metadata: %{
            "workspace_id" => @workspace_id,
            "assembly_kind" => "dm",
            "topic" => "Direct messages with #{person.name}.",
            "participant_ids" => members,
            "position" => dm.position,
            "source_key" => "seed/room/#{dm.id}"
          }
        }
      end)

    channels ++ dms
  end

  defp ensure_room(%{id: id, members: members} = spec) do
    room_result =
      case ChatRuntime.get_room(id) do
        {:ok, _room} ->
          :ok

        {:error, :not_found} ->
          case ChatRuntime.provision_room(
                 @room_definition,
                 Map.take(spec, [:id, :kind, :name, :metadata])
               ) do
            {:ok, _result} -> :ok
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end

    with :ok <- room_result, do: join_members(id, members)
  end

  defp join_members(room_id, members) do
    Enum.reduce_while(Enum.uniq([@current_user_id, @system_user_id | members]), :ok, fn member,
                                                                                        :ok ->
      case ChatRuntime.get_room_membership(room_id, member) do
        {:ok, %{status: :active}} ->
          {:cont, :ok}

        _other ->
          request = Join.new!(%{"member" => member})

          case room_call(room_id, request, @current_user_id) do
            {:ok, _result} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp channel_member_ids(%{agent_room: true}) do
    demo_user_ids() ++
      Enum.map(agent_people(), & &1.id) ++
      [@system_user_id, "provider:telegram", "provider:discord", "workflow:deploy"]
  end

  defp channel_member_ids(_channel), do: demo_user_ids() ++ [@system_user_id]

  defp seed_messages do
    Enum.reduce_while(@seed_messages, :ok, fn {room_id, messages}, :ok ->
      result =
        messages
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {message, index}, :ok ->
          case seed_message(room_id, normalize_seed_message(room_id, message, index)) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_seed_message(room_id, {sender_id, text}, index) do
    %{
      id: seed_message_id(room_id, index),
      sender_id: sender_id,
      body: text,
      role: message_role(sender_id),
      metadata: %{source: "seed"},
      reactions: %{}
    }
  end

  defp normalize_seed_message(room_id, attrs, index) do
    attrs
    |> Map.put_new(:id, seed_message_id(room_id, index))
    |> Map.put_new(:role, message_role(Map.fetch!(attrs, :sender_id)))
    |> Map.put_new(:metadata, %{source: "seed"})
    |> Map.put_new(:reactions, %{})
  end

  defp seed_message(room_id, attrs) do
    case ChatRuntime.get_room_history(room_id, attrs.id) do
      {:ok, %Jido.Chat.Runtime.Room.HistoryRecord{}} ->
        :ok

      {:ok, nil} ->
        metadata =
          attrs.metadata
          |> stringify_keys()
          |> Map.put("workspace_id", @workspace_id)
          |> Map.put("source_key", "seed/message/#{attrs.id}")
          |> Map.put("mentions", [])
          |> Map.put("mention_handles", [])
          |> put_origin(attrs.sender_id, attrs.role)

        post =
          Post.text(attrs.body,
            thread_id: Map.get(attrs, :thread_id),
            reply_to_id: Map.get(attrs, :reply_to_id),
            mentions: [],
            metadata: metadata
          )

        request =
          PostSignal.new!(
            %{"post" => Post.to_map(post), "mentions" => post.mentions},
            id: attrs.id
          )

        case room_call(room_id, request, attrs.sender_id) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp seed_reactions do
    Enum.reduce_while(@seed_messages, :ok, fn {room_id, messages}, :ok ->
      result =
        messages
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {message, index}, :ok ->
          attrs = normalize_seed_message(room_id, message, index)

          reactions =
            Enum.flat_map(attrs.reactions, fn {reaction, actors} ->
              Enum.map(actors, &{reaction, &1})
            end)

          case Enum.reduce_while(reactions, :ok, fn {reaction, actor}, :ok ->
                 case ensure_reaction(room_id, attrs.id, reaction, actor) do
                   :ok -> {:cont, :ok}
                   {:error, reason} -> {:halt, {:error, reason}}
                 end
               end) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ensure_reaction(room_id, message_id, reaction, actor) do
    case ChatRuntime.get_room_reaction(room_id, message_id, reaction, actor) do
      {:ok, %{status: :active}} ->
        :ok

      _other ->
        request = AddReaction.new!(%{"message_id" => message_id, "reaction" => reaction})

        case room_call(room_id, request, actor) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp room_call(room_id, request, actor) do
    with {:ok, address} <- Jido.agent_address(ChatRuntime.jido(), room_id),
         {:ok, %Jido.AgentServer.TurnResult{status: :committed} = result} <-
           Jido.call(ChatRuntime.jido(), address, request, context: %{actor: actor}) do
      {:ok, result}
    else
      {:ok, %Jido.AgentServer.TurnResult{status: status, error: reason}} ->
        {:error, {status, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp seed_message_id(room_id, index) do
    digest = :crypto.hash(:sha256, "#{room_id}:#{index}") |> Base.url_encode64(padding: false)
    "seed:#{digest}"
  end

  defp put_origin(metadata, sender_id, role) do
    kind =
      case role do
        :assistant -> :agent
        :system -> :system
        _other -> :human
      end

    profile = person_seed(sender_id)

    actor =
      Actor.new(%{
        id: sender_id,
        kind: kind,
        username: Map.get(profile, :handle),
        display_name: Map.get(profile, :name)
      })

    Map.put(metadata, "jido_chat_origin", %{"actor" => Actor.to_map(actor)})
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp message_role(@system_user_id), do: :system

  defp message_role(sender_id) do
    case person_seed(sender_id) do
      %{type: :agent} -> :assistant
      %{type: :system} -> :system
      _person -> :user
    end
  end

  defp person_view_from_seed(person) do
    %{
      id: person.id,
      name: person.name,
      handle: person.handle,
      initials: person.initials,
      title: person.title,
      tone: person.tone,
      presence: person.presence |> Atom.to_string()
    }
  end

  defp fallback_person(person_id) do
    %{
      id: person_id,
      name: person_id,
      initials: initials_for(person_id),
      title: "",
      tone: "bg-stone-200 text-stone-950",
      presence: "offline"
    }
  end

  defp initials_for(value) do
    value
    |> to_string()
    |> String.split(~r/[^a-zA-Z0-9]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
    |> case do
      "" -> "??"
      initials -> initials
    end
  end
end
