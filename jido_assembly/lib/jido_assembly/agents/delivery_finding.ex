defmodule Jido.Assembly.Agents.DeliveryFinding do
  @moduledoc "Validates a Bridge finding and binds its citations to stored chat evidence."

  alias Jido.Joi

  @schema Joi.object(
            %{
              "outcome" => Joi.enum(["confirmed", "pending", "blocked"]),
              "summary" => Joi.string(min_length: 1, max_length: 240),
              "source_message_ids" =>
                Joi.array(Joi.string(min_length: 1, max_length: 256),
                  min_length: 1,
                  max_length: 4
                )
            },
            unrecognized_keys: :error
          )

  def output_schema, do: Joi.to_json_schema(@schema)

  def result(raw, evidence) do
    with :ok <- Joi.validate(@schema, raw),
         %{"summary" => summary, "source_message_ids" => ids} <- raw,
         summary when summary != "" <- String.trim(summary),
         ^ids <- Enum.uniq(ids),
         true <- Enum.all?(ids, fn id -> Enum.any?(evidence, &(&1["id"] == id)) end) do
      {:ok, %{body: summary, data: %{raw | "summary" => summary}}}
    else
      _invalid -> {:error, :invalid_delivery_finding}
    end
  end

  def scripted_result(trigger_id) do
    %{
      "outcome" => "pending",
      "summary" => "Check the provider receipts before confirming delivery.",
      "source_message_ids" => [trigger_id]
    }
  end
end
