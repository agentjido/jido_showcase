defmodule Jido.Assembly.LiveProviderAcceptanceTest do
  use Jido.Assembly.HologramPageCase, async: false

  alias Jido.Assembly.{Bridges, Chat, ChatRuntime, ChatStorage, LiveProviderSetup}
  alias Jido.Assembly.ChatConnections.EnvironmentResolver
  alias Jido.Assembly.Pages.Assembly
  alias Jido.Assembly.{ReleaseNotes, Seeds}
  alias Jido.Assembly.ReleaseNotes.Publication
  alias Jido.Chat, as: ChatSDK
  alias Jido.Chat.Client
  alias Jido.Chat.Runtime.Room.Reaction

  @moduletag :assembly_live
  @moduletag timeout: 210_000

  @telegram %{
    name: "Telegram",
    source: "telegram",
    definition: "assembly.telegram.v1",
    adapter: Jido.Chat.Telegram.Adapter,
    secret_refs: %{"token" => "TELEGRAM_BOT_TOKEN"},
    target: "TELEGRAM_TEST_CHAT_ID",
    target_pattern: ~r/^-?[1-9]\d*$/,
    reply_command: "Reply"
  }

  @discord %{
    name: "Discord",
    source: "discord",
    definition: "assembly.discord.v1",
    adapter: Jido.Chat.Discord.Adapter,
    secret_refs: %{"token" => "DISCORD_BOT_TOKEN"},
    target: "DISCORD_TEST_CHANNEL_ID",
    target_pattern: ~r/^[1-9]\d*$/,
    reply_command: "Reply in the channel"
  }

  @slack %{
    name: "Slack",
    source: "slack",
    definition: "assembly.slack.v1",
    adapter: Jido.Chat.Slack.Adapter,
    secret_refs: %{"bot_token" => "SLACK_BOT_TOKEN", "app_token" => "SLACK_APP_TOKEN"},
    target: "SLACK_TEST_CHANNEL_ID",
    target_pattern: ~r/^[CG][A-Z0-9]+$/,
    reply_command: "Reply in thread"
  }

  @telegram_file_source Map.put(@telegram, :requires_operator, false)
  @x_attachment_fallback %{
    source: "x",
    definition: "assembly.x.v1",
    adapter: Jido.Chat.X.Adapter,
    secret_refs: %{},
    target: "X_TEST_RECIPIENT_ID",
    target_pattern: ~r/^[1-9]\d*$/,
    requires_operator: false
  }

  for {id, provider} <- [{"LV06", @telegram}, {"LV07", @discord}, {"LV08", @slack}] do
    provider = Map.put(provider, :requires_operator, false)

    @tag provider_probe: id
    @tag skip: LiveProviderSetup.blocker(provider)
    test "#{id} saves an outbound #{provider.name} receipt and removes the test message" do
      provider = unquote(Macro.escape(provider))
      relay = send_relay_root(unquote(id), provider, direction: :outbound)
      assert {:ok, work} = ChatStorage.list_work(ChatStorage, relay.account, status: :completed)

      assert [%{result: %{"result" => %{"id" => receipt}}}] =
               Enum.filter(work, &(&1.kind == :outbound and &1.local_message_id == relay.root))

      assert receipt == relay.external_root

      record_probe(unquote(id), %{root_id: relay.root, external_message_id: receipt})
    end
  end

  @tag scenario: "LV06"
  @tag skip: LiveProviderSetup.blocker(@telegram)
  test "Telegram delivers the Assembly root and relays a human reply to both Assembly users" do
    run_relay("LV06", @telegram)
  end

  @tag scenario: "LV07"
  @tag skip: LiveProviderSetup.blocker(@discord)
  test "Discord preserves the provider message reference in the Assembly thread" do
    run_relay("LV07", @discord)
  end

  @tag scenario: "LV08"
  @tag skip: LiveProviderSetup.blocker(@slack)
  test "Slack Socket Mode links the human reply to the exact provider thread" do
    run_relay("LV08", @slack)
  end

  @discord_outbound Map.put(@discord, :requires_operator, false)
  @tag provider_probe: "LV09"
  @tag skip: LiveProviderSetup.blocker(@discord_outbound)
  test "LV09 uploads and downloads exact bytes and receives Discord reaction acknowledgments" do
    reply = send_discord_attachment(@discord_outbound, direction: :outbound)
    client = provider_client(@discord_outbound)

    assert {:ok, %{data: %{"result" => %{"acknowledged" => true}}}} =
             ChatSDK.add_reaction(client, reply.target, reply.receipt, "👍")

    assert {:ok, %{data: %{"result" => %{"acknowledged" => true}}}} =
             ChatSDK.remove_reaction(client, reply.target, reply.receipt, "👍")

    record_probe("LV09", %{
      attachment_id: reply.attachment,
      external_message_id: reply.receipt,
      attachment_bytes: reply.size,
      reaction_acknowledgments: 2
    })
  end

  @tag scenario: "LV09"
  @tag skip: LiveProviderSetup.blocker(@discord)
  test "Discord retains the attachment bytes and maps a human reaction to its exact record" do
    %{room: room, caption: caption, attachment: attachment, receipt: receipt, size: size} =
      send_discord_attachment(@discord, [])

    IO.puts("LV09: Add 👍 to \"#{caption}\" in the dedicated Discord test channel.")

    reaction =
      await!("Discord reaction", 80_000, fn ->
        assert {:ok, reactions} = ChatRuntime.list_room_reactions(room, message_id: attachment)
        Enum.find(reactions, &(&1.reaction == "+1" and &1.status == :active))
      end)

    assert {:ok, %{reactions: [%{emoji: "+1", count: 1}]}} =
             Chat.get_message_view(attachment, "user:eli")

    actor = Reaction.actor(reaction)
    IO.puts("LV09: Remove your 👍 from \"#{caption}\".")

    assert %{status: :removed, revision: 2} =
             await!("Discord reaction removal", 80_000, fn ->
               assert {:ok, reaction} =
                        ChatRuntime.get_room_reaction(room, attachment, "+1", actor)

               if match?(%{status: :removed}, reaction), do: reaction
             end)

    assert {:ok, %{reactions: []}} = Chat.get_message_view(attachment, "user:eli")

    record_evidence("LV09", %{
      attachment_id: attachment,
      external_message_id: receipt,
      attachment_bytes: size,
      reaction_revision: 2
    })
  end

  @tag provider_probe: "LV10"
  @tag skip: LiveProviderSetup.blocker(@discord_outbound)
  test "LV10 publishes a reviewed fixture note once to the dedicated Discord channel" do
    discord = System.fetch_env!(@discord.target)
    nonce = nonce()
    relay = "acceptance:LV10:discord:#{nonce}"
    assert {:ok, %{id: intake}, _} = Chat.create_channel(%{name: "LV10-#{nonce}"})

    assert {:ok, %{id: root, permalink: root_link}} =
             Chat.send_message(intake, "Release acceptance #{nonce}", "user:maya")

    assert {:ok, %{id: evidence, permalink: evidence_link}} =
             Chat.send_message(intake, "The release smoke test passed.", "user:eli",
               thread_id: root,
               reply_to_id: root
             )

    start_provider(@discord_outbound, relay, Seeds.release_log_room_id(), discord,
      direction: :outbound
    )

    result = publish_reviewed_release(relay, discord, root_link, evidence_link, nonce)

    record_probe(
      "LV10",
      Map.merge(result, %{fixture_root_id: root, fixture_evidence_id: evidence})
    )
  end

  @tag scenario: "LV10"
  @tag timeout: 320_000
  @tag skip: LiveProviderSetup.blocker(@telegram) || LiveProviderSetup.blocker(@discord)
  test "Telegram and Discord contribute exact evidence before one reviewed result is published" do
    telegram = System.fetch_env!(@telegram.target)
    discord = System.fetch_env!(@discord.target)
    nonce = nonce()
    origin = "acceptance:LV10:telegram:#{nonce}"
    relay = "acceptance:LV10:discord:#{nonce}"
    request = "Assembly LV10 release intake #{nonce}"
    finding = "Evidence #{nonce} confirms the release smoke test."

    assert {:ok, %{id: intake}, _} = Chat.create_channel(%{name: "LV10-#{nonce}"})
    start_provider(@telegram, origin, intake, telegram, direction: :inbound)
    start_provider(@discord, relay, intake, discord)

    IO.puts(
      "LV10: Post \"#{request}\" in the dedicated Telegram test chat. Remove it after the check."
    )

    assert %{id: root, permalink: root_link} =
             await!("Telegram release request", 120_000, fn ->
               Enum.find(Chat.list_message_views(intake, "user:maya"), &(&1.body == request))
             end)

    assert %{direction: :inbound} = provider_link(origin, root, telegram)

    assert %{direction: :outbound, external_message_id: relayed_root} =
             await!("Discord release request receipt", 20_000, fn ->
               provider_link(relay, root, discord)
             end)

    on_exit(fn -> delete_test_message(@discord, discord, relayed_root) end)

    IO.puts(
      "LV10: Have the Discord participant reply to \"#{request}\" with \"#{finding}\". " <>
        "Remove the reply after the check."
    )

    assert %{id: evidence, permalink: evidence_link, reply_to_id: ^root} =
             await!("Discord release evidence", 120_000, fn ->
               Enum.find(Chat.list_thread_views(intake, root, "user:eli"), &(&1.body == finding))
             end)

    assert %{direction: :inbound} = provider_link(relay, evidence, discord)

    destination = Seeds.release_log_room_id()

    assert {:ok, %{room_id: ^destination}} =
             Bridges.bind(relay, destination, discord, direction: :outbound)

    result = publish_reviewed_release(relay, discord, root_link, evidence_link, nonce)
    record_evidence("LV10", Map.merge(result, %{intake_root_id: root, evidence_id: evidence}))
  end

  defp publish_reviewed_release(relay, discord, root_link, evidence_link, nonce) do
    destination = Seeds.release_log_room_id()
    assert {:ok, before} = ChatRuntime.list_room_history(destination)

    assert {:ok, %{id: local_root}, _signals} =
             ReleaseNotes.request_from_chat(
               Seeds.release_room_id(),
               "user:maya",
               "@triage Prepare the release note using [the request](#{root_link}) " <>
                 "and [the test evidence](#{evidence_link})."
             )

    version = review_mixed_release(local_root, root_link, evidence_link, nonce)
    proposal = Publication.proposal_id(version.id)
    approval = Publication.approval_id(proposal)
    post = Publication.destination_message_id(approval)

    assert {:ok, %{id: ^proposal}} =
             release_action(
               "maya",
               "propose_publish",
               local_root,
               ReleaseNotes.message_anchor(version.id)
             )

    assert {:ok, ^before} = ChatRuntime.list_room_history(destination)
    assert {:ok, []} = ChatRuntime.bridge_links(relay, post)

    assert {:error, :stale_action} =
             release_action(
               "eli",
               "approve_publish",
               local_root,
               ReleaseNotes.message_anchor(proposal)
             )

    assert {:ok, _} =
             release_action(
               "maya",
               "approve_publish",
               local_root,
               ReleaseNotes.message_anchor(proposal)
             )

    assert %{direction: :outbound, external_message_id: published} =
             await!("approved Discord release receipt", 20_000, fn ->
               provider_link(relay, post, discord)
             end)

    on_exit(fn -> delete_test_message(@discord, discord, published) end)

    assert {:ok, %{body: body}} = Chat.get_message_view(post, "user:eli")
    assert body == version.body
    assert {:ok, after_publication} = ChatRuntime.list_room_history(destination)
    assert Enum.map(after_publication -- before, & &1.message_id) == [post]

    assert {:ok, work} = ChatStorage.list_work(ChatStorage, relay, status: :completed)

    assert [%{result: %{"result" => %{"id" => ^published, "text" => ^body}}}] =
             Enum.filter(work, &(&1.kind == :outbound and &1.local_message_id == post))

    %{
      review_root_id: local_root,
      version_id: version.id,
      approval_id: approval,
      published_id: post,
      external_message_id: published
    }
  end

  @tag provider_probe: "LV11"
  @tag skip: LiveProviderSetup.blocker(@telegram_file_source)
  test "LV11 verifies bytes from the supported Telegram attachment route" do
    telegram = System.fetch_env!(@telegram.target)
    nonce = nonce()
    account = "acceptance:LV11:telegram:#{nonce}"

    assert {:ok, %{id: room}, _} = Chat.create_channel(%{name: "LV11-#{nonce}"})
    start_provider(@telegram_file_source, account, room, telegram, direction: :outbound)

    result = send_telegram_attachment(room, account, telegram, nonce)

    record_probe("LV11", %{
      attachment_id: result.attachment,
      external_message_id: result.receipt,
      attachment_bytes: result.size
    })
  end

  @tag scenario: "LV11"
  @tag skip:
         LiveProviderSetup.blocker(@telegram_file_source) ||
           LiveProviderSetup.blocker(@x_attachment_fallback)
  test "Telegram sends the file and the configured X destination records its unsupported fallback" do
    telegram = System.fetch_env!(@telegram.target)
    x = System.fetch_env!(@x_attachment_fallback.target)
    nonce = nonce()
    sending_account = "acceptance:LV11:telegram:#{nonce}"
    skipped_account = "acceptance:LV11:x:#{nonce}"
    assert {:ok, %{id: room}, _} = Chat.create_channel(%{name: "LV11-#{nonce}"})
    start_provider(@telegram_file_source, sending_account, room, telegram, direction: :outbound)
    start_provider(@x_attachment_fallback, skipped_account, room, x, direction: :outbound)

    assert ChatSDK.capabilities(provider_client(@x_attachment_fallback))[:send_file] ==
             :unsupported

    %{attachment: attachment, receipt: receipt, filename: filename, size: size} =
      send_telegram_attachment(room, sending_account, telegram, nonce)

    assert %{status: :failed, delivery_route: :attachment_skipped} =
             skipped =
             await!("X fallback", 5_000, fn ->
               assert {:ok, work} = ChatStorage.message_deliveries(attachment)
               Enum.find(work, &(&1.account_id == skipped_account))
             end)

    refute Map.has_key?(skipped, :signal)
    assert {:ok, []} = ChatRuntime.bridge_links(skipped_account, attachment)

    assert {:ok,
            %{
              attachments: [%{filename: ^filename, size_bytes: ^size}],
              bridge_deliveries: deliveries
            }} =
             Chat.get_message_view(attachment, "user:eli")

    assert %{status: "Delivered"} = Enum.find(deliveries, &(&1.provider == "Telegram"))

    assert %{status: "Skipped", detail: "Attachment delivery unsupported"} =
             Enum.find(deliveries, &(&1.provider == "X"))

    record_evidence("LV11", %{
      attachment_id: attachment,
      external_message_id: receipt,
      fallback_work_id: skipped.id,
      fallback: skipped.delivery_route
    })
  end

  defp review_mixed_release(root, root_link, evidence_link, nonce) do
    assert {:ok, %{id: draft}} =
             release_action("maya", "decide", root, ReleaseNotes.decision_anchor(root), %{
               "choice" => "document"
             })

    assert {:ok, version} =
             release_action("eli", "revise", root, ReleaseNotes.message_anchor(draft), %{
               "body" =>
                 "Release #{nonce}: the smoke test passed. [Request](#{root_link}). " <>
                   "[Test evidence](#{evidence_link})."
             })

    assert {:ok, %{reply_to_id: reviewed}} =
             release_action("maya", "review", root, ReleaseNotes.message_anchor(version.id))

    assert reviewed == version.id
    version
  end

  defp release_action(person, operation, root, target, attrs \\ %{}) do
    ReleaseNotes.submit(
      person,
      Map.merge(attrs, %{"operation" => operation, "root" => root, "target" => target})
    )
  end

  defp run_relay(scenario, provider) do
    %{
      nonce: nonce,
      account: account,
      room: room,
      target: target,
      root_text: root_text,
      root: root,
      external_root: external_root
    } = send_relay_root(scenario, provider, [])

    reply_text = "Reply #{nonce}"

    IO.puts(
      "#{scenario}: In the dedicated #{provider.name} test target, use #{provider.reply_command} " <>
        "on \"#{root_text}\" " <>
        "with \"#{reply_text}\". Remove your reply after the check."
    )

    assert %{id: reply} =
             await!("operator reply", 170_000, fn ->
               Enum.find(
                 Chat.list_thread_views(room, root, "user:maya"),
                 &(&1.body == reply_text)
               )
             end)

    assert {:ok, record} = ChatRuntime.get_room_history(room, reply)

    assert %{
             thread_id: ^root,
             reply_to_id: ^root,
             content: [%{kind: :text, text: ^reply_text}],
             metadata: %{
               "jido_chat_origin" => %{
                 "account_id" => ^account,
                 "external_room_id" => ^target,
                 "external_message_id" => external_reply
               }
             }
           } = Chat.message_record(record)

    assert %{external_message_id: ^external_reply, direction: :inbound} =
             reply_link =
             await!("inbound provider receipt", 5_000, fn ->
               provider_link(account, reply, target)
             end)

    refute external_reply == external_root
    if provider.source == "slack", do: assert(reply_link.external_thread_id == external_root)

    source = provider.source
    provider_name = provider.name

    for user <- ["user:maya", "user:eli"] do
      session = "acceptance:#{scenario}:#{nonce}:#{user}"

      {page, _server} =
        init_page(Assembly, %{},
          user_id: user,
          session_id: session,
          instance_id: session,
          query: %{"room" => room, "message" => reply}
        )

      assert %{
               current_user: %{id: ^user},
               focused_message_id: ^reply,
               thread_root: %{
                 id: ^root,
                 body: ^root_text,
                 bridge_deliveries: [
                   %{provider: ^provider_name, status: "Delivered", external_room_id: ^target}
                 ]
               },
               thread_messages: replies
             } = page.state

      assert [%{id: ^reply, body: ^reply_text, source: "adapter", channel: ^source}] =
               Enum.filter(replies, &(&1.body == reply_text))
    end

    record_evidence(scenario, %{
      room_id: room,
      root_id: root,
      reply_id: reply,
      external_root_id: external_root,
      external_reply_id: external_reply
    })
  end

  defp send_relay_root(scenario, provider, opts) do
    nonce = nonce()
    account = "acceptance:#{scenario}:#{nonce}"
    target = System.fetch_env!(provider.target)
    root_text = "Assembly #{scenario} acceptance #{nonce}"

    assert {:ok, %{id: room}, _messages} = Chat.create_channel(%{name: "#{scenario}-#{nonce}"})
    start_provider(provider, account, room, target, opts)

    assert {:ok, %{id: root}} = Chat.send_message(room, root_text, "user:maya")

    assert %{external_message_id: external_root, direction: :outbound} =
             await!("outbound provider receipt", 20_000, fn ->
               provider_link(account, root, target)
             end)

    on_exit(fn -> delete_test_message(provider, target, external_root) end)

    %{
      nonce: nonce,
      account: account,
      room: room,
      target: target,
      root_text: root_text,
      root: root,
      external_root: external_root
    }
  end

  defp send_discord_attachment(provider, opts) do
    target = System.fetch_env!(provider.target)
    nonce = nonce()
    account = "acceptance:LV09:#{nonce}"
    caption = "Assembly LV09 acceptance #{nonce}"
    filename = "assembly-#{nonce}.txt"
    bytes = "Assembly attachment check #{nonce}\n"
    size = byte_size(bytes)

    assert {:ok, %{id: room}, _} = Chat.create_channel(%{name: "LV09-#{nonce}"})
    start_provider(provider, account, room, target, opts)

    assert {:ok, %{id: attachment}} =
             Chat.send_attachment(
               room,
               %{filename: filename, media_type: "text/plain", bytes: bytes},
               "user:maya",
               caption: caption
             )

    assert %{external_message_id: receipt, direction: :outbound} =
             await!("Discord attachment receipt", 20_000, fn ->
               provider_link(account, attachment, target)
             end)

    on_exit(fn -> delete_test_message(provider, target, receipt) end)

    assert {:ok, work} = ChatStorage.list_work(ChatStorage, account, status: :completed)

    assert [%{result: %{"result" => %{"id" => ^receipt, "media" => [media]}}}] =
             Enum.filter(work, &(&1.kind == :outbound and &1.local_message_id == attachment))

    assert %{"name" => ^filename, "resource_ref" => ref} = media
    encoded = Base.encode64(bytes)

    assert {:ok, %{data: %{"result" => %{"content_base64" => ^encoded}}}} =
             ChatSDK.download_file(provider_client(provider), ref)

    assert {:ok, %{attachments: [%{filename: ^filename, size_bytes: ^size}]}} =
             Chat.get_message_view(attachment, "user:eli")

    %{
      room: room,
      caption: caption,
      target: target,
      attachment: attachment,
      receipt: receipt,
      size: size
    }
  end

  defp send_telegram_attachment(room, account, target, nonce) do
    filename = "assembly-fallback-#{nonce}.txt"
    bytes = "Assembly attachment fallback #{nonce}\n"
    size = byte_size(bytes)

    assert {:ok, %{id: attachment}} =
             Chat.send_attachment(
               room,
               %{filename: filename, media_type: "text/plain", bytes: bytes},
               "user:maya",
               caption: "Assembly LV11 acceptance #{nonce}"
             )

    assert %{external_message_id: receipt, direction: :outbound} =
             await!("Telegram attachment receipt", 20_000, fn ->
               provider_link(account, attachment, target)
             end)

    on_exit(fn -> delete_test_message(@telegram, target, receipt) end)

    assert {:ok, work} = ChatStorage.list_work(ChatStorage, account, status: :completed)

    assert [%{result: %{"result" => %{"id" => ^receipt, "media" => [media]}}}] =
             Enum.filter(work, &(&1.kind == :outbound and &1.local_message_id == attachment))

    assert %{"kind" => "file", "resource_ref" => ref} = media
    encoded = Base.encode64(bytes)

    assert {:ok, %{data: %{"result" => %{"content_base64" => ^encoded}}}} =
             ChatSDK.download_file(provider_client(@telegram_file_source), ref)

    assert {:ok, %{attachments: [%{filename: ^filename, size_bytes: ^size}]}} =
             Chat.get_message_view(attachment, "user:eli")

    %{attachment: attachment, receipt: receipt, filename: filename, size: size}
  end

  defp record_evidence(scenario, details) do
    IO.puts(Jason.encode!(Map.put(details, :scenario, scenario)))
  end

  defp record_probe(scenario, details) do
    IO.puts(Jason.encode!(Map.put(details, :provider_probe, scenario)))
  end

  defp start_provider(provider, account, room, target, opts \\ []) do
    assert {:ok, _} =
             LiveProviderSetup.with_target(provider, fn ^target ->
               assert {:ok, _} =
                        ChatRuntime.provision_connection(provider.definition, %{
                          account_id: account,
                          desired: :stopped,
                          secret_refs: provider.secret_refs
                        })

               on_exit(fn -> assert :ok = ChatRuntime.deprovision_connection(account) end)
               assert {:ok, _} = Bridges.bind(account, room, target, opts)

               on_exit(fn ->
                 assert {:ok, _} = ChatRuntime.deprovision_bridge_binding(account, target)
               end)

               ChatRuntime.start_managed_connection(account)
             end)
  end

  defp delete_test_message(provider, target, message) do
    # Keep provider errors and request details out of ExUnit output.
    deleted? =
      match?(
        {:ok, %{data: %{"result" => %{"acknowledged" => true}}}},
        ChatSDK.delete_message(provider_client(provider), target, message)
      )

    assert deleted?, "Could not remove the outbound test message."
  end

  defp provider_client(provider) do
    {:ok, credentials} = EnvironmentResolver.resolve(provider.secret_refs, %{})
    Client.new!(provider.adapter, id: "assembly/#{provider.source}", credentials: credentials)
  end

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  defp provider_link(account, message, target) do
    assert {:ok, links} = ChatRuntime.bridge_links(account, message)
    Enum.find(links, &(&1.external_room_id == target))
  end

  defp await!(description, timeout, read) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_value!(description, deadline, read)
  end

  defp await_value!(description, deadline, read) do
    case read.() do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          await_value!(description, deadline, read)
        else
          flunk("Timed out waiting for #{description}.")
        end

      value ->
        value
    end
  end
end
