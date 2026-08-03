defmodule PhoenixKitInbox.Web.ComposeLiveTest do
  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages

  setup %{conn: conn} do
    alice = user_fixture()
    bob = user_fixture()

    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)

    conn = put_test_scope(conn, fake_scope(user_uuid: alice.uuid, email: alice.email))

    %{conn: conn, alice: alice, bob: bob, alice_mb: alice_mb, bob_mb: bob_mb}
  end

  test "renders the compose form", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/inbox/compose")

    assert html =~ "To"
    assert html =~ "Subject"
    assert html =~ "Send"
  end

  test "sending delivers the message and redirects to Sent", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> form("form", %{
               "to" => ctx.bob.email,
               "cc" => "",
               "bcc" => "",
               "subject" => "Hi Bob",
               "body" => "How's it going?"
             })
             |> render_submit()

    assert to =~ "folder=sent"

    assert [%{message: message}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
    assert message.subject == "Hi Bob"
  end

  test "an unknown recipient re-renders the form with an error", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

    html =
      view
      |> form("form", %{
        "to" => "nobody@example.com",
        "cc" => "",
        "bcc" => "",
        "subject" => "Lost",
        "body" => "..."
      })
      |> render_submit()

    assert html =~ "No mailbox matches"
    assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
  end

  test "saving a draft keeps it in the drafts folder", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

    view
    |> form("form", %{
      "to" => "",
      "cc" => "",
      "bcc" => "",
      "subject" => "Later",
      "body" => "Unfinished"
    })
    |> render_change()

    view |> element("button[phx-click='save_draft']") |> render_click()

    assert [%{message: draft}] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")
    assert draft.subject == "Later"
    assert draft.status == "draft"
  end

  test "replying prefills the recipient and a Re: subject", ctx do
    {:ok, message} =
      Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
        "to" => ctx.alice.email,
        "subject" => "Original",
        "body" => "Quote this"
      })

    {:ok, _view, html} = live(ctx.conn, "/en/admin/inbox/compose?reply_to=#{message.uuid}")

    assert html =~ "Re: Original"
    assert html =~ ctx.bob.email
    assert html =~ "&gt; Quote this"
  end

  test "forwarding prefills a Fwd: subject and no recipient", ctx do
    {:ok, message} =
      Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
        "to" => ctx.alice.email,
        "subject" => "Original",
        "body" => "Pass it on"
      })

    {:ok, _view, html} = live(ctx.conn, "/en/admin/inbox/compose?forward=#{message.uuid}")

    assert html =~ "Fwd: Original"
    assert html =~ "&gt; Pass it on"
  end

  test "a user without the inbox permission can't compose", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope(permissions: [], roles: []))

    {:ok, _view, html} = live(conn, "/en/admin/inbox/compose")

    assert html =~ "You don&#39;t have permission to use Inbox."
  end
end
