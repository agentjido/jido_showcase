defmodule Jido.Assembly.ChatConnections.OutboundMessage do
  @moduledoc "Selects provider routes for thread replies and attachments."

  use Jido.Action, name: "assembly_bridge_outbound", schema: Jido.Joi.map()

  alias Jido.Assembly.{Bridges, ChatRuntime, ChatStorage}
  alias Jido.Assembly.Chat.Attachments
  alias Jido.Chat.{Adapter, Content, FileSource, Media, Message}
  alias Jido.Chat.Runtime.Actions.BridgeOutbound
  alias Jido.Chat.Runtime.Bridge
  alias Jido.Chat.Runtime.Bridge.{Binding, Worker}
  alias Jido.Chat.Runtime.Directives.RelayOutbound
  alias Jido.Chat.Signal.{SendFile, SendMessage}

  @impl true
  def run(params, context) do
    runtime = context.plugin_inputs[Bridge].runtime
    message = Message.from_map(context.signal.data["message"])
    attachments = Attachments.parts(message.content)

    if message.thread_id || attachments != [] do
      route_message(runtime, message, attachments, context)
    else
      BridgeOutbound.run(params, context)
    end
  end

  defp route_message(runtime, message, attachments, context) do
    origin = message.metadata["jido_chat_origin"] || %{}

    if context.signal.data["author"] == runtime.account_ref or
         origin["account_id"] == runtime.account_id do
      {:ok, context.agent_state, []}
    else
      with {:ok, adapter} when is_atom(adapter) <- Bridges.account_adapter(runtime.account_id),
           operation = operation(message, attachments, adapter),
           {:ok, work} <- build_work(runtime, message, adapter.channel_type(), operation),
           :ok <- Worker.admit_many(runtime.worker, work) do
        {:ok, context.agent_state, Enum.map(work, &%RelayOutbound{work: &1})}
      else
        {:error, _reason} = error -> error
        _unavailable -> {:error, :bridge_provider_unavailable}
      end
    end
  end

  defp build_work(runtime, message, provider, operation) do
    Enum.reduce_while(runtime.mappings, {:ok, []}, fn mapping, {:ok, work} ->
      case build_delivery(runtime, mapping, message, provider, operation) do
        {:ok, nil} -> {:cont, {:ok, work}}
        {:ok, item} -> {:cont, {:ok, [item | work]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp build_delivery(runtime, mapping, message, provider, operation) do
    room = message.room_id
    id = request_id(runtime.account_id, mapping.name, message.id)

    with {:ok, %Binding{enabled: true, room_id: ^room, direction: direction} = binding}
         when direction in [:outbound, :both] <-
           ChatRuntime.get_bridge_binding(runtime.account_id, mapping.external_room),
         {:ok, nil} <- ChatStorage.get_work(ChatStorage, id),
         {:ok, reference} <- thread_reference(provider, runtime, mapping, message) do
      work = %{
        id: id,
        kind: :outbound,
        account_id: binding.account_id,
        mapping: mapping.name,
        local_message_id: message.id,
        external_room_id: binding.external_room_id,
        provider: provider
      }

      create_work(work, operation, binding, message, runtime.client_id, reference)
    else
      {:ok, %{delivery_route: route}} when route in [:thread_skipped, :attachment_skipped] ->
        {:ok, nil}

      {:ok, %{kind: :outbound} = existing} ->
        {:ok, existing}

      {:ok, _binding} ->
        {:ok, nil}

      {:error, _reason} = error ->
        error
    end
  end

  defp operation(message, [], _adapter),
    do: {:ok, SendMessage, %{"text" => Message.fallback_text(message)}, nil}

  defp operation(message, [%Media{source: %FileSource{kind: :base64} = source} = media], adapter) do
    attachment = Attachments.view(media)

    if Adapter.capabilities(adapter)[:send_file] in [:native, :emulated] and
         byte_size(source.content_base64) <= 240_000 do
      caption =
        for %Content{kind: :text, text: text} <- message.content, do: text

      data = %{
        "source" => %{
          "filename" => source.filename,
          "content_base64" => source.content_base64
        },
        "media_kind" => if(media.kind == :image, do: "image", else: "file")
      }

      data = if caption == [], do: data, else: Map.put(data, "caption", Enum.join(caption, "\n"))
      {:ok, SendFile, data, attachment}
    else
      {:unsupported, attachment}
    end
  end

  defp operation(_message, _attachments, _adapter), do: {:unsupported, nil}

  defp create_work(work, {:unsupported, attachment}, _binding, _message, _client, _reference) do
    work
    |> Map.put(:attachment, attachment)
    |> skip(:attachment_skipped, "attachment_unsupported")
  end

  defp create_work(work, {:ok, command, payload, attachment}, binding, message, client, reference) do
    data = %{
      "client_id" => client,
      "request_id" => work.id,
      "room_id" => binding.external_room_id
    }

    work = Map.put(work, :attachment, attachment)

    case route(binding, message, reference) do
      {:send, route, params} ->
        signal = command.new!(data |> Map.merge(payload) |> Map.merge(params))
        {:ok, Map.merge(work, %{signal: signal, delivery_route: route})}

      :skip ->
        skip(work, :thread_skipped, "thread_unavailable")
    end
  end

  defp route(_binding, %{thread_id: nil}, _reference), do: {:send, :room, %{}}
  defp route(_binding, _message, {key, id}), do: {:send, :thread, %{key => id}}
  defp route(%Binding{metadata: %{"thread_fallback" => "skip"}}, _message, nil), do: :skip
  defp route(_binding, _message, nil), do: {:send, :thread_fallback, %{}}

  defp skip(work, route, reason) do
    terminal =
      Map.merge(work, %{
        status: :failed,
        delivery_route: route,
        error: reason
      })

    with {:ok, _work} <- ChatStorage.put_work(ChatStorage, terminal), do: {:ok, nil}
  end

  defp thread_reference(_provider, _runtime, _mapping, %{thread_id: nil}), do: {:ok, nil}
  defp thread_reference(:x, _runtime, _mapping, _message), do: {:ok, nil}

  defp thread_reference(:slack, runtime, mapping, message) do
    with {:ok, links} <-
           ChatStorage.links_for_local(ChatStorage, runtime.account_id, message.thread_id) do
      {:ok,
       Enum.find_value(links, fn link ->
         if link.external_room_id == mapping.external_room,
           do: {"thread_id", link.external_message_id}
       end)}
    end
  end

  defp thread_reference(_provider, runtime, mapping, _message) do
    case runtime.reply_links[mapping.name] do
      nil -> {:ok, nil}
      id -> {:ok, {"reply_to_id", id}}
    end
  end

  defp request_id(account, mapping, message_id) do
    key = :erlang.term_to_binary({account, mapping, message_id})
    "bridge-outbound/" <> Base.url_encode64(:crypto.hash(:sha256, key), padding: false)
  end
end
