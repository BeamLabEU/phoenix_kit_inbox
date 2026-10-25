defmodule PhoenixKitInbox.Web.AttachmentsLiveTest do
  @moduledoc """
  Attachments in the UI: compose uploads and the "attach existing file"
  picker, chips that come off again, forwards and drafts that carry their
  files, and the download links in the reading pane.
  """

  use PhoenixKitInbox.LiveCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Paths
  alias PhoenixKitInbox.Test.Repo

  setup :storage_setup

  setup %{conn: conn} do
    enable_inbox!()
    alice = user_fixture()
    bob = user_fixture()
    carol = user_fixture()

    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    {:ok, carol_mb} = Mailboxes.ensure_user_mailbox(carol)

    %{
      conn: put_test_scope(conn, scope_for(alice)),
      alice: alice,
      bob: bob,
      carol: carol,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      carol_mb: carol_mb
    }
  end

  # The send runs in a task: the page once the task answered.
  defp submit(view, to) do
    push_send(view, to)
    render_async(view)
  end

  # A send that succeeds: the page goes to Sent.
  defp submit_ok(view, to) do
    push_send(view, to)
    assert_redirect(view)
  end

  defp push_send(view, to) do
    view
    |> form("#compose-form", %{
      "to" => to,
      "cc" => "",
      "bcc" => "",
      "subject" => "Files",
      "body" => "See attached."
    })
    |> render_submit()
  end

  defp save_draft(view) do
    view |> element("button[phx-click=save_draft]") |> render_click()
    render_async(view)
  end

  defp upload_scan(view) do
    view
    |> file_input("#compose-form", :attachments, [
      %{name: "scan.pdf", content: "%PDF scanned", type: "application/pdf"}
    ])
    |> render_upload("scan.pdf")
  end

  defp inbox_files do
    case Libraries.get_hidden_library_by_slug(Attachments.library_slug()) do
      nil -> []
      library -> files_in_library(library.uuid)
    end
  end

  defp received(mailbox) do
    [%{message: message}] = Messages.list_folder(mailbox.uuid, "inbox")
    Attachments.list_for_message(message.uuid)
  end

  describe "compose" do
    test "an upload stays out of Storage until the send, then is stored once", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      upload_scan(view)

      assert has_element?(view, "#compose-attachments [id^=upload-]", "scan.pdf")
      assert inbox_files() == []

      submit_ok(view, "@#{ctx.bob.username}")

      assert [%{file_uuid: file_uuid, filename: "scan.pdf"}] = received(ctx.bob_mb)
      assert [%{uuid: ^file_uuid}] = inbox_files()
    end

    test "an upload taken off before saving is cancelled; nothing is stored", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      upload_scan(view)

      view |> element("#compose-attachments [id^=upload-] button") |> render_click()

      refute has_element?(view, "#compose-attachments [id^=upload-]")
      assert inbox_files() == []
    end

    test "leaving compose after an upload stores nothing", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      upload_scan(view)

      assert {:error, {:live_redirect, _}} =
               view |> element("#compose-form a", "Cancel") |> render_click()

      assert inbox_files() == []
    end

    test "saving a draft stores the upload; the chip then names the draft's snapshot", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      upload_scan(view)

      save_draft(view)

      [%{message: draft}] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")
      [row] = Attachments.list_for_message(draft.uuid)
      assert row.filename == "scan.pdf"
      assert has_element?(view, "#attachment-#{row.file_uuid}", "scan.pdf")
      refute has_element?(view, "#compose-attachments [id^=upload-]")

      save_draft(view)
      assert [%{uuid: uuid}] = Attachments.list_for_message(draft.uuid)
      assert uuid == row.uuid
      assert [_] = inbox_files()
    end

    test "a refused send keeps the upload for the next try", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      upload_scan(view)

      submit(view, "nobody@example.com")
      assert has_element?(view, "#compose-attachments [id^=upload-]", "scan.pdf")
      assert inbox_files() == []

      submit_ok(view, "@#{ctx.bob.username}")
      assert [%{filename: "scan.pdf"}] = received(ctx.bob_mb)
    end

    test "an existing file the user may read is attached; another's is refused, unnamed", ctx do
      mine = stored_file_fixture(ctx.alice, "my photo", filename: "mine.jpg")
      theirs = stored_file_fixture(ctx.carol, "her contract", filename: "contract.pdf")

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      send(view.pid, {:media_selected, [mine.uuid, theirs.uuid]})

      assert has_element?(view, "#attachment-#{mine.uuid}", "mine.jpg")
      refute has_element?(view, "#attachment-#{theirs.uuid}")
      # A forged pick of another user's file must not tell its name.
      assert has_element?(view, "#flash-error", "Not attached: a file.")
      refute render(view) =~ "contract.pdf"

      submit_ok(view, "@#{ctx.bob.username}")
      assert [%{source_file_uuid: source}] = received(ctx.bob_mb)
      assert source == mine.uuid
    end

    test "a refused pick the user may read is named", ctx do
      binned =
        ctx.alice
        |> stored_file_fixture("old notes", filename: "old-notes.txt")
        |> Ecto.Changeset.change(status: "trashed", trashed_at: DateTime.utc_now(:second))
        |> Repo.update!()

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      send(view.pid, {:media_selected, [binned.uuid]})

      assert has_element?(view, "#flash-error", "Not attached: old-notes.txt.")
      refute has_element?(view, "#attachment-#{binned.uuid}")
    end

    test "a send while an upload is still in progress waits for it", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

      view
      |> file_input("#compose-form", :attachments, [
        %{name: "big.pdf", content: String.duplicate("x", 2_000), type: "application/pdf"}
      ])
      |> render_upload("big.pdf", 50)

      submit(view, "@#{ctx.bob.username}")
      assert has_element?(view, "#flash-error", "Wait for the uploads to finish.")

      save_draft(view)
      assert has_element?(view, "#flash-error", "Wait for the uploads to finish.")

      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []
      assert Messages.list_folder(ctx.alice_mb.uuid, "drafts") == []
      assert inbox_files() == []
    end

    test "taking a picked file off leaves the original alone", ctx do
      mine = stored_file_fixture(ctx.alice, "keep me", filename: "keep.txt")

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      send(view.pid, {:media_selected, [mine.uuid]})
      view |> element("#attachment-#{mine.uuid} button") |> render_click()

      refute has_element?(view, "#attachment-#{mine.uuid}")
      assert Storage.get_file(mine.uuid)
    end

    test "the media picker lists the user's own files, not another user's", ctx do
      stored_file_fixture(ctx.alice, "my photo", filename: "mine.jpg")
      stored_file_fixture(ctx.carol, "her contract", filename: "contract.pdf")

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      html = view |> element("#attach-existing") |> render_click()

      assert html =~ "mine.jpg"
      refute html =~ "contract.pdf"
    end

    test "a system role's media picker lists the whole library", ctx do
      stored_file_fixture(ctx.carol, "her contract", filename: "contract.pdf")
      admin = %{scope_for(ctx.alice) | cached_roles: ["Admin"]}
      conn = put_test_scope(ctx.conn, admin)

      {:ok, view, _html} = live(conn, "/en/admin/inbox/compose")
      html = view |> element("#attach-existing") |> render_click()

      assert html =~ "contract.pdf"
    end

    test "the media picker is not mounted without a user", ctx do
      conn = put_test_scope(ctx.conn, %{scope_for(ctx.alice) | user: nil})
      {:ok, view, _html} = live(conn, "/en/admin/inbox/compose")

      render_click(view, "open_media_selector", %{})

      refute has_element?(view, "#media-selector-modal-backdrop-inbox-media-selector")
    end

    test "the attach-existing button opens the media picker", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

      picker = "#media-selector-modal-backdrop-inbox-media-selector"

      refute has_element?(view, picker)
      view |> element("#attach-existing") |> render_click()
      assert has_element?(view, picker)

      send(view.pid, {:media_selector_closed})
      refute has_element?(view, picker)
    end

    test "a forward carries the original's attachments", ctx do
      {:ok, original} =
        Messages.send_message(
          scope_for(ctx.alice),
          ctx.alice_mb,
          %{"to" => "@#{ctx.bob.username}", "subject" => "Plans"},
          attachments_data: [%{binary: "plan", filename: "plan.pdf"}]
        )

      [row] = Attachments.list_for_message(original.uuid)

      conn = put_test_scope(build_conn() |> init_test_session(%{}), scope_for(ctx.bob))

      {:ok, view, _html} =
        live(conn, "/en/admin/inbox/compose?mailbox=#{ctx.bob_mb.uuid}&forward=#{original.uuid}")

      assert has_element?(view, "#attachment-#{row.file_uuid}", "plan.pdf")

      submit_ok(view, "@#{ctx.carol.username}")
      assert [%{file_uuid: file_uuid}] = received(ctx.carol_mb)
      assert file_uuid == row.file_uuid
    end

    test "a reopened draft shows its attachments and keeps them on save", ctx do
      mine = stored_file_fixture(ctx.alice, "draft file", filename: "d.txt")

      {:ok, draft} =
        Messages.save_draft(scope_for(ctx.alice), ctx.alice_mb, %{
          "subject" => "WIP",
          "attachments" => [%{"file_uuid" => mine.uuid}]
        })

      [row] = Attachments.list_for_message(draft.uuid)

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose?draft=#{draft.uuid}")
      assert has_element?(view, "#attachment-#{row.file_uuid}", "d.txt")

      save_draft(view)

      assert [%{uuid: uuid}] = Attachments.list_for_message(draft.uuid)
      assert uuid == row.uuid
    end

    test "a refused send says why and keeps the chips", ctx do
      Application.put_env(:phoenix_kit_inbox, :attachment_policy, {__MODULE__, :refuse})
      on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :attachment_policy) end)

      mine = stored_file_fixture(ctx.alice, "price list", filename: "prices.pdf")
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      send(view.pid, {:media_selected, [mine.uuid]})

      submit(view, "@#{ctx.bob.username}")

      assert has_element?(
               view,
               "#flash-error",
               PhoenixKitInbox.Errors.message({:attachment_refused, :money})
             )

      assert has_element?(view, "#attachment-#{mine.uuid}")
    end
  end

  def refuse(_scope, _users, _rows), do: {:error, :money}

  # Refuses a row whose filename the test registered.
  def refuse_file(_scope, _users, rows) do
    refused = Application.get_env(:phoenix_kit_inbox, :policy_refused_file)
    if Enum.any?(rows, &(&1.filename == refused)), do: {:error, :money}, else: :ok
  end

  # Holds the send until the test lets it go.
  def hold(_scope, _users, _rows) do
    send(Application.get_env(:phoenix_kit_inbox, :hold_test_pid), {:held, self()})

    receive do
      :go -> :ok
    after
      5_000 -> :ok
    end
  end

  # Holds the first call it gets (the test registered a pid), then answers
  # by the scope: only one holding inbox.send_external may see the files.
  def hold_once_by_scope(scope, _users, _rows) do
    if pid = Application.get_env(:phoenix_kit_inbox, :hold_test_pid) do
      Application.delete_env(:phoenix_kit_inbox, :hold_test_pid)
      send(pid, {:held, self()})

      receive do
        :go -> :ok
      after
        5_000 -> :ok
      end
    end

    if Scope.can?(scope, "inbox.send_external"),
      do: :ok,
      else: {:error, :money}
  end

  # The send's own links to upload files (ComposeLive.own_uploads/1).
  defp upload_links,
    do: Path.wildcard(Path.join(System.tmp_dir!(), "phoenix_kit_inbox_upload_*"))

  defp upload_ref(view) do
    [_, ref] = Regex.run(~r/id="upload-([^"]+)"/, render(view))
    ref
  end

  defp put_policy(fun) do
    Application.put_env(:phoenix_kit_inbox, :attachment_policy, {__MODULE__, fun})
    Application.put_env(:phoenix_kit_inbox, :hold_test_pid, self())

    on_exit(fn ->
      for key <- [:attachment_policy, :hold_test_pid, :policy_refused_file],
          do: Application.delete_env(:phoenix_kit_inbox, key)
    end)
  end

  defp withhold_file(filename) do
    put_policy(:refuse_file)
    Application.put_env(:phoenix_kit_inbox, :policy_refused_file, filename)
  end

  # A CHECK constraint the attachment changeset does not know: inserting a
  # row named `filename` raises inside the message transaction.
  defp raise_on_row!(filename) do
    Repo.query!("""
    ALTER TABLE phoenix_kit_inbox_attachments
      ADD CONSTRAINT inbox_test_refuse CHECK (filename <> '#{filename}') NOT VALID
    """)
  end

  defp stop_raising! do
    Repo.query!("ALTER TABLE phoenix_kit_inbox_attachments DROP CONSTRAINT inbox_test_refuse")
  end

  describe "sending and saving in a task" do
    test "a send that crashes keeps the text, the uploads and the chips for the next try",
         ctx do
      mine = stored_file_fixture(ctx.alice, "price list", filename: "prices.pdf")
      raise_on_row!("scan.pdf")

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      upload_scan(view)
      send(view.pid, {:media_selected, [mine.uuid]})

      ExUnit.CaptureLog.capture_log(fn -> submit(view, "@#{ctx.bob.username}") end)

      assert has_element?(
               view,
               "#flash-error",
               "The message may not have been sent. Check Sent before trying again."
             )

      assert has_element?(view, "input[name=to][value='@#{ctx.bob.username}']")
      assert has_element?(view, "input[name=subject][value=Files]")
      assert has_element?(view, "textarea[name=body]", "See attached.")
      assert has_element?(view, "#compose-attachments [id^=upload-]", "scan.pdf")
      assert has_element?(view, "#attachment-#{mine.uuid}", "prices.pdf")
      refute has_element?(view, "#compose-send[disabled]")
      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []
      assert inbox_files() == []

      stop_raising!()
      submit_ok(view, "@#{ctx.bob.username}")

      assert ["prices.pdf", "scan.pdf"] == ctx.bob_mb |> received() |> Enum.map(& &1.filename)
    end

    test "a refused send keeps the text, the uploads and the chips", ctx do
      mine = stored_file_fixture(ctx.alice, "price list", filename: "prices.pdf")
      withhold_file("prices.pdf")

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      upload_scan(view)
      send(view.pid, {:media_selected, [mine.uuid]})

      submit(view, "@#{ctx.bob.username}")

      assert has_element?(
               view,
               "#flash-error",
               PhoenixKitInbox.Errors.message({:attachment_refused, :money})
             )

      assert has_element?(view, "input[name=subject][value=Files]")
      assert has_element?(view, "textarea[name=body]", "See attached.")
      assert has_element?(view, "#compose-attachments [id^=upload-]", "scan.pdf")
      assert has_element?(view, "#attachment-#{mine.uuid}", "prices.pdf")
    end

    test "a draft save that crashes keeps the uploads; the next save stores them", ctx do
      raise_on_row!("scan.pdf")

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

      view
      |> form("#compose-form", %{"subject" => "Later", "body" => "Unfinished"})
      |> render_change()

      upload_scan(view)
      ExUnit.CaptureLog.capture_log(fn -> save_draft(view) end)

      assert has_element?(view, "#flash-error", "The draft could not be saved. Try again.")
      assert has_element?(view, "input[name=subject][value=Later]")
      assert has_element?(view, "#compose-attachments [id^=upload-]", "scan.pdf")
      assert Messages.list_folder(ctx.alice_mb.uuid, "drafts") == []
      assert inbox_files() == []

      stop_raising!()
      save_draft(view)

      [%{message: draft}] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")
      assert [%{filename: "scan.pdf"}] = Attachments.list_for_message(draft.uuid)
      refute has_element?(view, "#compose-attachments [id^=upload-]")
    end

    test "while a send runs, a second send or a save does nothing", ctx do
      put_policy(:hold)

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      upload_scan(view)

      push_send(view, "@#{ctx.bob.username}")
      assert_receive {:held, task}

      assert has_element?(view, "#compose-send[disabled]")
      assert has_element?(view, "#compose-save-draft[disabled]")
      assert has_element?(view, "#compose-attachments input[type=file][disabled]")

      render_submit(view, "send", %{"to" => "@#{ctx.bob.username}", "subject" => "Again"})
      render_click(view, "save_draft", %{})
      refute_receive {:held, _}, 200

      send(task, :go)
      assert_redirect(view)

      assert [%{message: %{subject: "Files"}}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      assert [_] = Messages.list_folder(ctx.alice_mb.uuid, "sent")
      assert Messages.list_folder(ctx.alice_mb.uuid, "drafts") == []
      assert [_] = inbox_files()
    end
  end

  describe "while a draft save runs" do
    test "nothing else changes what it works on", ctx do
      desk = shared_mailbox_fixture(ctx.alice, %{name: "Desk"})
      # A reader besides the writer: the policy is asked about the draft.
      grant_fixture(desk, ctx.bob, "read")
      mine = stored_file_fixture(ctx.alice, "price list", filename: "prices.pdf")
      other = stored_file_fixture(ctx.alice, "other", filename: "other.pdf")

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose?mailbox=#{desk.uuid}")
      send(view.pid, {:media_selected, [mine.uuid]})
      save_draft(view)

      [%{message: draft}] = Messages.list_folder(desk.uuid, "drafts")
      [row] = Attachments.list_for_message(draft.uuid)
      upload_scan(view)
      ref = upload_ref(view)

      put_policy(:hold)
      view |> element("button[phx-click=save_draft]") |> render_click()
      assert_receive {:held, task}

      # The uploads stay open during a save; only a send closes them.
      refute has_element?(view, "#compose-attachments input[type=file][disabled]")

      render_click(view, "discard", %{})
      render_click(view, "select_mailbox", %{"mailbox" => ctx.alice_mb.uuid})
      render_click(view, "open_media_selector", %{})
      render_click(view, "remove_attachment", %{"file" => to_string(row.file_uuid)})
      render_click(view, "cancel_upload", %{"ref" => ref})
      send(view.pid, {:media_selected, [other.uuid]})

      assert [%{message: %{uuid: uuid}}] = Messages.list_folder(desk.uuid, "drafts")
      assert uuid == draft.uuid
      assert has_element?(view, "select[name=mailbox] option[selected][value='#{desk.uuid}']")
      refute has_element?(view, "#media-selector-modal-backdrop-inbox-media-selector")
      assert has_element?(view, "#attachment-#{row.file_uuid}", "prices.pdf")
      assert has_element?(view, "#upload-#{ref}", "scan.pdf")
      refute has_element?(view, "#attachment-#{other.uuid}")

      send(task, :go)
      render_async(view)

      [%{message: saved}] = Messages.list_folder(desk.uuid, "drafts")
      assert saved.uuid == draft.uuid

      assert ["prices.pdf", "scan.pdf"] ==
               draft.uuid |> Attachments.list_for_message() |> Enum.map(& &1.filename)
    end

    test "its chips are judged with the scope refreshed meanwhile", ctx do
      {:ok, message} =
        Messages.send_message(
          scope_for(ctx.bob),
          ctx.bob_mb,
          %{"to" => "@#{ctx.alice.username}", "subject" => "Offer"},
          attachments_data: [%{binary: "priced", filename: "priced.pdf"}]
        )

      [row] = Attachments.list_for_message(message.uuid)

      Application.put_env(
        :phoenix_kit_inbox,
        :attachment_policy,
        {__MODULE__, :hold_once_by_scope}
      )

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_inbox, :attachment_policy)
        Application.delete_env(:phoenix_kit_inbox, :hold_test_pid)
      end)

      conn = put_test_scope(ctx.conn, scope_for(ctx.alice, ["inbox", "inbox.send_external"]))

      {:ok, view, _html} =
        live(conn, "/en/admin/inbox/compose?mailbox=#{ctx.alice_mb.uuid}&forward=#{message.uuid}")

      assert has_element?(view, "#attachment-#{row.file_uuid}", "priced.pdf")

      Application.put_env(:phoenix_kit_inbox, :hold_test_pid, self())
      view |> element("button[phx-click=save_draft]") |> render_click()
      assert_receive {:held, task}

      refresh_scope(view, scope_for(ctx.alice, ["inbox"]))
      send(task, :go)
      render_async(view)

      assert [_] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")
      assert has_element?(view, "#attachment-#{row.file_uuid}", "Attachment not available")
      refute render(view) =~ "priced.pdf"
    end
  end

  describe "without the module's task supervisor" do
    test "a send still goes, in the page's own task", ctx do
      supervisor = Process.whereis(PhoenixKitInbox.TaskSupervisor)
      Process.unregister(PhoenixKitInbox.TaskSupervisor)
      on_exit(fn -> Process.register(supervisor, PhoenixKitInbox.TaskSupervisor) end)

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      submit_ok(view, "@#{ctx.bob.username}")

      assert [%{message: %{subject: "Files"}}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
    end
  end

  describe "an upload added while a draft save runs" do
    test "stays an upload; the save takes only the ones it stored", ctx do
      desk = shared_mailbox_fixture(ctx.alice, %{name: "Desk"})
      grant_fixture(desk, ctx.bob, "read")
      put_policy(:hold)

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose?mailbox=#{desk.uuid}")
      upload_scan(view)
      view |> element("button[phx-click=save_draft]") |> render_click()
      assert_receive {:held, task}

      view
      |> file_input("#compose-form", :attachments, [
        %{name: "late.txt", content: "late", type: "text/plain"}
      ])
      |> render_upload("late.txt")

      send(task, :go)
      render_async(view)

      [%{message: draft}] = Messages.list_folder(desk.uuid, "drafts")
      assert [%{filename: "scan.pdf"}] = Attachments.list_for_message(draft.uuid)
      refute has_element?(view, "#compose-attachments [id^=upload-]", "scan.pdf")
      assert has_element?(view, "#compose-attachments [id^=upload-]", "late.txt")
    end
  end

  describe "leaving the page while a send runs" do
    # An upload's temporary file goes with the page: the send works on a
    # link to it of its own, which it deletes when done.
    test "does not cut the send short, uploads included", ctx do
      mine = stored_file_fixture(ctx.alice, "price list", filename: "prices.pdf")
      links_before = upload_links()
      put_policy(:hold)
      Process.flag(:trap_exit, true)

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      send(view.pid, {:media_selected, [mine.uuid]})
      upload_scan(view)
      push_send(view, "@#{ctx.bob.username}")
      assert_receive {:held, task}

      # The browser goes away: the LiveView process ends.
      ref = Process.monitor(task)
      Process.exit(view.pid, {:shutdown, :closed})

      send(task, :go)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}

      assert ["prices.pdf", "scan.pdf"] == ctx.bob_mb |> received() |> Enum.map(& &1.filename)
      assert upload_links() == links_before
    end
  end

  describe "an attachment the host's policy withholds from the viewer" do
    setup ctx do
      {:ok, message} =
        Messages.send_message(
          scope_for(ctx.alice),
          ctx.alice_mb,
          %{"to" => "@#{ctx.bob.username}", "subject" => "Offer"},
          attachments_data: [
            %{binary: "plan", filename: "plan.pdf"},
            %{binary: "priced", filename: "priced.pdf"}
          ]
        )

      [plan, priced] = Attachments.list_for_message(message.uuid)
      withhold_file("priced.pdf")

      bob_conn = put_test_scope(build_conn() |> init_test_session(%{}), scope_for(ctx.bob))
      %{message: message, plan: plan, priced: priced, bob_conn: bob_conn}
    end

    test "is shown in the reading pane without its name, size or link", ctx do
      {:ok, view, _html} =
        live(
          ctx.bob_conn,
          "/en/admin/inbox?mailbox=#{ctx.bob_mb.uuid}&message=#{ctx.message.uuid}"
        )

      assert has_element?(
               view,
               ~s(#message-attachments a[href="#{Paths.attachment(ctx.plan.uuid)}"]),
               "plan.pdf"
             )

      assert has_element?(
               view,
               "#message-attachment-#{ctx.priced.uuid}",
               "Attachment not available"
             )

      refute has_element?(view, ~s(a[href="#{Paths.attachment(ctx.priced.uuid)}"]))
      refute render(view) =~ "priced.pdf"
    end

    test "the sender, who made the snapshot, sees it as it is", ctx do
      {:ok, view, _html} =
        live(
          ctx.conn,
          "/en/admin/inbox?mailbox=#{ctx.alice_mb.uuid}&folder=sent&message=#{ctx.message.uuid}"
        )

      assert has_element?(
               view,
               ~s(#message-attachments a[href="#{Paths.attachment(ctx.priced.uuid)}"]),
               "priced.pdf"
             )
    end

    test "is a forward's chip without its name; the send asks the policy", ctx do
      {:ok, view, _html} =
        live(
          ctx.bob_conn,
          "/en/admin/inbox/compose?mailbox=#{ctx.bob_mb.uuid}&forward=#{ctx.message.uuid}"
        )

      assert has_element?(view, "#attachment-#{ctx.plan.file_uuid}", "plan.pdf")
      assert has_element?(view, "#attachment-#{ctx.priced.file_uuid}", "Attachment not available")
      refute render(view) =~ "priced.pdf"

      submit(view, "@#{ctx.carol.username}")

      assert has_element?(
               view,
               "#flash-error",
               PhoenixKitInbox.Errors.message({:attachment_refused, :money})
             )

      view |> element("#attachment-#{ctx.priced.file_uuid} button") |> render_click()
      submit_ok(view, "@#{ctx.carol.username}")

      assert [%{filename: "plan.pdf"}] = received(ctx.carol_mb)
    end
  end

  describe "the reading pane" do
    test "lists the attachments as download links", ctx do
      {:ok, message} =
        Messages.send_message(
          scope_for(ctx.bob),
          ctx.bob_mb,
          %{"to" => "@#{ctx.alice.username}", "subject" => "For you"},
          attachments_data: [%{binary: "data", filename: "report.pdf"}]
        )

      [row] = Attachments.list_for_message(message.uuid)

      {:ok, view, _html} =
        live(ctx.conn, "/en/admin/inbox?mailbox=#{ctx.alice_mb.uuid}&message=#{message.uuid}")

      assert has_element?(
               view,
               ~s(#message-attachments a[href="#{Paths.attachment(row.uuid)}"]),
               "report.pdf"
             )
    end

    test "shows no attachment list for a message without any", ctx do
      {:ok, message} =
        Messages.send_message(scope_for(ctx.bob), ctx.bob_mb, %{
          "to" => "@#{ctx.alice.username}",
          "subject" => "Plain"
        })

      {:ok, view, _html} =
        live(ctx.conn, "/en/admin/inbox?mailbox=#{ctx.alice_mb.uuid}&message=#{message.uuid}")

      refute has_element?(view, "#message-attachments")
    end
  end
end
