defmodule Jido.Assembly.Chat.Attachments do
  @moduledoc false

  alias Jido.Chat.{Content, FileSource, Media}

  def parts(content) do
    Enum.flat_map(content, fn
      %Content{kind: :media, media: %Media{} = media} -> [media]
      %Content{kind: :file, file: %FileSource{} = file} -> [%Media{kind: :file, source: file}]
      _part -> []
    end)
  end

  def view(%Media{} = media) do
    %{
      filename: media.name || media.source.filename || "Attachment",
      media_type: media.media_type || media.source.media_type || "application/octet-stream",
      size_bytes: (media.metadata || %{})["size_bytes"]
    }
  end
end
