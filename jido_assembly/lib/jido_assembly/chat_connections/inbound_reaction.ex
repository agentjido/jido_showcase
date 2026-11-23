defmodule Jido.Assembly.ChatConnections.InboundReaction do
  @moduledoc "Imports a provider reaction on a message linked to an Assembly room."

  use Jido.Action, name: "assembly_bridge_inbound_reaction", schema: Jido.Joi.map()

  alias Jido.Assembly.{Bridges, ChatRuntime, ChatStorage, Seeds}
  alias Jido.Chat.Principal
  alias Jido.Chat.Runtime.Bridge.Binding
  alias Jido.Chat.Runtime.Signal.Room.{AddReaction, RemoveReaction}
  alias Jido.Chat.Signal.Identity

  @impl true
  def run(_params, %{
        agent_id: "jido.chat/account/" <> encoded_account,
        chat: %{adapter: adapter, client_id: client_id},
        signal: signal,
        agent_state: state
      }) do
    with true <- signal.source == Identity.client_source(client_id),
         {:ok, account_id} <- Base.url_decode64(encoded_account, padding: false),
         %{"room_id" => external_room, "message_id" => external_message, "actor_id" => actor} <-
           signal.data,
         {:ok, %Binding{enabled: true, direction: direction} = binding}
         when direction in [:inbound, :both] <-
           ChatRuntime.get_bridge_binding(account_id, external_room),
         {:ok, %{local_message_id: message_id}} <-
           ChatStorage.link_for_external(ChatStorage, account_id, external_room, external_message),
         {:ok, emoji} <- emoji_key(adapter.channel_type(), signal.data["reaction"]),
         {:ok, address} <- Jido.agent_address(ChatRuntime.jido(), binding.room_id),
         {:ok, command} <- room_command(signal.type, message_id, emoji),
         principal = external_actor(account_id, external_room, actor),
         {:ok, %Jido.AgentServer.TurnResult{status: :committed}} <-
           Jido.call(ChatRuntime.jido(), address, command, context: %{actor: principal}) do
      {:ok, state, []}
    else
      {:ok, nil} -> {:ok, state, []}
      {:ok, %Binding{}} -> {:ok, state, []}
      {:error, :missing_emoji} -> {:ok, state, []}
      {:ok, %Jido.AgentServer.TurnResult{error: reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_provider_reaction}
    end
  end

  def run(_params, _context), do: {:error, :invalid_provider_reaction}

  defp emoji_key(:telegram, "custom_emoji:" <> id) when id != "",
    do: {:ok, "telegram:emoji:" <> id}

  defp emoji_key(:discord, emoji) when is_binary(emoji) do
    case Regex.run(~r/:(\d+)$/, emoji, capture: :all_but_first) do
      [id] -> {:ok, "discord:emoji:" <> id}
      nil -> unicode_key(emoji)
    end
  end

  defp emoji_key(:slack, reaction) when reaction in ["+1", "thumbsup"], do: {:ok, "+1"}
  defp emoji_key(:slack, "rocket"), do: {:ok, "ship"}
  defp emoji_key(:slack, "eyes"), do: {:ok, "seen"}
  defp emoji_key(:slack, reaction) when is_binary(reaction), do: {:ok, "slack:emoji:" <> reaction}

  defp emoji_key(_provider, emoji), do: unicode_key(emoji)

  defp unicode_key(emoji) when is_binary(emoji) and emoji != "" do
    emoji = String.normalize(emoji, :nfc)
    option = Enum.find(Seeds.reaction_options(), &(&1.glyph == emoji))
    {:ok, if(option, do: option.key, else: emoji)}
  end

  defp unicode_key(_emoji), do: {:error, :missing_emoji}

  defp room_command("jido.chat.reaction.added", message_id, emoji),
    do: AddReaction.new(%{"message_id" => message_id, "reaction" => emoji})

  defp room_command("jido.chat.reaction.removed", message_id, emoji),
    do: RemoveReaction.new(%{"message_id" => message_id, "reaction" => emoji})

  defp external_actor(account_id, external_room, actor_id) do
    Principal.new(%{
      id: Bridges.external_actor_id(account_id, actor_id),
      kind: :service,
      attributes: %{"bridge_account" => account_id, "external_room" => external_room}
    })
  end
end
