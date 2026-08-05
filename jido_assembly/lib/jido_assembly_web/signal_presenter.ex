defmodule Jido.AssemblyWeb.SignalPresenter do
  @moduledoc """
  Presents `Jido.Signal` structs as small Hologram-safe maps.

  Signals are domain/runtime facts. Hologram actions only need a compact
  payload for the developer inspector, so this module owns that UI boundary.
  """

  @data_keys [
    :message_id,
    :participant_id,
    :presence,
    :from,
    :to,
    :reason,
    :thread_id,
    :is_typing,
    :reaction,
    :room_id
  ]

  def summary(signals, type) when is_list(signals) and is_binary(type) do
    signals
    |> Enum.find(&match_type?(&1, type))
    |> summary()
  end

  def summary(signals, types) when is_list(signals) and is_list(types) do
    Enum.find_value(types, &summary(signals, &1))
  end

  def summary([%Jido.Signal{} = signal | _signals]), do: summary(signal)
  def summary([]), do: nil
  def summary(nil), do: nil

  def summary(%Jido.Signal{data: data} = signal) when is_map(data) do
    data
    |> Enum.reduce(base_summary(signal), &put_data/2)
    |> reject_nil_values()
  end

  def summary(%Jido.Signal{} = signal), do: base_summary(signal)

  defp match_type?(%Jido.Signal{type: type}, type), do: true
  defp match_type?(_signal, _type), do: false

  defp base_summary(signal) do
    %{
      id: signal.id,
      type: signal.type,
      source: signal.source,
      subject: signal.subject
    }
  end

  defp put_data({:message_id, value}, summary), do: put_known(summary, :message_id, value)
  defp put_data({"message_id", value}, summary), do: put_known(summary, :message_id, value)
  defp put_data({:participant_id, value}, summary), do: put_known(summary, :participant_id, value)

  defp put_data({"participant_id", value}, summary),
    do: put_known(summary, :participant_id, value)

  defp put_data({:presence, value}, summary), do: put_known(summary, :presence, value)
  defp put_data({"presence", value}, summary), do: put_known(summary, :presence, value)
  defp put_data({:from, value}, summary), do: put_known(summary, :from, value)
  defp put_data({"from", value}, summary), do: put_known(summary, :from, value)
  defp put_data({:to, value}, summary), do: put_known(summary, :to, value)
  defp put_data({"to", value}, summary), do: put_known(summary, :to, value)
  defp put_data({:reason, value}, summary), do: put_known(summary, :reason, value)
  defp put_data({"reason", value}, summary), do: put_known(summary, :reason, value)
  defp put_data({:thread_id, value}, summary), do: put_known(summary, :thread_id, value)
  defp put_data({"thread_id", value}, summary), do: put_known(summary, :thread_id, value)
  defp put_data({:is_typing, value}, summary), do: put_known(summary, :is_typing, value)
  defp put_data({"is_typing", value}, summary), do: put_known(summary, :is_typing, value)
  defp put_data({:reaction, value}, summary), do: put_known(summary, :reaction, value)
  defp put_data({"reaction", value}, summary), do: put_known(summary, :reaction, value)
  defp put_data({:room_id, value}, summary), do: put_known(summary, :room_id, value)
  defp put_data({"room_id", value}, summary), do: put_known(summary, :room_id, value)
  defp put_data(_entry, summary), do: summary

  defp put_known(summary, _key, nil), do: summary

  defp put_known(summary, key, value) when key in @data_keys do
    Map.put(summary, key, value)
  end

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
