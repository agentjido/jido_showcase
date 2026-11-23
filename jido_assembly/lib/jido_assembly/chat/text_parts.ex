defmodule Jido.Assembly.Chat.TextParts do
  @moduledoc "Splits readable chat text into text, code and HTTP links without creating HTML."

  @markup ~r/\x60{3}[^\r\n]*\r?\n[\s\S]*?\x60{3}|\x60[^\x60\r\n]+\x60|https?:\/\/[^\s<>"'\x60]*[^\s<>"'\x60.,;:!?)\]]/iu

  def split(body) when is_binary(body) do
    {parts, offset} =
      Enum.reduce(Regex.scan(@markup, body, return: :index), {[], 0}, fn [{start, count}],
                                                                         {parts, offset} ->
        matched = binary_part(body, start, count)
        parts = add_text(parts, body, offset, start - offset)
        {[formatted(matched, start) | parts], start + count}
      end)

    parts
    |> add_text(body, offset, byte_size(body) - offset)
    |> Enum.reverse()
  end

  defp add_text(parts, _body, _offset, 0), do: parts

  defp add_text(parts, body, offset, count),
    do: [%{kind: :text, text: binary_part(body, offset, count), offset: offset} | parts]

  defp formatted(<<96, 96, 96, rest::binary>>, offset) do
    [_language, body] = String.split(rest, "\n", parts: 2)
    %{kind: :code_block, text: binary_part(body, 0, byte_size(body) - 3), offset: offset}
  end

  defp formatted(<<96, rest::binary>>, offset),
    do: %{kind: :code, text: binary_part(rest, 0, byte_size(rest) - 1), offset: offset}

  defp formatted(value, offset) do
    case URI.new(value) do
      {:ok, %{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        %{kind: :link, text: value, offset: offset}

      _other ->
        %{kind: :text, text: value, offset: offset}
    end
  end
end
