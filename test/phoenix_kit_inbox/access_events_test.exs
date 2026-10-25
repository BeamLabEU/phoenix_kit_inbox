defmodule PhoenixKitInbox.AccessEventsTest do
  @moduledoc """
  The access events core cannot know about: a write that changes which
  mailboxes a user reaches, or which senders are offered, tells the users
  concerned after it commits — and a refused write tells nobody.
  """

  # The senders topic is global: another test's broadcast would land here.
  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKitInbox.AccessEvents
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Schemas.Identity

  @manage ["inbox", "inbox.manage_shared"]

  setup do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture()
    bob = user_fixture()
    desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})
    grant_fixture(desk, bob, "read")

    %{admin: admin, alice: alice, bob: bob, desk: desk, manage: scope_for(admin, @manage)}
  end

  # A process of its own subscribed by `subscribe`, forwarding what it gets as
  # `{name, message}` — so a test tells apart who received what.
  defp listen(name, subscribe) do
    test = self()

    pid =
      spawn_link(fn ->
        :ok = subscribe.()
        send(test, {:listening, name})
        forward(test, name)
      end)

    assert_receive {:listening, ^name}
    pid
  end

  defp forward(test, name) do
    receive do
      message -> send(test, {name, message})
    end

    forward(test, name)
  end

  # Everything broadcast before this call has reached the listener's mailbox
  # (a broadcast is a send); once the ping comes back, it has been forwarded.
  defp flush(pid, name) do
    send(pid, :ping)
    assert_receive {^name, :ping}
  end

  describe "mailbox access" do
    test "a grant reaches the user it was given to", ctx do
      :ok = AccessEvents.subscribe_user(ctx.alice.uuid)

      {:ok, _} = Mailboxes.grant_access(ctx.manage, ctx.desk, ctx.alice.uuid, "write")

      assert_received {:inbox_access_changed, :mailboxes}
    end

    test "a revoke reaches the user it was taken from", ctx do
      :ok = AccessEvents.subscribe_user(ctx.bob.uuid)

      :ok = Mailboxes.revoke_access(ctx.manage, ctx.desk, ctx.bob.uuid)

      assert_received {:inbox_access_changed, :mailboxes}
    end

    test "archiving and restoring reach the owner and every grant holder", ctx do
      owner = listen(:owner, fn -> AccessEvents.subscribe_user(ctx.admin.uuid) end)
      holder = listen(:holder, fn -> AccessEvents.subscribe_user(ctx.bob.uuid) end)
      other = listen(:other, fn -> AccessEvents.subscribe_user(ctx.alice.uuid) end)

      {:ok, archived} = Mailboxes.archive_mailbox(ctx.manage, ctx.desk)
      {:ok, _} = Mailboxes.restore_mailbox(ctx.manage, archived)

      flush(owner, :owner)
      flush(holder, :holder)
      flush(other, :other)

      for name <- [:owner, :holder] do
        assert_received {^name, {:inbox_access_changed, :mailboxes}}
        assert_received {^name, {:inbox_access_changed, :mailboxes}}
        refute_received {^name, {:inbox_access_changed, _}}
      end

      refute_received {:other, _}
    end

    test "an account deletion reaches who reached the mailboxes it archived or handed over",
         ctx do
      sales = shared_mailbox_fixture(ctx.admin, %{name: "Sales"})
      grant_fixture(sales, ctx.alice, "admin")

      holder = listen(:holder, fn -> AccessEvents.subscribe_user(ctx.bob.uuid) end)
      successor = listen(:successor, fn -> AccessEvents.subscribe_user(ctx.alice.uuid) end)

      :ok = Mailboxes.handle_user_deletion(ctx.admin.uuid)
      flush(holder, :holder)
      flush(successor, :successor)

      # Desk had no admin grantee: archived, so Bob's read grant leads nowhere.
      assert {:ok, %{status: "archived"}} = Mailboxes.fetch_mailbox(ctx.desk.uuid)
      assert_received {:holder, {:inbox_access_changed, :mailboxes}}
      # Sales passed to Alice.
      assert {:ok, %{owner_uuid: owner}} = Mailboxes.fetch_mailbox(sales.uuid)
      assert owner == ctx.alice.uuid
      assert_received {:successor, {:inbox_access_changed, :mailboxes}}
    end

    test "a renamed or readdressed mailbox reaches its grant holders", ctx do
      :ok = AccessEvents.subscribe_user(ctx.bob.uuid)

      {:ok, _} =
        Mailboxes.update_mailbox(ctx.manage, ctx.desk, %{"address" => "help@company.test"})

      assert_received {:inbox_access_changed, :mailboxes}
    end

    test "a new shared mailbox reaches its creator", ctx do
      :ok = AccessEvents.subscribe_user(ctx.admin.uuid)

      {:ok, _} = Mailboxes.create_shared_mailbox(ctx.manage, %{"name" => "Sales"})

      assert_received {:inbox_access_changed, :mailboxes}
    end

    test "a refused write tells nobody", ctx do
      :ok = AccessEvents.subscribe_user(ctx.alice.uuid)
      :ok = AccessEvents.subscribe_user(ctx.bob.uuid)

      assert {:error, _} =
               Mailboxes.grant_access(scope_for(ctx.bob), ctx.desk, ctx.alice.uuid, "write")

      assert {:error, _} = Mailboxes.revoke_access(scope_for(ctx.bob), ctx.desk, ctx.bob.uuid)
      assert {:error, _} = Mailboxes.archive_mailbox(scope_for(ctx.bob), ctx.desk)

      refute_received {:inbox_access_changed, _}
    end

    test "nobody else hears about it", ctx do
      :ok = AccessEvents.subscribe_user(ctx.bob.uuid)

      {:ok, _} = Mailboxes.grant_access(ctx.manage, ctx.desk, ctx.alice.uuid, "write")

      refute_received {:inbox_access_changed, _}
    end
  end

  describe "senders" do
    setup ctx do
      smtp = mail_integration_fixture(:system, username: "noreply@company.test")
      :ok = AccessEvents.subscribe_senders()
      Map.put(ctx, :smtp, smtp)
    end

    test "creating, changing and deleting a shared sender reach every page", ctx do
      {:ok, identity} =
        Identities.create_shared(ctx.manage, %{
          "label" => "Common",
          "integration_uuid" => ctx.smtp
        })

      assert_received {:inbox_access_changed, :senders}

      {:ok, _} = Identities.update_identity(ctx.manage, identity, %{"role_uuids" => []})
      assert_received {:inbox_access_changed, :senders}

      :ok = Identities.delete_identity(ctx.manage, identity)
      assert_received {:inbox_access_changed, :senders}
    end

    test "a refused change tells nobody", ctx do
      {:ok, identity} =
        Identities.create_shared(ctx.manage, %{
          "label" => "Common",
          "integration_uuid" => ctx.smtp
        })

      assert_received {:inbox_access_changed, :senders}

      assert {:error, :forbidden} =
               Identities.update_identity(scope_for(ctx.alice), identity, %{"role_uuids" => []})

      assert {:error, :forbidden} =
               Identities.delete_identity(scope_for(ctx.alice), %Identity{uuid: identity.uuid})

      refute_received {:inbox_access_changed, _}
    end

    test "a personal sender reaches its owner only", ctx do
      owner = listen(:owner, fn -> AccessEvents.subscribe_user(ctx.alice.uuid) end)
      global = listen(:global, &AccessEvents.subscribe_senders/0)
      own = mail_integration_fixture({:user, ctx.alice.uuid})

      {:ok, identity} =
        Identities.create_personal(scope_for(ctx.alice), %{
          "label" => "Mine",
          "integration_uuid" => own
        })

      :ok = Identities.delete_identity(scope_for(ctx.alice), identity)
      flush(owner, :owner)
      flush(global, :global)

      assert_received {:owner, {:inbox_access_changed, :senders}}
      assert_received {:owner, {:inbox_access_changed, :senders}}
      refute_received {:global, _}
    end
  end
end
