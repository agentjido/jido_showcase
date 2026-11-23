defmodule Jido.Assembly.ChatConnections.DeliveryResult do
  @moduledoc "Settles file results and preserves retry delays from provider rejections."

  use Jido.Action, name: "assembly_bridge_delivery_result", schema: Jido.Joi.map()

  alias Jido.Assembly.{ChatRuntime, ChatStorage}
  alias Jido.Chat.Runtime.Actions.BridgeResult
  alias Jido.Chat.Runtime.Bridge.Worker
  alias Jido.Chat.Runtime.Directives.CompleteOutbound
  alias Jido.Chat.Signal.{SendFile, SendMessage}

  @file_completed Jido.Chat.SendFile.Completed.type()
  @file_failed Jido.Chat.SendFile.Failed.type()
  @message_failed Jido.Chat.SendMessage.Failed.type()

  @impl true
  def run(params, %{signal: %{type: @message_failed, data: data}} = context) do
    if rate_limited?(data),
      do: settle(context, SendMessage.type(), :failed),
      else: BridgeResult.run(params, context)
  end

  def run(_params, %{signal: %{type: @file_completed}} = context),
    do: settle(context, SendFile.type(), :completed)

  def run(_params, %{signal: %{type: @file_failed}} = context),
    do: settle(context, SendFile.type(), :failed)

  defp settle(
         %{agent_id: "jido.chat/account/" <> encoded, signal: signal} = context,
         type,
         outcome
       ) do
    request_id = signal.data["request_id"]

    with {:ok, account_id} <- Base.url_decode64(encoded, padding: false),
         worker = Worker.server(ChatRuntime, account_id),
         %{client_source: source} <- Worker.data(worker),
         true <- signal.source == source,
         {:ok, %{kind: :outbound, account_id: ^account_id, signal: %Jido.Signal{type: ^type}}} <-
           Worker.get_work(worker, request_id) do
      settle_result(context, request_id, outcome)
    else
      _invalid -> {:error, :invalid_bridge_delivery_result}
    end
  catch
    :exit, _reason -> {:error, :bridge_worker_unavailable}
  end

  defp settle_result(%{signal: %{data: data}} = context, request_id, outcome) do
    if outcome == :failed and rate_limited?(data) do
      with {:ok, _work} <- ChatStorage.record_delivery_rate_limit(request_id, data) do
        {:ok, context.agent_state, []}
      end
    else
      directive = %CompleteOutbound{request_id: request_id, outcome: outcome, result: data}
      {:ok, context.agent_state, [directive]}
    end
  end

  defp rate_limited?(%{"code" => "rate_limited", "outcome" => outcome})
       when outcome in ["rejected", "not_attempted"],
       do: true

  defp rate_limited?(_data), do: false
end
