defmodule Jido.Assembly.AgentsTest do
  use ExUnit.Case, async: false

  alias Jido.Assembly.{Agents, Chat, Messaging}

  @ops_room "room:ops-workflow"
  @agent_names ["Triage Agent", "Bridge Agent", "Runbook Agent"]
  @agent_ids ["agent:triage", "agent:bridge", "agent:runbook"]

  setup do
    app_key = Application.get_env(:req_llm, :anthropic_api_key)
    env_key = System.get_env("ANTHROPIC_API_KEY")

    Application.delete_env(:req_llm, :anthropic_api_key)
    System.delete_env("ANTHROPIC_API_KEY")

    on_exit(fn ->
      restore_app_key(app_key)
      restore_env_key(env_key)
    end)

    :ok
  end

  test "snapshot exposes the three seeded Jido AI participants" do
    snapshot = Agents.snapshot()

    assert Enum.map(snapshot.agents, & &1.name) == @agent_names
    assert snapshot.model == "anthropic:claude-haiku-4-5"
    assert snapshot.safety.max_agents_per_round == 3
    assert snapshot.safety.max_rounds_per_prompt == 2
    assert snapshot.missing_api_key
  end

  test "run_round refuses to run without an Anthropic API key" do
    assert {:error, :missing_api_key} = Agents.run_round(@ops_room)
  end

  test "run_round requires the safety cap even with a test responder" do
    assert {:error, :safety_required} =
             Agents.run_round(@ops_room,
               safety_enabled: false,
               responder: fn agent, _room, _transcript -> {:ok, "#{agent.name} ready."} end
             )
  end

  test "run_round writes bounded agent replies through the Assembly chat context" do
    {room, prompt} = prompted_room!("How should these agents answer?")

    responder = fn agent, _room, transcript ->
      {:ok,
       "#{agent.name} sees #{Enum.count(transcript)} prior messages and adds one bounded reply."}
    end

    assert {:ok, result} =
             Agents.run_round(room.id,
               responder: responder,
               prompt_message_id: prompt.id,
               safety_enabled: true,
               inter_agent_enabled: true
             )

    assert Enum.map(result.messages, & &1.author) == @agent_names
    assert result.prompt_message_id == prompt.id
    assert result.round_index == 1
    assert result.round_limit == 2
    assert Enum.count(result.signals) == 3

    for message <- result.messages do
      assert message.room_id == room.id
      assert message.sender_id in @agent_ids

      assert {:ok, persisted} = Messaging.get_message(message.id)
      assert persisted.role == :assistant
      assert persisted.metadata.source == "jido_ai"
      assert is_binary(persisted.metadata.agent_round_id)
      assert persisted.metadata.agent_prompt_message_id == prompt.id
    end

    assert Enum.any?(
             Chat.list_message_views(room.id),
             &(&1.id == List.last(result.messages).id)
           )
  end

  test "run_round can keep agent turns out of later agent context" do
    {room, prompt} = prompted_room!("Answer without chaining agents.")
    parent = self()

    responder = fn agent, _room, transcript ->
      send(parent, {:agent_transcript, agent.name, Enum.count(transcript)})
      {:ok, "#{agent.name} replies without using the other agent turns."}
    end

    assert {:ok, result} =
             Agents.run_round(room.id,
               responder: responder,
               prompt_message_id: prompt.id,
               safety_enabled: true,
               inter_agent_enabled: false
             )

    assert Enum.count(result.messages) == 3

    assert_receive {:agent_transcript, "Triage Agent", count}
    assert_receive {:agent_transcript, "Bridge Agent", ^count}
    assert_receive {:agent_transcript, "Runbook Agent", ^count}
  end

  test "run_round defaults to the latest human prompt" do
    {room, _first_prompt} = prompted_room!("First prompt should not anchor the round.")

    assert {:ok, second_prompt, _signals} =
             Chat.send_message_command(
               room.id,
               "Second prompt should anchor the round.",
               Chat.current_user_id()
             )

    parent = self()

    responder = fn agent, _room, transcript ->
      if agent.name == "Triage Agent" do
        send(parent, {:triage_transcript, Enum.map(transcript, & &1.body)})
      end

      {:ok, "#{agent.name} answers the latest prompt."}
    end

    assert {:ok, result} =
             Agents.run_round(room.id,
               responder: responder,
               safety_enabled: true,
               inter_agent_enabled: true
             )

    assert result.prompt_message_id == second_prompt.id
    assert_receive {:triage_transcript, bodies}
    assert Enum.any?(bodies, &String.contains?(&1, "Second prompt"))
    refute Enum.any?(bodies, &String.contains?(&1, "First prompt"))
  end

  test "run_round enforces a round limit per human prompt" do
    {room, prompt} = prompted_room!("Only one continuation is allowed.")

    responder = fn agent, _room, _transcript ->
      {:ok, "#{agent.name} answers once."}
    end

    assert {:ok, result} =
             Agents.run_round(room.id,
               responder: responder,
               prompt_message_id: prompt.id,
               round_limit: 1,
               safety_enabled: true
             )

    assert result.round_index == 1
    assert result.round_limit == 1

    assert {:error, {:round_limit_reached, 1}} =
             Agents.run_round(room.id,
               responder: responder,
               prompt_message_id: prompt.id,
               round_limit: 1,
               safety_enabled: true
             )
  end

  defp prompted_room!(prompt) do
    name = "agent-test-#{System.unique_integer([:positive])}"

    assert {:ok, room, _messages, _signals} =
             Chat.create_channel_command(%{name: name, topic: "Agent test room."})

    assert {:ok, prompt_message, _signals} =
             Chat.send_message_command(room.id, prompt, Chat.current_user_id())

    {room, prompt_message}
  end

  defp restore_app_key(nil), do: Application.delete_env(:req_llm, :anthropic_api_key)
  defp restore_app_key(value), do: Application.put_env(:req_llm, :anthropic_api_key, value)

  defp restore_env_key(nil), do: System.delete_env("ANTHROPIC_API_KEY")
  defp restore_env_key(value), do: System.put_env("ANTHROPIC_API_KEY", value)
end
