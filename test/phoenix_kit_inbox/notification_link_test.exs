defmodule PhoenixKitInbox.NotificationLinkTest do
  @moduledoc """
  The host's `config :phoenix_kit_inbox, notification_link: {Mod, :fun}`
  picks where a reader's in-app notification of a received message leads;
  without it, or when it answers anything but a raw path, the link stays the
  module's own. Global application env, hence not async.
  """

  use PhoenixKitInbox.DataCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Paths

  defmodule Links do
    @moduledoc false

    # Sends the test process what it was asked, then answers from the
    # application env the test set.
    def link(message, mailbox, reader_uuid) do
      send(
        Application.get_env(:phoenix_kit_inbox, :link_test_pid),
        {:asked, message.uuid, mailbox.uuid, reader_uuid}
      )

      case Application.get_env(:phoenix_kit_inbox, :link_test_answer) do
        fun when is_function(fun, 1) -> fun.(reader_uuid)
        answer -> answer
      end
    end

    def broken(_message, _mailbox, _reader_uuid), do: raise("link blew up")
    def exits(_message, _mailbox, _reader_uuid), do: exit(:gone)
    def throws(_message, _mailbox, _reader_uuid), do: throw(:gone)
  end

  setup do
    enable_inbox!()
    alice = user_fixture()
    bob = user_fixture()
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)

    Application.put_env(:phoenix_kit_inbox, :link_test_pid, self())

    on_exit(fn ->
      Enum.each(
        [:notification_link, :link_test_pid, :link_test_answer],
        &Application.delete_env(:phoenix_kit_inbox, &1)
      )
    end)

    %{alice: alice, bob: bob, alice_mb: alice_mb, bob_mb: bob_mb}
  end

  defp send_to_bob(ctx) do
    {:ok, message} =
      Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
        "to" => ctx.bob.email,
        "subject" => "Ping"
      })

    message
  end

  defp hook(fun, answer) do
    Application.put_env(:phoenix_kit_inbox, :notification_link, {Links, fun})
    Application.put_env(:phoenix_kit_inbox, :link_test_answer, answer)
  end

  defp links(message_uuid) do
    from(a in "phoenix_kit_activities",
      where:
        a.action == "inbox.message_received" and
          a.resource_uuid == type(^message_uuid, :binary_id),
      select: {type(a.target_uuid, :binary_id), a.metadata}
    )
    |> Repo.all()
    |> Map.new(fn {target, metadata} -> {target, metadata["notification_link"]} end)
  end

  test "without a host hook the link opens the message in the reader's mailbox", ctx do
    message = send_to_bob(ctx)

    assert links(message.uuid) == %{
             ctx.bob.uuid => Paths.raw_message_path(ctx.bob_mb.uuid, message.uuid)
           }
  end

  test "the host's path is the link; the hook gets the message, the mailbox and the reader",
       ctx do
    hook(:link, "/portal/letters?x=1")
    message = send_to_bob(ctx)

    assert_received {:asked, message_uuid, mailbox_uuid, reader_uuid}

    assert {message_uuid, mailbox_uuid, reader_uuid} ==
             {message.uuid, ctx.bob_mb.uuid, ctx.bob.uuid}

    assert links(message.uuid) == %{ctx.bob.uuid => "/portal/letters?x=1"}
  end

  test "asked per reader: each reader of a shared mailbox gets his own answer", ctx do
    carol = user_fixture()
    shared = shared_mailbox_fixture(carol, %{name: "Ops"})
    grant_fixture(shared, ctx.bob, "read")
    bob_uuid = ctx.bob.uuid
    hook(:link, fn reader -> if reader == bob_uuid, do: "/portal/letters" end)

    {:ok, message} =
      Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{"to" => "ops", "subject" => "Ping"})

    assert links(message.uuid) == %{
             bob_uuid => "/portal/letters",
             carol.uuid => Paths.raw_message_path(shared.uuid, message.uuid)
           }
  end

  test "an answer that is no path on this site keeps the module's link", ctx do
    for answer <- [
          nil,
          :default,
          "",
          "portal/letters",
          "//evil.example/x",
          "/\\evil.example/x",
          "/\t/evil.example/x",
          "/\n/evil.example/x",
          "/portal\r\nletters",
          "https://evil.example/x",
          42
        ] do
      hook(:link, answer)
      {message, log} = with_log(fn -> send_to_bob(ctx) end)

      if answer, do: assert(log =~ "notification_link"), else: refute(log =~ "notification_link")

      assert links(message.uuid) == %{
               ctx.bob.uuid => Paths.raw_message_path(ctx.bob_mb.uuid, message.uuid)
             },
             "answer #{inspect(answer)}"
    end
  end

  test "a hook that raises, exits or throws keeps the module's link and the message", ctx do
    for fun <- [:broken, :exits, :throws] do
      Application.put_env(:phoenix_kit_inbox, :notification_link, {Links, fun})

      {message, log} = with_log(fn -> send_to_bob(ctx) end)

      assert log =~ "notification_link"

      assert links(message.uuid) == %{
               ctx.bob.uuid => Paths.raw_message_path(ctx.bob_mb.uuid, message.uuid)
             }
    end
  end
end
