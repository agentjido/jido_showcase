defmodule Jido.Assembly.Chat.Mentions do
  @moduledoc """
  Resolves Assembly-local `@handle` mentions against persisted participants.

  `jido_messaging` owns participant storage. Assembly owns the workspace handle
  syntax and projects resolved user IDs into message metadata for the demo UI.
  """

  alias Jido.Assembly.Messaging
  alias Jido.Chat.Mention

  @handle_pattern ~r/(?:^|[^\p{L}\p{N}_])@([A-Za-z][A-Za-z0-9_]*(?:[.-][A-Za-z0-9_]+)*)/u
  @default_limit 500

  def metadata(body, opts \\ []) do
    mentions = parse(body, opts)

    %{
      mentions: user_ids_from_mentions(mentions),
      mention_handles: mention_handles(mentions)
    }
  end

  def mentioned_user_ids(body, opts \\ []) do
    body
    |> parse(opts)
    |> user_ids_from_mentions()
  end

  def parse(body, opts \\ []) do
    participants_by_handle = participant_index(opts)

    body
    |> mention_tokens()
    |> Enum.reduce([], fn token, acc ->
      case Map.get(participants_by_handle, token.handle) do
        nil -> acc
        participant -> [to_mention(token, participant) | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq_by(&{&1.user_id, mention_offset(&1)})
  end

  defp mention_tokens(body) do
    body = to_string(body)

    Regex.scan(@handle_pattern, body, return: :index)
    |> Enum.flat_map(fn
      [{_match_offset, _match_length}, {handle_offset, handle_length}] ->
        mention_offset = handle_offset - 1
        mention_length = handle_length + 1
        handle = binary_part(body, handle_offset, handle_length)

        [
          %{
            handle: normalize_handle(handle),
            mention_text: binary_part(body, mention_offset, mention_length),
            offset: mention_offset,
            length: mention_length
          }
        ]

      _other ->
        []
    end)
  end

  defp participant_index(opts) do
    opts
    |> participants()
    |> Enum.reduce(%{}, fn participant, acc ->
      participant
      |> participant_handles()
      |> Enum.reduce(acc, &Map.put_new(&2, &1, participant))
    end)
  end

  defp participants(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    case Messaging.directory_search(:participant, %{}, limit: limit) do
      {:ok, participants} -> Enum.filter(participants, &mentionable?/1)
      {:error, _reason} -> []
    end
  end

  defp mentionable?(participant), do: participant.type in [:human, :agent]

  defp participant_handles(participant) do
    identity = participant.identity || %{}
    metadata = participant.metadata || %{}

    [
      metadata_value(identity, :handle),
      metadata_value(metadata, :handle),
      first_name(metadata_value(identity, :name)),
      first_name(metadata_value(identity, :display_name)),
      participant.id
    ]
    |> Kernel.++(List.wrap(metadata_value(identity, :mention_handles)))
    |> Kernel.++(List.wrap(metadata_value(metadata, :mention_handles)))
    |> Enum.map(&normalize_handle/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp to_mention(token, participant) do
    identity = participant.identity || %{}

    Mention.new(%{
      user_id: participant.id,
      username: token.handle,
      display_name: metadata_value(identity, :name),
      mention_text: token.mention_text,
      metadata: %{offset: token.offset, length: token.length}
    })
  end

  defp user_ids_from_mentions(mentions) do
    mentions
    |> Enum.map(& &1.user_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp mention_handles(mentions) do
    mentions
    |> Enum.map(& &1.username)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp mention_offset(%Mention{metadata: metadata}) do
    metadata[:offset] || metadata["offset"] || 0
  end

  defp first_name(nil), do: nil

  defp first_name(value) do
    value
    |> to_string()
    |> String.split(~r/[^a-zA-Z0-9_.-]+/, trim: true)
    |> List.first()
  end

  defp normalize_handle(nil), do: ""

  defp normalize_handle(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("@")
    |> String.downcase()
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_metadata, _key), do: nil
end
