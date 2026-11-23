defmodule Jido.Assembly.RoomAuthorizer do
  @moduledoc "Admits imported reactions through an active provider binding."

  @behaviour Jido.Chat.Authorizer

  alias Jido.Assembly.ChatRuntime
  alias Jido.Chat.Authorizer.Room
  alias Jido.Chat.Principal
  alias Jido.Chat.Runtime.Bridge.Binding

  @impl true
  def authorize(
        %Principal{
          id: "provider:" <> _,
          kind: :service,
          attributes: %{"bridge_account" => account, "external_room" => external_room}
        },
        action,
        %{type: :room, id: %{id: room_id}},
        _context
      )
      when action in [:reaction_add, :reaction_remove] do
    with {:ok, %Binding{room_id: ^room_id, enabled: true, direction: direction}}
         when direction in [:inbound, :both] <-
           ChatRuntime.get_bridge_binding(account, external_room),
         {:ok, member} <- ChatRuntime.connection_ref(account),
         {:ok, %{status: :active}} <- ChatRuntime.get_room_membership(room_id, member) do
      :ok
    else
      _other -> {:error, :not_authorized}
    end
  end

  def authorize(principal, action, resource, context),
    do: Room.authorize(principal, action, resource, context)
end
