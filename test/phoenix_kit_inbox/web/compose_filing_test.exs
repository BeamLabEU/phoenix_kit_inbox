defmodule PhoenixKitInbox.Web.ComposeFilingTest do
  @moduledoc """
  Compose end to end on a core that links and files: an upload whose bytes
  already lie in Media, a saved draft (its snapshot in `Drafts`), the send
  (the snapshot in the message's own folder). Skipped on a core without
  `Storage.link_copy/3` or managed libraries.
  """

  use PhoenixKitInbox.LiveCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Message
  alias PhoenixKitInbox.Test.Repo

  Code.ensure_loaded(Storage)

  @content "%PDF scanned"

  @moduletag skip:
               if(
                 function_exported?(Storage, :link_copy, 3) and
                   Attachments.managed_libraries?(),
                 do: false,
                 else: "needs a PhoenixKit core with link_copy/3 and managed libraries"
               )

  setup :storage_setup

  setup %{conn: conn} do
    enable_inbox!()
    alice = user_fixture()
    bob = user_fixture()
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, _} = Mailboxes.ensure_user_mailbox(bob)

    %{conn: put_test_scope(conn, scope_for(alice)), alice: alice, alice_mb: alice_mb, bob: bob}
  end

  test "an upload of bytes Media holds is linked, kept in Drafts, then filed with the message",
       ctx do
    media =
      ctx.alice
      |> stored_file_fixture(@content, filename: "scan.pdf")
      |> Ecto.Changeset.change(status: "active")
      |> Repo.update!()

    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

    view
    |> file_input("#compose-form", :attachments, [
      %{name: "scan.pdf", content: @content, type: "application/pdf"}
    ])
    |> render_upload("scan.pdf")

    view |> element("button[phx-click=save_draft]") |> render_click()
    render_async(view)

    [%{message: draft}] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")
    [row] = Attachments.list_for_message(draft.uuid)
    snapshot = Storage.get_file(row.file_uuid)

    # No second copy of the bytes, and filed under the mailbox's Drafts.
    assert snapshot.file_path == media.file_path
    assert snapshot.uuid != media.uuid
    assert Storage.get_folder(snapshot.folder_uuid).name == "Drafts"

    view
    |> form("#compose-form", %{
      "to" => "@#{ctx.bob.username}",
      "cc" => "",
      "bcc" => "",
      "subject" => "Files",
      "body" => "See attached."
    })
    |> render_submit()

    assert_redirect(view)

    folder = Repo.get!(Message, draft.uuid).metadata["attachments_folder_uuid"]
    sent = Storage.get_file(snapshot.uuid)

    assert folder
    assert sent.folder_uuid == folder
    assert Storage.get_folder(folder).name =~ "Files"
    assert sent.file_path == media.file_path
  end
end
