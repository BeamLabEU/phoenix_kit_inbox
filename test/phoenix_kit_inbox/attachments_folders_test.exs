defmodule PhoenixKitInbox.AttachmentsFoldersTest do
  @moduledoc """
  The folders of the attachments library (`PhoenixKitInbox.Attachments.Folders`):
  the path of a message, the host's hook, the folder recorded on the message,
  the all-or-nothing filing, drafts and links. Skipped on a core without
  managed hidden libraries, where nothing is filed.
  """

  use PhoenixKitInbox.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKit.Modules.Storage.FolderLink
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Settings
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Attachments.Folders
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Attachment
  alias PhoenixKitInbox.Schemas.Message

  Code.ensure_loaded(Libraries)

  @no_managed if(function_exported?(Libraries, :update_system_library_listing, 2),
                do: false,
                else: "needs a PhoenixKit core with managed hidden libraries"
              )

  @key "attachments_folder_uuid"

  # The folder functions with a failure the test asks for (`:folder_test_fail`):
  # `{:create_folder, n}` the nth folder made, `:move`, `:link`; or a rival
  # that wins the insert (`:rival_folder`, `:rival_link`).
  defmodule FolderStorage do
    @moduledoc false
    import Ecto.Query

    alias PhoenixKit.Modules.Storage
    alias PhoenixKitInbox.Test.Repo

    defdelegate get_file(uuid), to: Storage
    defdelegate folder_link(folder, file), to: Storage

    # The core's functions with the options a core without them lacks.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    defp core(fun, args), do: apply(Storage, fun, args)

    def create_folder(attrs, scope, opts) do
      count = (Process.get(:folders_made) || 0) + 1
      Process.put(:folders_made, count)

      case Application.get_env(:phoenix_kit_inbox, :folder_test_fail) do
        {:create_folder, ^count} ->
          {:error, :boom}

        # The message's own folder is made as its message vanishes (the levels exist).
        {:vanish, uuid} when count == 1 ->
          Repo.delete_all(from(m in PhoenixKitInbox.Schemas.Message, where: m.uuid == ^uuid))
          core(:create_folder, [attrs, scope, opts])

        :rival_folder when count <= 2 ->
          # Another message's filing makes a shared level first.
          _ = core(:create_folder, [attrs, scope, opts])
          core(:create_folder, [attrs, scope, opts])

        _ ->
          core(:create_folder, [attrs, scope, opts])
      end
    end

    def move_file_to_folder(file, folder, scope, opts) do
      case Application.get_env(:phoenix_kit_inbox, :folder_test_fail) do
        :move -> {:error, :boom}
        _ -> core(:move_file_to_folder, [file, folder, scope, opts])
      end
    end

    def create_folder_link(folder, file, scope, opts) do
      case Application.get_env(:phoenix_kit_inbox, :folder_test_fail) do
        :link ->
          {:error, :boom}

        :rival_link ->
          _ = core(:create_folder_link, [folder, file, scope, opts])
          core(:create_folder_link, [folder, file, scope, opts])

        _ ->
          core(:create_folder_link, [folder, file, scope, opts])
      end
    end
  end

  # The host's hook: answers `:folder_test_answer`, or raises, exits, throws.
  defmodule Hook do
    @moduledoc false

    def names(message, mailbox) do
      send(Application.get_env(:phoenix_kit_inbox, :folder_test_pid), {:hook, message, mailbox})

      case Application.get_env(:phoenix_kit_inbox, :folder_test_answer) do
        :raise -> raise "host bug"
        :exit -> exit(:gone)
        :throw -> throw(:oops)
        answer -> answer
      end
    end
  end

  # A core that has hidden libraries but no managed ones.
  defmodule NoManagedLibraries do
    @moduledoc false
    alias PhoenixKit.Modules.Storage.Libraries

    defdelegate get_hidden_library_by_slug(slug), to: Libraries
    defdelegate hidden?(library), to: Libraries
    defdelegate media_uuid, to: Libraries

    def create_system_library(attrs, _opts),
      do: Libraries.create_system_library(attrs, hidden: true)
  end

  setup :storage_setup

  setup do
    enable_inbox!()

    alice = user_fixture()
    bob = user_fixture()
    {:ok, alice_box} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_box} = Mailboxes.ensure_user_mailbox(bob)

    on_exit(fn ->
      for key <- [
            :folder_storage,
            :folder_test_fail,
            :folder_test_answer,
            :folder_test_pid,
            :attachment_folder,
            :storage_libraries
          ],
          do: Application.delete_env(:phoenix_kit_inbox, key)
    end)

    %{
      alice: alice,
      bob: bob,
      alice_box: alice_box,
      bob_box: bob_box,
      scope: scope_for(alice),
      bob_scope: scope_for(bob)
    }
  end

  defp send_to(ctx, extra, opts) do
    attrs =
      Map.merge(%{"to" => "@#{ctx.bob.username}", "subject" => "Files", "body" => "hi"}, extra)

    {:ok, message} = Messages.send_message(ctx.scope, ctx.alice_box, attrs, opts)
    Repo.get!(Message, message.uuid)
  end

  defp send_data(ctx, extra \\ %{}, content \\ nil) do
    content = content || "bytes #{System.unique_integer([:positive])}"
    send_to(ctx, extra, attachments_data: [%{binary: content, filename: "a.txt"}])
  end

  defp save_draft(ctx, extra \\ %{}, opts) do
    {:ok, draft} =
      Messages.save_draft(
        ctx.scope,
        ctx.alice_box,
        Map.merge(%{"subject" => "Draft"}, extra),
        opts
      )

    Repo.get!(Message, draft.uuid)
  end

  defp data_opts(content), do: [attachments_data: [%{binary: content, filename: "d.txt"}]]

  defp snapshot(message) do
    [row] = Attachments.list_for_message(message.uuid)
    Storage.get_file(row.file_uuid)
  end

  # Names from the root to the folder.
  defp chain(nil), do: nil
  defp chain(%Storage.File{folder_uuid: uuid}), do: chain(uuid)

  defp chain(uuid) when is_binary(uuid), do: Folder |> Repo.get!(uuid) |> walk([])

  defp walk(nil, acc), do: acc

  defp walk(%Folder{} = f, acc) do
    parent = f.parent_uuid && Repo.get!(Folder, f.parent_uuid)
    walk(parent, [f.name | acc])
  end

  defp library_folders do
    {:ok, library} = Attachments.ensure_library()
    Repo.all(from(f in Folder, where: f.library_uuid == ^library.uuid))
  end

  # The message was sent `seconds` before it was.
  defp earlier(%Message{uuid: uuid}, seconds) do
    at = Repo.get!(Message, uuid).sent_at

    from(m in Message, where: m.uuid == ^uuid)
    |> Repo.update_all(set: [sent_at: DateTime.add(at, -seconds)])
  end

  defp stamp(%Message{sent_at: at}, format), do: Calendar.strftime(at, format)

  defp mailbox_folder(box), do: "#{box.name} (#{box.slug})"

  defp links_in(folder_uuid),
    do: Repo.all(from(l in FolderLink, where: l.folder_uuid == ^folder_uuid))

  defp hook!(answer) do
    Application.put_env(:phoenix_kit_inbox, :attachment_folder, {Hook, :names})
    Application.put_env(:phoenix_kit_inbox, :folder_test_pid, self())
    Application.put_env(:phoenix_kit_inbox, :folder_test_answer, answer)
  end

  defp storage!(failure) do
    Application.put_env(:phoenix_kit_inbox, :folder_storage, FolderStorage)
    Application.put_env(:phoenix_kit_inbox, :folder_test_fail, failure)
  end

  describe "the default path" do
    @describetag skip: @no_managed

    test "mailbox / month / date time — subject, without an owner, recorded on the message",
         ctx do
      message = send_data(ctx, %{"subject" => "Quarterly"})
      file = snapshot(message)

      assert chain(file) == [
               mailbox_folder(ctx.alice_box),
               stamp(message, "%Y-%m"),
               stamp(message, "%Y-%m-%d %H:%M") <> " — Quarterly"
             ]

      assert message.metadata[@key] == file.folder_uuid
      assert Enum.all?(library_folders(), &is_nil(&1.user_uuid))
      # The send's own keys are still there.
      assert message.metadata["sender"]["user_uuid"] == ctx.alice.uuid
    end

    test "the time is the site's, not UTC", ctx do
      {:ok, _} = Settings.update_setting("time_zone", "+5")

      message = send_data(ctx, %{"subject" => "Zoned"})
      local = DateTime.add(message.sent_at, 5 * 3600)

      assert chain(snapshot(message)) == [
               mailbox_folder(ctx.alice_box),
               Calendar.strftime(local, "%Y-%m"),
               Calendar.strftime(local, "%Y-%m-%d %H:%M") <> " — Zoned"
             ]
    end

    test "namesake mailboxes do not share a folder", ctx do
      one = shared_mailbox_fixture(ctx.alice, %{name: "Support", slug: "support-one"})
      two = shared_mailbox_fixture(ctx.alice, %{name: "Support", slug: "support-two"})

      for box <- [one, two] do
        {:ok, _} =
          Messages.send_message(
            ctx.scope,
            box,
            %{"to" => "@#{ctx.bob.username}", "subject" => "S"},
            data_opts("from #{box.slug}")
          )
      end

      roots =
        library_folders()
        |> Enum.filter(&is_nil(&1.parent_uuid))
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert roots == ["Support (support-one)", "Support (support-two)"]
    end

    test "a renamed mailbox files new mail in a new folder; the old one stays", ctx do
      box = shared_mailbox_fixture(ctx.alice, %{name: "Support", slug: "support-r"})

      send_from =
        &Messages.send_message(
          ctx.scope,
          &1,
          %{"to" => "@#{ctx.bob.username}", "subject" => "S"},
          &2
        )

      {:ok, _} = send_from.(box, data_opts("before"))
      renamed = box |> Ecto.Changeset.change(name: "Sales") |> Repo.update!()
      {:ok, _} = send_from.(renamed, data_opts("after"))

      roots = library_folders() |> Enum.filter(&is_nil(&1.parent_uuid)) |> Enum.map(& &1.name)
      assert Enum.sort(roots) == ["Sales (support-r)", "Support (support-r)"]
    end

    test "a blank subject is (no subject); / and control characters go; 80 characters", ctx do
      blank = send_data(ctx, %{"subject" => "  "})
      assert List.last(chain(snapshot(blank))) =~ " — (no subject)"

      messy = send_data(ctx, %{"subject" => "Re: a/b\n\tc\u0007d " <> String.duplicate("x", 200)})
      name = List.last(chain(snapshot(messy)))

      [_, subject] = String.split(name, " — ", parts: 2)
      assert String.length(subject) == 80
      assert String.starts_with?(subject, "Re: ab c d xxx")
      refute name =~ "/"
      refute name =~ ~r/[[:cntrl:]]/u
    end

    test "two sends of one minute and subject get two folders; filing again reuses one", ctx do
      first = send_data(ctx, %{"subject" => "Same"})
      second = send_data(ctx, %{"subject" => "Same"})
      first_folder = first.metadata[@key]
      assert second.metadata[@key] != first_folder

      # The same minute, whatever the clock said: file the second one afresh.
      from(m in Message,
        where: m.uuid == ^second.uuid,
        update: [set: [sent_at: ^first.sent_at, metadata: fragment("? - ?", m.metadata, ^@key)]]
      )
      |> Repo.update_all([])

      Folders.lay_out_sent(Repo.get!(Message, second.uuid), ctx.alice_box)

      refilled = Repo.get!(Message, second.uuid).metadata[@key]
      assert refilled not in [first_folder, second.metadata[@key]]
      # Taken names get the next suffix ((2) is the second send's own, when the minute held).
      taken = Enum.map(library_folders(), & &1.name)
      name = Repo.get!(Folder, refilled).name
      assert String.starts_with?(name, Repo.get!(Folder, first_folder).name <> " (")
      assert Enum.count(taken, &(&1 == name)) == 1

      # A second filing of a message uses the folder it has.
      before = length(library_folders())
      Folders.lay_out_sent(Repo.get!(Message, second.uuid), ctx.alice_box)
      assert Repo.get!(Message, second.uuid).metadata[@key] == refilled
      assert length(library_folders()) == before
    end

    test "the folder is in the site's language, whoever sends", ctx do
      {:ok, _} = Languages.set_primary_language("ru")
      Gettext.put_locale(PhoenixKitInbox.Gettext, "et")

      blank = send_data(ctx, %{"subject" => ""})
      assert List.last(chain(snapshot(blank))) =~ " — (без темы)"

      draft = save_draft(ctx, data_opts("ru draft"))
      assert chain(snapshot(draft)) == [mailbox_folder(ctx.alice_box), "Черновики"]
    end
  end

  describe "the host's hook" do
    @describetag skip: @no_managed

    test "a list of names replaces mailbox/month, and gets the message and mailbox", ctx do
      hook!(["Orders", "  order-123 "])

      message = send_data(ctx, %{"subject" => "Hooked"})

      assert chain(snapshot(message)) == [
               "Orders",
               "order-123",
               stamp(message, "%Y-%m-%d %H:%M") <> " — Hooked"
             ]

      assert_received {:hook, %Message{uuid: uuid}, %{uuid: mailbox_uuid}}
      assert uuid == message.uuid
      assert mailbox_uuid == ctx.alice_box.uuid

      # The folder is recorded: filing again does not ask.
      Folders.lay_out_sent(message, ctx.alice_box)
      refute_received {:hook, _, _}
    end

    test "nil is the default path, quietly", ctx do
      hook!(nil)

      log =
        capture_log(fn ->
          message = send_data(ctx)
          assert [mailbox, _month, _name] = chain(snapshot(message))
          assert mailbox == mailbox_folder(ctx.alice_box)
        end)

      refute log =~ "attachment_folder"
    end

    for failure <- [:raise, :exit, :throw] do
      test "a hook that does #{failure} keeps the default path, with a warning", ctx do
        hook!(unquote(failure))

        log =
          capture_log(fn ->
            message = send_data(ctx)
            assert [mailbox, _month, _name] = chain(snapshot(message))
            assert mailbox == mailbox_folder(ctx.alice_box)
          end)

        assert log =~ "attachment_folder failed"
      end
    end

    for {label, answer} <- [
          {"not a list", "Orders"},
          {"an empty list", []},
          {"a blank name", ["Orders", "  "]},
          {"a slash", ["a/b"]},
          {"a control character", ["a\nb"]},
          {"a name over 255", [String.duplicate("a", 256)]},
          {"a name that is no string", ["ok", 5]}
        ] do
      test "an answer with #{label} keeps the default path, with a warning", ctx do
        hook!(unquote(Macro.escape(answer)))

        log =
          capture_log(fn ->
            message = send_data(ctx)
            assert [mailbox, _month, _name] = chain(snapshot(message))
            assert mailbox == mailbox_folder(ctx.alice_box)
          end)

        assert log =~ "attachment_folder answered"
      end
    end
  end

  describe "the folder on the message" do
    @describetag skip: @no_managed

    test "a caller's attachments_folder_uuid is dropped, on a send and on a draft", ctx do
      {:ok, library} = Attachments.ensure_library()

      {:ok, foreign} =
        Storage.create_folder(%{name: "Foreign", library_uuid: library.uuid}, nil,
          managed: :owner
        )

      message = send_data(ctx, %{"metadata" => %{@key => foreign.uuid, "keep" => "me"}})
      file = snapshot(message)

      assert message.metadata[@key] == file.folder_uuid
      assert file.folder_uuid != foreign.uuid
      assert message.metadata["keep"] == "me"

      draft = save_draft(ctx, %{"metadata" => %{@key => foreign.uuid}}, data_opts("d"))
      refute Map.has_key?(draft.metadata, @key)

      sent = send_to(ctx, %{"uuid" => draft.uuid, "metadata" => %{@key => foreign.uuid}}, [])
      assert sent.metadata[@key] != foreign.uuid
      assert Repo.get!(Folder, sent.metadata[@key]).parent_uuid != foreign.uuid
    end

    test "a message with several files files them all in one folder", ctx do
      message =
        send_to(ctx, %{},
          attachments_data: [
            %{binary: "one", filename: "1.txt"},
            %{binary: "two", filename: "2.txt"}
          ]
        )

      folders =
        for row <- Attachments.list_for_message(message.uuid),
            uniq: true,
            do: Storage.get_file(row.file_uuid).folder_uuid

      assert folders == [message.metadata[@key]]
    end
  end

  describe "all or nothing" do
    @describetag skip: @no_managed

    for {label, failure} <- [
          {"the first folder", {:create_folder, 1}},
          {"the folder of the message", {:create_folder, 3}},
          {"a move", :move}
        ] do
      test "a failure at #{label} leaves no folder and no key; the send stands; a later filing works",
           ctx do
        storage!(unquote(Macro.escape(failure)))

        {message, log} =
          with_log(fn -> send_data(ctx, %{"subject" => "Fails"}) end)

        assert message.status == "sent"
        assert log =~ "could not file the attachments"
        assert library_folders() == []
        refute Map.has_key?(message.metadata, @key)
        assert snapshot(message).folder_uuid == nil

        # The next filing (what a maintenance run does) lays it out.
        Application.delete_env(:phoenix_kit_inbox, :folder_test_fail)
        Process.delete(:folders_made)
        Folders.lay_out_sent(message, ctx.alice_box)

        message = Repo.get!(Message, message.uuid)
        assert [_, _, name] = chain(snapshot(message))
        assert name =~ " — Fails"
        assert message.metadata[@key] == snapshot(message).folder_uuid
      end
    end

    test "a rival that makes a level first is found, not an error", ctx do
      storage!(:rival_folder)

      message = send_data(ctx)

      # The month and the mailbox are each there once, the message's folder is its own.
      assert [mailbox, month, _name] = chain(snapshot(message))
      names = Enum.map(library_folders(), & &1.name)
      assert Enum.count(names, &(&1 == mailbox)) == 1
      assert Enum.count(names, &(&1 == month)) == 1
    end

    test "a message that vanishes before its key is written: nothing is left, nothing is lost",
         ctx do
      message = send_data(ctx, %{"subject" => "Vanishing"})
      before = library_folders()

      from(m in Message, where: m.uuid == ^message.uuid)
      |> Repo.update_all(set: [metadata: Map.delete(message.metadata, @key)])

      storage!({:vanish, message.uuid})
      Process.delete(:folders_made)
      # The old message folder is "live" but unrecorded now, so a new one is made.
      {_, log} =
        with_log(fn -> Folders.lay_out_sent(Repo.get!(Message, message.uuid), ctx.alice_box) end)

      assert log =~ "could not file the attachments"
      assert Repo.get(Message, message.uuid)
      assert library_folders() == before
    end

    test "after 20 taken names every further message gets its own uuid-tail suffix", ctx do
      first = send_data(ctx, %{"subject" => "Busy"})
      others = for n <- 1..3, do: send_data(ctx, %{"subject" => "Busy", "body" => "b#{n}"})
      folder = Repo.get!(Folder, first.metadata[@key])

      for n <- 2..21 do
        Storage.create_folder(
          %{
            name: "#{folder.name} (#{n})",
            library_uuid: folder.library_uuid,
            parent_uuid: folder.parent_uuid
          },
          nil,
          managed: :owner
        )
      end

      for message <- others do
        from(m in Message, where: m.uuid == ^message.uuid)
        |> Repo.update_all(
          set: [sent_at: first.sent_at, metadata: Map.delete(message.metadata, @key)]
        )

        Folders.lay_out_sent(Repo.get!(Message, message.uuid), ctx.alice_box)
      end

      names =
        for message <- others do
          Repo.get!(Folder, Repo.get!(Message, message.uuid).metadata[@key]).name
        end

      assert length(Enum.uniq(names)) == 3

      for {message, name} <- Enum.zip(others, names) do
        assert String.ends_with?(name, " (" <> String.slice(message.uuid, -12, 12) <> ")")
      end
    end

    test "a file moved out of another message's folder leaves a link there", ctx do
      first = save_draft(ctx, data_opts("raced"))
      file = snapshot(first)
      second = save_draft(ctx, %{"attachments" => [%{"file_uuid" => file.uuid}]}, [])

      # The second is filed first: it moves the file.
      sent_second = send_to(ctx, %{"uuid" => second.uuid, "subject" => "Second"}, [])
      earlier(sent_second, 60)
      sent_first = send_to(ctx, %{"uuid" => first.uuid, "subject" => "First"}, [])
      assert Storage.get_file(file.uuid).folder_uuid == sent_second.metadata[@key]

      # But the first was sent earlier: filing it again takes the file over.
      earlier(sent_first, 120)
      Folders.lay_out_sent(Repo.get!(Message, sent_first.uuid), ctx.alice_box)

      assert Storage.get_file(file.uuid).folder_uuid == sent_first.metadata[@key]
      assert [%{file_uuid: linked}] = links_in(sent_second.metadata[@key])
      assert linked == file.uuid
    end

    test "a message none of whose files is in the library makes no folder", ctx do
      media = stored_file_fixture(ctx.alice, "elsewhere")
      message = send_to(ctx, %{}, [])

      # A row naming a file outside the library (not made by the module).
      %Attachment{}
      |> Attachment.changeset(%{
        message_uuid: message.uuid,
        file_uuid: media.uuid,
        filename: "e.txt",
        content_type: "text/plain",
        size_bytes: 9,
        position: 0
      })
      |> Repo.insert!()

      Folders.lay_out_sent(message, ctx.alice_box)

      assert library_folders() == []
      refute Map.has_key?(Repo.get!(Message, message.uuid).metadata, @key)
    end

    test "the host is not asked inside the transaction when the recorded folder is dead", ctx do
      message = send_data(ctx, %{"subject" => "Dead"})
      Repo.delete!(Repo.get!(Folder, message.metadata[@key]))
      hook!(["Orders"])

      Folders.lay_out_sent(message, ctx.alice_box)

      assert_received {:hook, _, _}
      assert hd(chain(snapshot(Repo.get!(Message, message.uuid)))) == "Orders"
    end

    test "a file is filed with the first message that names it, not the last", ctx do
      # A is sent but its filing fails; B (bob) forwards the file and is filed.
      storage!(:move)
      {original, _} = with_log(fn -> send_data(ctx, %{"subject" => "Original"}) end)
      Application.delete_env(:phoenix_kit_inbox, :folder_test_fail)
      file = snapshot(original)
      assert file.folder_uuid == nil
      earlier(original, 60)

      {:ok, forward} =
        Messages.send_message(
          ctx.bob_scope,
          ctx.bob_box,
          %{
            "to" => "@#{ctx.alice.username}",
            "subject" => "Fwd",
            "attachments" => [%{"file_uuid" => file.uuid}]
          },
          []
        )

      forward = Repo.get!(Message, forward.uuid)
      assert Storage.get_file(file.uuid).folder_uuid == nil
      assert [_] = links_in(forward.metadata[@key])

      # A is filed later: the file is its own, and the forward keeps its link.
      Folders.lay_out_sent(Repo.get!(Message, original.uuid), ctx.alice_box)
      original = Repo.get!(Message, original.uuid)
      assert Storage.get_file(file.uuid).folder_uuid == original.metadata[@key]
      assert [_] = links_in(forward.metadata[@key])
    end

    test "format characters are left out of names", ctx do
      message = send_data(ctx, %{"subject" => "a\u202Eb\u200Bc"})
      assert List.last(chain(snapshot(message))) =~ " — abc"

      hook!(["Or\u200Bders"])
      other = send_data(ctx, %{"subject" => "H"})
      assert hd(chain(snapshot(other))) == "Orders"
    end

    test "the zone's daylight saving time is applied for the instant", ctx do
      {:ok, _} = Settings.update_setting("time_zone", "Europe/Tallinn")
      message = send_data(ctx, %{"subject" => "Dst"})

      for {at, hour} <- [{~U[2026-07-15 12:00:00Z], "15:00"}, {~U[2026-01-15 12:00:00Z], "14:00"}] do
        from(m in Message, where: m.uuid == ^message.uuid)
        |> Repo.update_all(set: [sent_at: at, metadata: Map.delete(message.metadata, @key)])

        Folders.lay_out_sent(Repo.get!(Message, message.uuid), ctx.alice_box)
        refreshed = Repo.get!(Message, message.uuid)

        assert Repo.get!(Folder, refreshed.metadata[@key]).name ==
                 Calendar.strftime(at, "%Y-%m-%d ") <> hour <> " — Dst"
      end
    end
  end

  describe "drafts" do
    @describetag skip: @no_managed

    test "a delayed draft filing leaves a snapshot already named by sent mail alone", ctx do
      storage!(:move)
      {message, _log} = with_log(fn -> send_data(ctx) end)
      file = snapshot(message)
      assert file.folder_uuid == nil
      Application.delete_env(:phoenix_kit_inbox, :folder_test_fail)

      assert :ok = Folders.lay_out_draft(ctx.alice_box, [file.uuid])
      assert Storage.get_file(file.uuid).folder_uuid == nil

      Folders.lay_out_sent(message, ctx.alice_box)
      assert Folders.laid_out?(message)
    end

    test "a draft's new snapshots are in mailbox / Drafts; the key is not written", ctx do
      draft = save_draft(ctx, data_opts("draft bytes"))
      file = snapshot(draft)

      assert chain(file) == [mailbox_folder(ctx.alice_box), "Drafts"]
      refute Map.has_key?(draft.metadata, @key)

      # Saving again with the same file adds no folder and moves nothing.
      before = library_folders()
      kept = save_draft(ctx, %{"uuid" => draft.uuid, "subject" => "Again"}, [])
      assert snapshot(kept).folder_uuid == file.folder_uuid
      assert library_folders() == before

      # Another draft shares the Drafts folder.
      other = save_draft(ctx, data_opts("other draft"))
      assert snapshot(other).folder_uuid == file.folder_uuid
    end

    test "sending the draft moves its snapshot (same file) into the message's folder", ctx do
      draft = save_draft(ctx, data_opts("to send"))
      file = snapshot(draft)

      sent = send_to(ctx, %{"uuid" => draft.uuid}, [])
      moved = snapshot(sent)

      assert moved.uuid == file.uuid
      assert [_, _, name] = chain(moved)
      assert name =~ " — Files"
      assert sent.metadata[@key] == moved.folder_uuid
    end

    test "a draft's snapshot another sent message names stays in Drafts and is linked", ctx do
      first = save_draft(ctx, data_opts("shared by two drafts"))
      file = snapshot(first)

      second = save_draft(ctx, %{"attachments" => [%{"file_uuid" => file.uuid}]}, [])
      assert snapshot(second).uuid == file.uuid

      # The second goes out, but its filing fails: the file stays in Drafts.
      storage!(:move)
      capture_log(fn -> send_to(ctx, %{"uuid" => second.uuid}, []) end)
      Application.delete_env(:phoenix_kit_inbox, :folder_test_fail)
      assert snapshot(second).folder_uuid == file.folder_uuid
      earlier(second, 60)

      # The first goes out: an earlier sent message names the file, so it is only linked.
      sent = send_to(ctx, %{"uuid" => first.uuid, "subject" => "First"}, [])

      assert snapshot(sent).folder_uuid == file.folder_uuid
      assert chain(file.folder_uuid) == [mailbox_folder(ctx.alice_box), "Drafts"]
      assert [%{file_uuid: linked}] = links_in(sent.metadata[@key])
      assert linked == file.uuid

      # The second one is filed afterwards (what a maintenance run does): the file is its own.
      Folders.lay_out_sent(Repo.get!(Message, second.uuid), ctx.alice_box)
      second = Repo.get!(Message, second.uuid)
      assert snapshot(second).folder_uuid == second.metadata[@key]
      assert [_, _, name] = chain(snapshot(second))
      assert name =~ " — Files"
    end

    test "a draft saved before its mailbox was renamed is still the message's own", ctx do
      box = shared_mailbox_fixture(ctx.alice, %{name: "Support", slug: "support-d"})

      {:ok, draft} =
        Messages.save_draft(ctx.scope, box, %{"subject" => "Old"}, data_opts("renamed draft"))

      assert chain(snapshot(draft)) == ["Support (support-d)", "Drafts"]

      renamed = box |> Ecto.Changeset.change(name: "Sales") |> Repo.update!()

      {:ok, sent} =
        Messages.send_message(
          ctx.scope,
          renamed,
          %{"uuid" => draft.uuid, "to" => "@#{ctx.bob.username}", "subject" => "New"},
          []
        )

      assert [mailbox, _month, name] = chain(snapshot(sent))
      assert mailbox == "Sales (support-d)"
      assert name =~ " — New"
    end

    test "a failing Drafts filing leaves the draft saved and no folder", ctx do
      storage!(:move)

      {draft, log} = with_log(fn -> save_draft(ctx, data_opts("unfiled draft")) end)

      assert draft.status == "draft"
      assert log =~ "could not file the attachments"
      assert library_folders() == []
      assert snapshot(draft).folder_uuid == nil
    end
  end

  describe "inside a caller's transaction" do
    @describetag skip: @no_managed

    test "a send commits with the caller's work, and files nothing", ctx do
      storage!(:move)

      result =
        Repo.transaction(fn ->
          {:ok, message} =
            Messages.send_message(
              ctx.scope,
              ctx.alice_box,
              %{"to" => "@#{ctx.bob.username}", "subject" => "Inside"},
              data_opts("inside")
            )

          message
        end)

      assert {:ok, message} = result
      assert Repo.get(Message, message.uuid)
      assert snapshot(message).folder_uuid == nil
      assert library_folders() == []

      # Nothing in the way, and still nothing is filed there.
      Application.delete_env(:phoenix_kit_inbox, :folder_test_fail)

      assert {:ok, _} =
               Repo.transaction(fn ->
                 draft = save_draft(ctx, data_opts("inside draft"))
                 assert snapshot(draft).folder_uuid == nil
               end)

      assert library_folders() == []
    end
  end

  describe "links" do
    @describetag skip: @no_managed

    test "a sent message's file attached to a draft (way 2) is linked, not moved", ctx do
      original = send_data(ctx, %{"subject" => "Original"})
      file = snapshot(original)

      draft = save_draft(ctx, %{"attachments" => [%{"file_uuid" => file.uuid}]}, [])
      sent = send_to(ctx, %{"uuid" => draft.uuid, "subject" => "Again"}, [])

      assert snapshot(sent).uuid == file.uuid
      assert Storage.get_file(file.uuid).folder_uuid == original.metadata[@key]
      assert sent.metadata[@key] != original.metadata[@key]
      assert [%{file_uuid: linked}] = links_in(sent.metadata[@key])
      assert linked == file.uuid
    end

    test "a forward (way 6) is linked in the new message's folder", ctx do
      original = send_data(ctx, %{"subject" => "Original"})
      file = snapshot(original)

      {:ok, forward} =
        Messages.send_message(
          ctx.bob_scope,
          ctx.bob_box,
          %{
            "to" => "@#{ctx.alice.username}",
            "subject" => "Fwd",
            "attachments" => [%{"file_uuid" => file.uuid}]
          },
          []
        )

      forward = Repo.get!(Message, forward.uuid)

      assert Storage.get_file(file.uuid).folder_uuid == original.metadata[@key]
      assert [mailbox, _, name] = chain(forward.metadata[@key])
      assert mailbox == mailbox_folder(ctx.bob_box)
      assert name =~ " — Fwd"
      assert [%{file_uuid: linked}] = links_in(forward.metadata[@key])
      assert linked == file.uuid
    end

    test "a link a rival made first does not break the filing", ctx do
      original = send_data(ctx, %{"subject" => "Original"})
      file = snapshot(original)
      storage!(:rival_link)

      {:ok, forward} =
        Messages.send_message(
          ctx.bob_scope,
          ctx.bob_box,
          %{
            "to" => "@#{ctx.alice.username}",
            "subject" => "Fwd",
            "attachments" => [%{"file_uuid" => file.uuid}]
          },
          []
        )

      forward = Repo.get!(Message, forward.uuid)
      assert [_] = links_in(forward.metadata[@key])
    end

    test "a failing link rolls the filing back; the first message's folders stay", ctx do
      original = send_data(ctx, %{"subject" => "Original"})
      file = snapshot(original)
      before = library_folders()
      storage!(:link)

      {forward, log} =
        with_log(fn ->
          {:ok, forward} =
            Messages.send_message(
              ctx.bob_scope,
              ctx.bob_box,
              %{
                "to" => "@#{ctx.alice.username}",
                "subject" => "Fwd",
                "attachments" => [%{"file_uuid" => file.uuid}]
              },
              []
            )

          Repo.get!(Message, forward.uuid)
        end)

      assert forward.status == "sent"
      assert log =~ "could not file the attachments"
      refute Map.has_key?(forward.metadata, @key)
      assert library_folders() == before
    end
  end

  describe "a core without managed libraries" do
    test "files nothing and the send works", ctx do
      Application.put_env(:phoenix_kit_inbox, :storage_libraries, NoManagedLibraries)

      message = send_data(ctx)

      assert snapshot(message).folder_uuid == nil
      refute Map.has_key?(message.metadata, @key)
      assert library_folders() == []

      draft = save_draft(ctx, data_opts("plain draft"))
      assert snapshot(draft).folder_uuid == nil
    end
  end
end
