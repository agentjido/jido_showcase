defmodule Jido.AssemblyWeb.SignalPresenterTest do
  use ExUnit.Case, async: true

  alias Jido.AssemblyWeb.SignalPresenter

  test "summarizes a signal as a compact Hologram payload" do
    {:ok, signal} =
      Jido.Signal.new(
        "jido.assembly.presence.changed",
        %{
          "user_id" => "user:maggie",
          "from" => "offline",
          "to" => "online",
          "ignored" => "not for UI payload"
        },
        source: "/jido-assembly/presence",
        subject: "room:general"
      )

    assert SignalPresenter.summary(signal) == %{
             id: signal.id,
             type: "jido.assembly.presence.changed",
             source: "/jido-assembly/presence",
             subject: "room:general",
             user_id: "user:maggie",
             from: "offline",
             to: "online"
           }
  end

  test "selects the first matching signal type from a list" do
    {:ok, joined} =
      Jido.Signal.new(
        "jido.assembly.presence.joined",
        %{user_id: "user:maggie"},
        source: "test",
        subject: "room:general"
      )

    {:ok, changed} =
      Jido.Signal.new(
        "jido.assembly.presence.changed",
        %{user_id: "user:maggie"},
        source: "test",
        subject: "room:general"
      )

    assert %{type: "jido.assembly.presence.changed"} =
             SignalPresenter.summary([joined, changed], [
               "jido.assembly.presence.changed",
               "jido.assembly.presence.joined"
             ])
  end
end
