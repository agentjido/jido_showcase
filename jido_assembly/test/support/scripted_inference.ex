defmodule Jido.Assembly.ScriptedInference do
  @moduledoc false

  @behaviour Jido.AI.InferenceClient

  def child_spec(replies) do
    %{
      id: __MODULE__,
      start: {Agent, :start_link, [fn -> {replies, []} end, [name: __MODULE__]]}
    }
  end

  def calls do
    Agent.get(__MODULE__, fn {_replies, calls} -> Enum.reverse(calls) end)
  end

  @impl true
  def generate_text(model, context, options) do
    call = %{model: model, messages: ReqLLM.Context.to_list(context), options: options}

    reply =
      Agent.get_and_update(__MODULE__, fn
        {responder, calls} when is_function(responder, 1) ->
          {responder, {responder, [call | calls]}}

        {[reply | rest], calls} ->
          {reply, {rest, [call | calls]}}

        {[], calls} ->
          {nil, {[], [call | calls]}}
      end)

    reply = if is_function(reply, 1), do: reply.(call), else: reply

    case reply do
      nil ->
        {:error, :unexpected_model_call}

      {:error, reason} ->
        {:error, reason}

      {:object, object} ->
        {:ok, %{response(model, context, Jason.encode!(object)) | object: object}}

      :live ->
        Jido.AI.InferenceClient.ReqLLM.generate_text(model, context, options)

      {:tool, name, params} ->
        id = "assembly-fixture-call-#{System.unique_integer([:positive])}"
        message = ReqLLM.Context.assistant("", tool_calls: [{name, params, id: id}])

        {:ok, %{response(model, context, "") | message: message, finish_reason: :tool_calls}}

      text ->
        {:ok, response(model, context, text)}
    end
  end

  defp response(model, context, text) do
    %ReqLLM.Response{
      id: "assembly-test-model",
      model: model,
      context: context,
      message: ReqLLM.Context.assistant(text),
      finish_reason: :stop,
      usage: %{input_tokens: 12, output_tokens: 6}
    }
  end

  @impl true
  def evaluation_models, do: []

  for {name, arity} <- Jido.AI.InferenceClient.behaviour_info(:callbacks),
      {name, arity} not in [generate_text: 3, evaluation_models: 0] do
    @impl true
    def unquote(name)(unquote_splicing(Macro.generate_arguments(arity, __MODULE__))),
      do: {:error, :not_supported}
  end
end
