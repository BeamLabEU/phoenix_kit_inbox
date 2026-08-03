defmodule PhoenixKitInbox.MessagesTest do
  use PhoenixKitInbox.DataCase, async: true

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages

  setup do
    alice = user_fixture()
    bob = user_fixture()
    carol = user_fixture()

    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    {:ok, carol_mb} = Mailboxes.ensure_user_mailbox(carol)

    %{
      alice: alice,
      bob: bob,
      carol: carol,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      carol_mb: carol_mb
    }
  end

  describe "send_message/3" do
    test "delivers to the recipient's inbox and the sender's sent folder", ctx do
      assert {:ok, message} =
               Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
                 "to" => ctx.bob.email,
                 "subject" => "Hello",
                 "body" => "First message"
               })

      assert message.status == "sent"
      assert message.sent_at

      assert [%{message: received}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      assert received.uuid == message.uuid

      assert [%{message: sent}] = Messages.list_folder(ctx.alice_mb.uuid, "sent")
      assert sent.uuid == message.uuid

      # Nothing landed in the sender's own inbox.
      assert Messages.list_folder(ctx.alice_mb.uuid, "inbox") == []
    end

    test "the recipient's copy starts unseen, the sender's starts seen", ctx do
      {:ok, _} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "subject" => "Unread me"
        })

      assert [%{delivery: received}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      assert is_nil(received.seen_at)

      assert [%{delivery: sent}] = Messages.list_folder(ctx.alice_mb.uuid, "sent")
      assert sent.seen_at
    end

    test "fans out to to/cc/bcc in one send", ctx do
      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "cc" => ctx.carol.email,
          "subject" => "Group"
        })

      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox")) == 1
      assert length(Messages.list_folder(ctx.carol_mb.uuid, "inbox")) == 1

      roles = message.uuid |> Messages.list_recipients() |> Enum.map(& &1.role) |> Enum.sort()
      assert roles == ["cc", "to"]
    end

    test "accepts comma- and semicolon-separated recipient lists", ctx do
      {:ok, _} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => "#{ctx.bob.email}, #{ctx.carol.email}",
          "subject" => "Both"
        })

      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox")) == 1
      assert length(Messages.list_folder(ctx.carol_mb.uuid, "inbox")) == 1
    end

    test "a recipient listed twice gets one copy, keeping the stronger role", ctx do
      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "cc" => ctx.bob.email,
          "subject" => "Once"
        })

      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox")) == 1
      assert [%{role: "to"}] = Messages.list_recipients(message.uuid)
    end

    test "an unknown recipient refuses the whole send", ctx do
      assert {:error, {:unknown_recipients, ["ghost@example.com"]}} =
               Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
                 "to" => "#{ctx.bob.email}, ghost@example.com",
                 "subject" => "Partial"
               })

      # The valid recipient got nothing — the send was atomic.
      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []
      assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
    end

    test "sending with no recipients is refused", ctx do
      assert {:error, :no_recipients} =
               Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{"subject" => "To nobody"})
    end

    test "an entirely blank message is refused", ctx do
      assert {:error, changeset} =
               Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
                 "to" => ctx.bob.email,
                 "subject" => "  ",
                 "body" => ""
               })

      assert %{body: _} = errors_on(changeset)
    end

    test "a root message is its own thread", ctx do
      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "subject" => "Root"
        })

      assert message.thread_uuid == message.uuid
    end

    test "a reply inherits the parent's thread", ctx do
      {:ok, root} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "subject" => "Root"
        })

      {:ok, reply} =
        Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
          "to" => ctx.alice.email,
          "subject" => "Re: Root",
          "parent_uuid" => root.uuid
        })

      assert reply.thread_uuid == root.thread_uuid
      assert reply.uuid != reply.thread_uuid

      assert length(Messages.list_thread(root.thread_uuid)) == 2
    end
  end

  describe "drafts" do
    test "saving creates one delivery in the author's drafts folder", ctx do
      assert {:ok, draft} =
               Messages.save_draft(ctx.alice_mb, ctx.alice.uuid, %{
                 "subject" => "Half written",
                 "body" => "..."
               })

      assert draft.status == "draft"
      assert [%{message: listed}] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")
      assert listed.uuid == draft.uuid
    end

    test "re-saving updates the same message rather than creating another", ctx do
      {:ok, draft} = Messages.save_draft(ctx.alice_mb, ctx.alice.uuid, %{"subject" => "v1"})

      {:ok, updated} =
        Messages.save_draft(ctx.alice_mb, ctx.alice.uuid, %{
          "uuid" => draft.uuid,
          "subject" => "v2"
        })

      assert updated.uuid == draft.uuid
      assert updated.subject == "v2"
      assert length(Messages.list_folder(ctx.alice_mb.uuid, "drafts")) == 1
    end

    test "a draft with no recipients is fine — validation happens at send", ctx do
      assert {:ok, _} = Messages.save_draft(ctx.alice_mb, ctx.alice.uuid, %{"subject" => ""})
    end

    test "sending a draft promotes the same row and empties the drafts folder", ctx do
      {:ok, draft} = Messages.save_draft(ctx.alice_mb, ctx.alice.uuid, %{"subject" => "Ready"})

      {:ok, sent} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "uuid" => draft.uuid,
          "to" => ctx.bob.email,
          "subject" => "Ready"
        })

      assert sent.uuid == draft.uuid
      assert sent.status == "sent"
      assert Messages.list_folder(ctx.alice_mb.uuid, "drafts") == []
      assert length(Messages.list_folder(ctx.alice_mb.uuid, "sent")) == 1
      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox")) == 1
    end

    test "deleting a draft removes it and its delivery", ctx do
      {:ok, draft} = Messages.save_draft(ctx.alice_mb, ctx.alice.uuid, %{"subject" => "Nope"})

      assert :ok = Messages.delete_draft(ctx.alice_mb, draft.uuid)
      assert Messages.list_folder(ctx.alice_mb.uuid, "drafts") == []
    end

    test "you can't delete someone else's draft", ctx do
      {:ok, draft} = Messages.save_draft(ctx.alice_mb, ctx.alice.uuid, %{"subject" => "Mine"})

      assert {:error, :message_not_found} = Messages.delete_draft(ctx.bob_mb, draft.uuid)
    end
  end

  describe "per-mailbox state" do
    setup ctx do
      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => "#{ctx.bob.email}, #{ctx.carol.email}",
          "subject" => "Shared thread",
          "body" => "Body text"
        })

      Map.put(ctx, :message, message)
    end

    test "marking seen in one mailbox doesn't touch the other", ctx do
      assert {:ok, _} = Messages.mark_seen(ctx.bob_mb.uuid, ctx.message.uuid)

      assert [%{delivery: bobs}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      assert bobs.seen_at

      assert [%{delivery: carols}] = Messages.list_folder(ctx.carol_mb.uuid, "inbox")
      assert is_nil(carols.seen_at)
    end

    test "mark_seen is idempotent and keeps the original stamp", ctx do
      {:ok, first} = Messages.mark_seen(ctx.bob_mb.uuid, ctx.message.uuid)
      {:ok, second} = Messages.mark_seen(ctx.bob_mb.uuid, ctx.message.uuid)

      assert first.seen_at == second.seen_at
    end

    test "mark_unseen clears the stamp", ctx do
      {:ok, _} = Messages.mark_seen(ctx.bob_mb.uuid, ctx.message.uuid)
      assert {:ok, delivery} = Messages.mark_unseen(ctx.bob_mb.uuid, ctx.message.uuid)
      assert is_nil(delivery.seen_at)
    end

    test "starring is per mailbox", ctx do
      assert {:ok, %{starred: true}} = Messages.toggle_star(ctx.bob_mb.uuid, ctx.message.uuid)

      assert [%{delivery: %{starred: false}}] = Messages.list_folder(ctx.carol_mb.uuid, "inbox")
    end

    test "moving to trash takes it out of the inbox listing", ctx do
      assert {:ok, _} = Messages.move_to_folder(ctx.bob_mb.uuid, ctx.message.uuid, "trash")

      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []
      assert length(Messages.list_folder(ctx.bob_mb.uuid, "trash")) == 1

      # Carol's copy is untouched.
      assert length(Messages.list_folder(ctx.carol_mb.uuid, "inbox")) == 1
    end

    test "purging removes only this mailbox's copy", ctx do
      assert :ok = Messages.purge(ctx.bob_mb.uuid, ctx.message.uuid)

      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []

      assert {:error, :message_not_found} =
               Messages.fetch_for_mailbox(ctx.bob_mb.uuid, ctx.message.uuid)

      assert length(Messages.list_folder(ctx.carol_mb.uuid, "inbox")) == 1
      assert {:ok, _} = Messages.fetch_for_mailbox(ctx.carol_mb.uuid, ctx.message.uuid)
    end

    test "a mailbox can't read a message it was never sent", ctx do
      stranger = user_fixture()
      {:ok, stranger_mb} = Mailboxes.ensure_user_mailbox(stranger)

      assert {:error, :message_not_found} =
               Messages.fetch_for_mailbox(stranger_mb.uuid, ctx.message.uuid)
    end

    test "unseen counts are per folder", ctx do
      assert %{"inbox" => 1} = Mailboxes.unseen_counts(ctx.bob_mb.uuid)

      {:ok, _} = Messages.mark_seen(ctx.bob_mb.uuid, ctx.message.uuid)
      assert Mailboxes.unseen_counts(ctx.bob_mb.uuid) == %{}
    end
  end

  describe "listing" do
    setup ctx do
      for n <- 1..3 do
        {:ok, _} =
          Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
            "to" => ctx.bob.email,
            "subject" => "Message #{n}",
            "body" => "Body of number #{n}"
          })
      end

      ctx
    end

    test "counts match the listing", ctx do
      assert Messages.count_folder(ctx.bob_mb.uuid, "inbox") == 3
      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox")) == 3
    end

    test "search matches subject and body", ctx do
      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox", search: "Message 2")) == 1
      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox", search: "number 3")) == 1
      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox", search: "Body of")) == 3
      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox", search: "nothing here") == []
    end

    test "a blank search term is ignored rather than matching nothing", ctx do
      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox", search: "   ")) == 3
    end

    test "unseen_only filters read messages out", ctx do
      [%{message: first} | _] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      {:ok, _} = Messages.mark_seen(ctx.bob_mb.uuid, first.uuid)

      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox", unseen_only: true)) == 2
    end

    test "limit and offset paginate", ctx do
      page1 = Messages.list_folder(ctx.bob_mb.uuid, "inbox", limit: 2, offset: 0)
      page2 = Messages.list_folder(ctx.bob_mb.uuid, "inbox", limit: 2, offset: 2)

      assert length(page1) == 2
      assert length(page2) == 1
      assert Enum.map(page1, & &1.message.uuid) != Enum.map(page2, & &1.message.uuid)
    end
  end
end
