defmodule Jido.AssemblyWeb.SignalPresenterTest do
  use ExUnit.Case, async: true

  alias Jido.AssemblyWeb.SignalPresenter

  test "summarizes a signal as a compact Hologram payload" do
    {:ok, signal} =
      Jido.Signal.new(
        "jido.messaging.participant.presence_changed",
        %{
          "participant_id" => "user:maggie",
          "from" => :offline,
          "to" => :online,
          "ignored" => "not for UI payload"
        },
        source: "jido_assembly.presence",
        subject: "room:general"
      )

    assert SignalPresenter.summary(signal) == %{
             id: signal.id,
             type: "jido.messaging.participant.presence_changed",
             source: "jido_assembly.presence",
             subject: "room:general",
             participant_id: "user:maggie",
             from: :offline,
             to: :online
           }
  end

  test "selects the first matching signal type from a list" do
    {:ok, joined} =
      Jido.Signal.new(
        "jido.messaging.room.participant_joined",
        %{participant_id: "user:maggie"},
        source: "test",
        subject: "room:general"
      )

    {:ok, changed} =
      Jido.Signal.new(
        "jido.messaging.participant.presence_changed",
        %{participant_id: "user:maggie"},
        source: "test",
        subject: "room:general"
      )

    assert %{type: "jido.messaging.participant.presence_changed"} =
             SignalPresenter.summary([joined, changed], [
               "jido.messaging.participant.presence_changed",
               "jido.messaging.room.participant_joined"
             ])
  end
end
