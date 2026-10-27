defmodule PhoenixKitInbox.AttachmentsLinkedTest do
  @moduledoc """
  Snapshots that name the stored objects of a file Storage already holds
  (`Storage.link_copy/3`) instead of writing the bytes again, and the full
  copy they fall back to when the core has no `link_copy/3`, refuses the
  donor or finds none. The tests that need `link_copy/3` are skipped on a
  core without it.
  """

  use PhoenixKitInbox.LiveCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Message
  alias PhoenixKitInbox.Test.Repo

  Code.ensure_loaded(Storage)

  # `false` where the core has `link_copy/3`, else the reason to skip.
  @no_link_copy if(function_exported?(Storage, :link_copy, 3),
                  do: false,
                  else: "needs a PhoenixKit core with Storage.link_copy/3"
                )

  # A core that has `store_file_in_buckets/7` only.
  defmodule NoLinkStorage do
    @moduledoc false
    defdelegate store_file_in_buckets(a, b, c, d, e, f, g), to: PhoenixKit.Modules.Storage
  end

  # A core whose `link_copy/3` always answers with `:reason`.
  defmodule RefusingStorage do
    @moduledoc false
    defdelegate store_file_in_buckets(a, b, c, d, e, f, g), to: PhoenixKit.Modules.Storage

    def link_copy(_donor, _user_uuid, _opts) do
      send(Application.get_env(:phoenix_kit_inbox, :linked_test_pid), :link_copy_called)
      {:error, Application.get_env(:phoenix_kit_inbox, :linked_test_reason)}
    end
  end

  # A core whose `link_copy/3` does what the test says (`:linked_test_mode`)
  # and reports each donor it is asked about.
  defmodule ScriptedStorage do
    @moduledoc false
    def store_file_in_buckets(a, b, c, d, e, f, g) do
      send(Application.get_env(:phoenix_kit_inbox, :linked_test_pid), :stored)
      Storage.store_file_in_buckets(a, b, c, d, e, f, g)
    end

    def link_copy(donor, user_uuid, opts) do
      send(Application.get_env(:phoenix_kit_inbox, :linked_test_pid), {:link_copy, donor.uuid})

      case Application.get_env(:phoenix_kit_inbox, :linked_test_mode) do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        :real -> apply(PhoenixKit.Modules.Storage, :link_copy, [donor, user_uuid, opts])
        :raise -> raise "core bug"
        :exit -> exit(:timeout)
        :throw -> throw(:oops)
        :donor_itself -> {:ok, donor}
        {:answer, answer} -> answer
      end
    end
  end

  setup :storage_setup

  setup do
    enable_inbox!()

    alice = user_fixture()
    bob = user_fixture()
    {:ok, alice_box} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, _} = Mailboxes.ensure_user_mailbox(bob)

    on_exit(fn ->
      for key <- [:storage_module, :linked_test_pid, :linked_test_reason, :linked_test_mode],
          do: Application.delete_env(:phoenix_kit_inbox, key)
    end)

    %{alice: alice, bob: bob, alice_box: alice_box, scope: scope_for(alice)}
  end

  # What Storage holds once its variants are made: no job runs in the suite,
  # so a stored file would stay "processing", which a donor may not be.
  defp media_file(user, content, opts) do
    user
    |> stored_file_fixture(content, opts)
    |> Ecto.Changeset.change(status: "active")
    |> Repo.update!()
  end

  defp send_to(ctx, extra, opts \\ []) do
    attrs = Map.merge(%{"to" => "@#{ctx.bob.username}", "subject" => "Files"}, extra)
    Messages.send_message(ctx.scope, ctx.alice_box, attrs, opts)
  end

  defp attach(file), do: %{"attachments" => [%{"file_uuid" => file.uuid}]}

  defp send_data(ctx, binary, filename \\ "data.txt") do
    {:ok, message} = send_to(ctx, %{}, attachments_data: [%{binary: binary, filename: filename}])
    [row] = Attachments.list_for_message(message.uuid)
    {row, Storage.get_file(row.file_uuid)}
  end

  defp send_file(ctx, file) do
    {:ok, message} = send_to(ctx, attach(file))
    [row] = Attachments.list_for_message(message.uuid)
    {row, Storage.get_file(row.file_uuid)}
  end

  defp original_key(file) do
    file.uuid
    |> Storage.list_file_instances()
    |> Enum.find(&(&1.variant_name == "original"))
    |> Map.fetch!(:file_name)
  end

  defp sha256(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  defp read_sha(row) do
    {:ok, path} = Attachments.read_file(row)
    content = File.read!(path)
    File.rm(path)
    sha256(content)
  end

  defp script(mode) do
    Application.put_env(:phoenix_kit_inbox, :storage_module, ScriptedStorage)
    Application.put_env(:phoenix_kit_inbox, :linked_test_pid, self())
    Application.put_env(:phoenix_kit_inbox, :linked_test_mode, mode)
  end

  # Every stored object of the local test bucket.
  defp bucket_objects do
    %{rows: [[root]]} =
      Repo.query!("SELECT endpoint FROM phoenix_kit_buckets WHERE enabled LIMIT 1")

    root |> Path.join("**") |> Path.wildcard() |> Enum.filter(&File.regular?/1) |> Enum.sort()
  end

  # The donors `link_copy/3` was asked about since the last call, in order.
  # Whether bytes were written since the last call.
  defp stored? do
    receive do
      :stored ->
        _ = stored?()
        true
    after
      0 -> false
    end
  end

  defp donors_asked(acc \\ []) do
    receive do
      {:link_copy, uuid} -> donors_asked([uuid | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A file Storage has finished with (no job runs in the suite).
  defp activate(file), do: file |> Ecto.Changeset.change(status: "active") |> Repo.update!()

  # Another record of the same stored objects, as if a second user had
  # uploaded the same bytes (Storage hands the first upload back instead).
  defp clone_file(file, user) do
    uuid = UUIDv7.generate()

    file
    |> Ecto.put_meta(state: :built)
    |> Map.merge(%{
      uuid: uuid,
      user_uuid: user.uuid,
      user_file_checksum: "clone:#{uuid}",
      inserted_at: DateTime.add(file.inserted_at, 1)
    })
    |> Repo.insert!()
  end

  defp library_uuid do
    {:ok, library} = Attachments.ensure_library()
    to_string(library.uuid)
  end

  defp inbox_files do
    case Libraries.get_hidden_library_by_slug(Attachments.library_slug()) do
      nil -> []
      library -> files_in_library(library.uuid)
    end
  end

  defp inbox_prefix do
    {:ok, library} = Attachments.ensure_library()
    library.key_prefix <> "/"
  end

  describe "ways 3 and 4: a Storage file" do
    @describetag skip: @no_link_copy

    test "the snapshot names the original's objects, and outlives the original", ctx do
      original = media_file(ctx.alice, "quarterly numbers", filename: "q3.txt")

      {row, snapshot} = send_file(ctx, original)

      assert snapshot.uuid != original.uuid
      assert to_string(snapshot.library_uuid) == library_uuid()
      assert snapshot.file_path == original.file_path
      assert original_key(snapshot) == original_key(original)
      assert read_sha(row) == sha256("quarterly numbers")

      # The original goes to the trash, then is deleted completely.
      {:ok, trashed} = Storage.trash_file(original)
      assert read_sha(row) == sha256("quarterly numbers")

      {:ok, _} = Storage.delete_file_completely(trashed)
      assert Storage.get_file(original.uuid) == nil
      assert read_sha(row) == sha256("quarterly numbers")
    end

    test "attachments_authorized: (way 4) links too", ctx do
      theirs = media_file(ctx.bob, "bob's file", filename: "b.txt")

      {:ok, message} = send_to(ctx, %{}, attachments_authorized: [theirs.uuid])
      [row] = Attachments.list_for_message(message.uuid)
      snapshot = Storage.get_file(row.file_uuid)

      assert to_string(snapshot.library_uuid) == library_uuid()
      assert snapshot.file_path == theirs.file_path
      assert snapshot.user_uuid == ctx.alice.uuid

      {:ok, _} = Storage.delete_file_completely(theirs)
      assert read_sha(row) == sha256("bob's file")
    end

    test "the row keeps the attachment's own name and content type", ctx do
      original = media_file(ctx.alice, "named", filename: "orig.txt")

      {row, snapshot} = send_file(ctx, original)

      assert row.filename == "orig.txt"
      assert row.content_type == "text/plain"
      assert snapshot.original_file_name == "orig.txt"
    end
  end

  describe "the download route" do
    @describetag skip: @no_link_copy

    test "serves the bytes of a linked snapshot after the original is gone",
         %{conn: conn} = ctx do
      original =
        media_file(ctx.alice, "%PDF linked", filename: "l.pdf", mime_type: "application/pdf")

      {row, _snapshot} = send_file(ctx, original)
      {:ok, _} = Storage.delete_file_completely(original)

      conn =
        conn
        |> put_test_scope(scope_for(ctx.bob))
        |> get(PhoenixKitInbox.Paths.attachment(row.uuid))

      assert conn.status == 200
      assert conn.resp_body == "%PDF linked"
    end
  end

  describe "ways 1 and 5: bytes" do
    @describetag skip: @no_link_copy

    test "another user's file is a donor, and the snapshot is the sender's", ctx do
      theirs = media_file(ctx.bob, "bob's bytes", filename: "b.txt")
      objects_before = bucket_objects()

      {row, snapshot} = send_data(ctx, "bob's bytes")

      assert snapshot.file_path == theirs.file_path
      assert bucket_objects() == objects_before
      assert snapshot.user_uuid == ctx.alice.uuid
      assert read_sha(row) == sha256("bob's bytes")
    end

    test "the sender's own file is offered first", ctx do
      script({:answer, {:error, :donor_changed}})
      theirs = media_file(ctx.bob, "shared bytes", filename: "b.txt")
      mine = clone_file(theirs, ctx.alice)

      {_row, _snapshot} = send_data(ctx, "shared bytes")

      assert_received {:link_copy, first}
      assert_received {:link_copy, second}
      assert [first, second] == [mine.uuid, theirs.uuid]
    end

    test "a donor the module's filter excludes is never offered to the core", ctx do
      script(:real)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for {change, content} <- [
            {[trashed_at: now], "trashed at"},
            {[system_managed: true], "managed"},
            {[edit_state: "pending"], "editing"},
            {[status: "trashed"], "status"}
          ] do
        donor = media_file(ctx.alice, content, filename: "d.txt")
        donor |> Ecto.Changeset.change(change) |> Repo.update!()

        {row, snapshot} = send_data(ctx, content)

        refute_received {:link_copy, _}
        assert snapshot.file_path != donor.file_path
        assert read_sha(row) == sha256(content)
      end
    end

    test "one refused Media donor ends the Media group", ctx do
      script({:answer, {:error, :donor_unavailable}})
      theirs = media_file(ctx.bob, "two donors", filename: "b.txt")
      clone_file(theirs, ctx.alice)

      {row, snapshot} = send_data(ctx, "two donors")

      assert_received {:link_copy, _}
      refute_received {:link_copy, _}
      assert String.starts_with?(snapshot.file_path, inbox_prefix())
      assert read_sha(row) == sha256("two donors")
    end

    test "a donor that changed under the caller does not end the group", ctx do
      script({:answer, {:error, :donor_changed}})
      theirs = media_file(ctx.bob, "changing", filename: "b.txt")
      clone_file(theirs, ctx.alice)

      send_data(ctx, "changing")

      assert_received {:link_copy, _}
      assert_received {:link_copy, _}
      refute_received {:link_copy, _}
    end

    test "an :incompatible answer ends a group of snapshots", ctx do
      {_row, first} = send_data(ctx, "snapshots")
      first = activate(first)
      clone_file(first, ctx.alice)
      script({:answer, {:error, :incompatible}})

      {row, _snapshot} = send_data(ctx, "snapshots")

      assert_received {:link_copy, _}
      refute_received {:link_copy, _}
      assert read_sha(row) == sha256("snapshots")
    end

    test "bytes only a snapshot holds are a link to that snapshot; Media comes first", ctx do
      script(:real)

      # New bytes: a full copy, under the module's own prefix.
      {_row, first} = send_data(ctx, "fresh bytes")
      assert String.starts_with?(first.file_path, inbox_prefix())
      assert donors_asked() == []
      assert stored?()
      first = activate(first)
      objects_before = bucket_objects()

      # The same bytes again: a link to that snapshot, no bytes written.
      {_row, second} = send_data(ctx, "fresh bytes")
      assert donors_asked() == [first.uuid]
      refute stored?()
      assert bucket_objects() == objects_before
      assert second.file_path == first.file_path
      assert second.uuid != first.uuid

      # Media gets the bytes: it is preferred to the snapshots.
      media = media_file(ctx.alice, "fresh bytes", filename: "m.txt")
      {_row, third} = send_data(ctx, "fresh bytes")
      assert donors_asked() == [media.uuid]
      assert third.file_path == media.file_path

      # Media drops them: a snapshot that names Media's keys (the second
      # link) is offered before the one under the module's prefix.
      {:ok, _} = Storage.delete_file_completely(media)
      {row, fourth} = send_data(ctx, "fresh bytes")
      assert [asked | _] = donors_asked()
      assert asked == third.uuid
      assert fourth.file_path == media.file_path
      assert read_sha(row) == sha256("fresh bytes")
    end

    test "a donor that is in the trash, system-managed or being edited is not used", ctx do
      for change <- [
            [status: "trashed", trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)],
            [system_managed: true],
            [edit_state: "pending"]
          ] do
        content = "only for #{inspect(change)}"
        media = media_file(ctx.alice, content, filename: "m.txt")
        media |> Ecto.Changeset.change(change) |> Repo.update!()

        {row, snapshot} = send_data(ctx, content)

        assert snapshot.file_path != media.file_path
        assert read_sha(row) == sha256(content)
      end
    end
  end

  describe "new bytes" do
    test "are a full copy", ctx do
      {row, snapshot} = send_data(ctx, "never seen before")

      assert String.starts_with?(snapshot.file_path, inbox_prefix())
      assert read_sha(row) == sha256("never seen before")
    end
  end

  describe "without a link" do
    test "a core without link_copy/3 copies in full", ctx do
      Application.put_env(:phoenix_kit_inbox, :storage_module, NoLinkStorage)
      original = media_file(ctx.alice, "full copy", filename: "f.txt")
      _media = media_file(ctx.alice, "full bytes", filename: "g.txt")

      {row, snapshot} = send_file(ctx, original)
      assert snapshot.file_path != original.file_path
      assert String.starts_with?(snapshot.file_path, inbox_prefix())
      assert read_sha(row) == sha256("full copy")

      {row, snapshot} = send_data(ctx, "full bytes")
      assert String.starts_with?(snapshot.file_path, inbox_prefix())
      assert read_sha(row) == sha256("full bytes")
    end

    for reason <- [:incompatible, :donor_unavailable, :donor_changed] do
      @tag skip: @no_link_copy
      test "an answer of #{reason} falls back to a full copy", ctx do
        Application.put_env(:phoenix_kit_inbox, :storage_module, RefusingStorage)
        Application.put_env(:phoenix_kit_inbox, :linked_test_pid, self())
        Application.put_env(:phoenix_kit_inbox, :linked_test_reason, unquote(reason))
        original = media_file(ctx.alice, "by file", filename: "f.txt")
        _media = media_file(ctx.alice, "by bytes", filename: "g.txt")

        {row, snapshot} = send_file(ctx, original)
        assert_received :link_copy_called
        assert snapshot.file_path != original.file_path
        assert read_sha(row) == sha256("by file")

        {row, snapshot} = send_data(ctx, "by bytes")
        assert_received :link_copy_called
        assert String.starts_with?(snapshot.file_path, inbox_prefix())
        assert read_sha(row) == sha256("by bytes")
      end
    end
  end

  describe "a core that misbehaves" do
    @describetag skip: @no_link_copy

    for mode <- [:raise, :exit, :throw, :donor_itself, {:answer, :weird}, {:answer, {:ok, nil}}] do
      test "#{inspect(mode)} is a full copy, for a file and for bytes", ctx do
        script(unquote(mode))
        original = media_file(ctx.alice, "by file", filename: "f.txt")
        media_file(ctx.alice, "by bytes", filename: "g.txt")

        {row, snapshot} = send_file(ctx, original)
        assert_received {:link_copy, _}
        assert snapshot.uuid != original.uuid
        assert snapshot.file_path != original.file_path
        assert to_string(snapshot.library_uuid) == library_uuid()
        assert read_sha(row) == sha256("by file")

        {row, snapshot} = send_data(ctx, "by bytes")
        assert_received {:link_copy, _}
        assert String.starts_with?(snapshot.file_path, inbox_prefix())
        assert read_sha(row) == sha256("by bytes")
      end
    end
  end

  describe "a send inside the caller's transaction" do
    @describetag skip: @no_link_copy

    test "the real core's refusals leave the full copies and a transaction that commits", ctx do
      script(:real)
      # Still "processing": the core answers :donor_unavailable.
      original = stored_file_fixture(ctx.alice, "in a transaction", filename: "t.txt")

      # An active donor whose original differs from what the upload is.
      donor = media_file(ctx.bob, "more", filename: "m.txt")
      [original_instance] = Storage.list_file_instances(donor.uuid)
      {:ok, _} = Storage.update_file_instance(original_instance, %{checksum: "changed"})

      assert {:ok, {{:ok, first}, {:ok, second}}} =
               Repo.transaction(fn ->
                 {send_to(ctx, attach(original)),
                  send_to(ctx, %{}, attachments_data: [%{binary: "more", filename: "m.txt"}])}
               end)

      assert [_, _] = donors_asked()

      for {message, content} <- [{first, "in a transaction"}, {second, "more"}] do
        [row] = Attachments.list_for_message(message.uuid)
        assert read_sha(row) == sha256(content)
        assert Storage.get_file(row.file_uuid).file_path != donor.file_path
      end

      assert Repo.aggregate(Message, :count) == 2
    end
  end

  describe "a send that fails" do
    @describetag skip: @no_link_copy

    test "removes the linked snapshot's row and leaves the donor's objects", ctx do
      original = media_file(ctx.alice, "keep me", filename: "k.txt")
      media = media_file(ctx.alice, "keep me too", filename: "k2.txt")

      assert {:error, %Ecto.Changeset{}} =
               send_to(
                 ctx,
                 Map.merge(attach(original), %{"subject" => String.duplicate("s", 501)}),
                 attachments_data: [%{binary: "keep me too", filename: "d.txt"}]
               )

      assert inbox_files() == []
      assert Repo.aggregate(Message, :count) == 0

      for donor <- [original, media] do
        assert Storage.get_file(donor.uuid)
        {:ok, path, _} = Storage.retrieve_file(donor.uuid)

        assert sha256(File.read!(path)) ==
                 sha256(if donor == original, do: "keep me", else: "keep me too")

        File.rm(path)
      end
    end
  end

  describe "the host's contract" do
    @describetag skip: @no_link_copy

    test "a linked snapshot is read without a scope, stays in the module's library, not system-managed",
         ctx do
      original = media_file(ctx.alice, "contract", filename: "c.txt")

      {:ok, message} = send_to(ctx, attach(original))
      [row] = Attachments.list_for_message(message.uuid)
      snapshot = Storage.get_file(row.file_uuid)

      assert snapshot.file_path == original.file_path
      assert to_string(snapshot.library_uuid) == library_uuid()
      assert snapshot.system_managed == false
      assert Attachments.safe_content_type(row.content_type) == "text/plain"
      assert read_sha(row) == sha256("contract")
    end
  end
end
