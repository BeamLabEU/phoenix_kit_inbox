defmodule PhoenixKitInbox.AttachmentsMaintenanceTest do
  @moduledoc """
  `mix phoenix_kit_inbox.relink_attachments` behind it: moving full-copy
  snapshots onto Media's stored objects in two phases, and filing the sent
  messages. Needs a core with `Storage.relink_file/3` (skipped without).
  """

  use PhoenixKitInbox.LiveCase, async: false

  import Ecto.Query

  alias Mix.Tasks.PhoenixKitInbox.RelinkAttachments, as: MixTask
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Attachments.Maintenance
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Attachment
  alias PhoenixKitInbox.Schemas.Message
  alias PhoenixKitInbox.Test.Repo

  Code.ensure_loaded(Storage)

  @moduletag skip:
               if(
                 function_exported?(Storage, :relink_file, 3) and
                   function_exported?(Storage, :delete_unreferenced_keys, 1),
                 do: false,
                 else: "needs a PhoenixKit core with Storage.relink_file/3"
               )

  # A core that stores bytes but has no `link_copy/3`: every snapshot is a
  # full copy, as the ones to be moved are.
  defmodule NoLinkStorage do
    @moduledoc false
    defdelegate store_file_in_buckets(a, b, c, d, e, f, g), to: PhoenixKit.Modules.Storage
  end

  # A host's folder hook that has no context to answer from.
  defmodule NilHook do
    @moduledoc false
    def folder(_message, _mailbox), do: nil
  end

  @bytes String.duplicate("the same bytes ", 200)

  setup :storage_setup

  setup do
    enable_inbox!()

    alice = user_fixture()
    bob = user_fixture()
    {:ok, alice_box} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, _} = Mailboxes.ensure_user_mailbox(bob)

    manifest = Path.join(System.tmp_dir!(), "relink_#{System.unique_integer([:positive])}.json")

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_inbox, :storage_module)
      Application.delete_env(:phoenix_kit_inbox, :attachment_folder)
      File.rm(manifest)
    end)

    %{alice: alice, bob: bob, alice_box: alice_box, scope: scope_for(alice), manifest: manifest}
  end

  # What Storage holds once its variants are made (no job runs in the suite).
  defp media_file(user, content) do
    user
    |> stored_file_fixture(content)
    |> Ecto.Changeset.change(status: "active")
    |> Repo.update!()
  end

  # The same bytes uploaded by a second user: Storage hands back a record of
  # its own on the same objects.
  defp second_media_file(user, content) do
    source = Path.join(System.tmp_dir!(), "inbox_src_#{System.unique_integer([:positive])}")
    File.write!(source, content)

    {:ok, file, :duplicate} =
      Storage.store_file_in_buckets(
        source,
        "document",
        user.uuid,
        sha256(content),
        "txt",
        "again.txt",
        mime_type: "text/plain"
      )

    File.rm(source)
    file |> Ecto.Changeset.change(status: "active") |> Repo.update!()
  end

  # A message with one full-copy snapshot of `content`.
  defp send_full_copy(ctx, content, filename \\ "data.txt") do
    Application.put_env(:phoenix_kit_inbox, :storage_module, NoLinkStorage)

    attrs = %{"to" => "@#{ctx.bob.username}", "subject" => "Files"}

    {:ok, message} =
      Messages.send_message(ctx.scope, ctx.alice_box, attrs,
        attachments_data: [%{binary: content, filename: filename}]
      )

    Application.delete_env(:phoenix_kit_inbox, :storage_module)
    [row] = Attachments.list_for_message(message.uuid)

    # Storage has finished with it (no job runs in the suite).
    file =
      row.file_uuid
      |> Storage.get_file()
      |> Ecto.Changeset.change(status: "active")
      |> Repo.update!()

    {message, row, file}
  end

  # The message as a failed filing would have left it: in no folder.
  defp unfile(message, file) do
    Repo.query!(
      "UPDATE phoenix_kit_inbox_messages SET metadata = metadata - 'attachments_folder_uuid' WHERE uuid = $1",
      [Ecto.UUID.dump!(message.uuid)]
    )

    Repo.query!("UPDATE phoenix_kit_files SET folder_uuid = NULL WHERE uuid = $1", [
      Ecto.UUID.dump!(file.uuid)
    ])
  end

  defp keys(file) do
    from(i in FileInstance, where: i.file_uuid == ^file.uuid, select: i.file_name)
    |> Repo.all()
    |> Enum.sort()
  end

  defp bucket_root do
    %{rows: [[root]]} =
      Repo.query!("SELECT endpoint FROM phoenix_kit_buckets WHERE enabled LIMIT 1")

    root
  end

  defp stored?(key), do: bucket_root() |> Path.join(key) |> File.exists?()

  defp prefix do
    {:ok, library} = Attachments.ensure_library()
    library.key_prefix <> "/"
  end

  defp read_manifest(path), do: path |> File.read!() |> Jason.decode!()

  defp sha256(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  defp read_sha(file) do
    {:ok, path} = Attachments.read_file(%Attachment{file_uuid: file.uuid})
    content = File.read!(path)
    File.rm(path)
    sha256(content)
  end

  # Two messages with the same bytes, and a record that names the first
  # snapshot's own keys: a group of three, with a donor in Media.
  defp group_fixture(ctx) do
    {m1, _, s1} = send_full_copy(ctx, @bytes)
    {m2, _, s2} = send_full_copy(ctx, @bytes)

    {:ok, s3} =
      Storage.link_copy(s1, ctx.alice.uuid, library_uuid: to_string(s1.library_uuid))

    donor = media_file(ctx.bob, @bytes)
    %{messages: [{m1, s1}, {m2, s2}], linked: s3, donor: donor}
  end

  describe "phase 1" do
    test "a dry run reports and writes nothing", ctx do
      %{messages: [{m1, s1}, {_m2, s2}], donor: donor} = group_fixture(ctx)
      unfile(m1, s1)
      before_keys = {keys(s1), keys(s2)}

      assert {:ok, report} = Maintenance.relink(manifest: ctx.manifest)

      assert %{apply?: false, records: 3, relinked: 3, without_donor: 0, errors: []} = report
      assert report.laid_out == 1
      # One stored object (the same bytes are the same key), named by all three.
      assert report.bytes == byte_size(@bytes)

      assert {keys(s1), keys(s2)} == before_keys
      assert Storage.get_file(s1.uuid).file_path == s1.file_path
      refute File.exists?(ctx.manifest)
      refute Storage.get_file(s1.uuid).file_path == donor.file_path
    end

    test "relinks the group, files the messages, writes the manifest and checks the bytes",
         ctx do
      %{messages: [{m1, s1}, {m2, s2}], linked: s3, donor: donor} = group_fixture(ctx)
      unfile(m1, s1)
      unfile(m2, s2)
      old_keys = (keys(s1) ++ keys(s2)) |> Enum.uniq() |> Enum.sort()
      assert Enum.all?(old_keys, &String.starts_with?(&1, prefix()))

      assert {:ok, report} = Maintenance.relink(apply: true, manifest: ctx.manifest)

      assert %{apply?: true, records: 3, relinked: 3, verified: 3, laid_out: 2, errors: []} =
               report

      assert report.bytes == byte_size(@bytes)

      for file <- [s1, s2, s3] do
        relinked = Storage.get_file(file.uuid)
        assert relinked.file_path == donor.file_path
        assert read_sha(relinked) == sha256(@bytes)
      end

      manifest = read_manifest(ctx.manifest)
      assert length(manifest["entries"]) == 3
      assert Enum.all?(manifest["entries"], &(&1["file_checksum"] == s1.file_checksum))
      assert Enum.all?(manifest["entries"], &(&1["verified"] == true))

      manifest_keys = manifest["entries"] |> Enum.flat_map(& &1["old_keys"]) |> Enum.uniq()
      assert Enum.sort(manifest_keys) == old_keys
      assert Enum.all?(manifest_keys, &String.starts_with?(&1, prefix()))

      # The old objects wait for phase 2.
      assert Enum.all?(old_keys, &stored?/1)

      for message <- [m1, m2] do
        assert Repo.get!(Message, message.uuid).metadata["attachments_folder_uuid"]
      end

      assert Storage.get_file(s1.uuid).folder_uuid
    end

    test "a second run changes nothing", ctx do
      %{messages: [{m1, s1}, _]} = group_fixture(ctx)
      unfile(m1, s1)
      assert {:ok, _} = Maintenance.relink(apply: true, manifest: ctx.manifest)
      first = File.read!(ctx.manifest)

      assert {:ok, report} = Maintenance.relink(apply: true, manifest: ctx.manifest)

      assert %{records: 0, relinked: 0, laid_out: 0, verified: 0, bytes: 0, errors: []} = report
      assert File.read!(ctx.manifest) == first
      assert {:ok, %{records: 0, laid_out: 0}} = Maintenance.relink()
    end

    test "a snapshot nobody else holds the bytes of stays", ctx do
      {_m, _row, snapshot} = send_full_copy(ctx, "bytes nobody else holds " <> @bytes)
      _other = media_file(ctx.bob, "different bytes")

      assert {:ok, report} = Maintenance.relink(apply: true, manifest: ctx.manifest)

      assert %{records: 0, relinked: 0, without_donor: 1, errors: []} = report
      assert Storage.get_file(snapshot.uuid).file_path == snapshot.file_path
      assert read_manifest(ctx.manifest)["entries"] == []
    end

    test "a file in the trash is no donor", ctx do
      {_m, _row, snapshot} = send_full_copy(ctx, @bytes)
      donor = media_file(ctx.bob, @bytes)

      donor
      |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      assert {:ok, %{records: 0, without_donor: 1}} = Maintenance.relink()
      assert Storage.get_file(snapshot.uuid).file_path == snapshot.file_path
    end

    test "applying needs a manifest", _ctx do
      assert {:error, :manifest_required} = Maintenance.relink(apply: true)
    end

    test "a manifest that is not one is not overwritten", ctx do
      File.write!(ctx.manifest, "not json")
      _ = group_fixture(ctx)

      assert {:error, {:manifest_unreadable, _}} =
               Maintenance.relink(apply: true, manifest: ctx.manifest)

      assert File.read!(ctx.manifest) == "not json"
    end
  end

  defp donor_key(file) do
    file.uuid
    |> Storage.list_file_instances()
    |> Enum.find(&(&1.variant_name == "original"))
    |> Map.fetch!(:file_name)
  end

  # An instance of `file` at `key`, with an object of `size` bytes in the bucket.
  defp add_instance(file, name, key, size) do
    path = Path.join(bucket_root(), key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, String.duplicate("v", size))

    %FileInstance{}
    |> FileInstance.changeset(%{
      variant_name: name,
      file_name: key,
      mime_type: "image/jpeg",
      ext: "jpg",
      checksum: "variant-#{System.unique_integer([:positive])}",
      size: size,
      file_uuid: file.uuid
    })
    |> Repo.insert!()
  end

  defp rewrite_manifest(path, fun) do
    manifest = read_manifest(path)
    File.write!(path, Jason.encode!(%{manifest | "entries" => fun.(manifest["entries"])}))
  end

  defp quiet_shell do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
  end

  describe "phase 1, the rest" do
    test "a dry run files nothing and makes no library", ctx do
      assert Storage.Libraries.get_hidden_library_by_slug(Attachments.library_slug()) == nil
      assert {:ok, %{records: 0, relinked: 0, laid_out: 0}} = Maintenance.relink()
      assert Storage.Libraries.get_hidden_library_by_slug(Attachments.library_slug()) == nil

      %{messages: [{m1, s1}, _]} = group_fixture(ctx)
      unfile(m1, s1)
      assert {:ok, %{laid_out: 1}} = Maintenance.relink()

      refute Repo.get!(Message, m1.uuid).metadata["attachments_folder_uuid"]
      refute Storage.get_file(s1.uuid).folder_uuid
    end

    test "a manifest that cannot be written moves nothing", ctx do
      {_m, _row, snapshot} = send_full_copy(ctx, @bytes)
      _donor = media_file(ctx.bob, @bytes)

      path =
        Path.join([
          System.tmp_dir!(),
          "no-such-dir-#{System.unique_integer([:positive])}",
          "m.json"
        ])

      assert {:error, {:manifest_unwritable, _}} = Maintenance.relink(apply: true, manifest: path)
      assert Storage.get_file(snapshot.uuid).file_path == snapshot.file_path
    end

    test "a manifest of another library is refused before anything moves", ctx do
      %{messages: [{_, s1}, _]} = group_fixture(ctx)

      File.write!(
        ctx.manifest,
        Jason.encode!(%{"library_uuid" => UUIDv7.generate(), "entries" => []})
      )

      assert {:error, :manifest_other_library} =
               Maintenance.relink(apply: true, manifest: ctx.manifest)

      assert Storage.get_file(s1.uuid).file_path == s1.file_path
    end

    test "bytes that do not read back are left unverified, and a later run checks them", ctx do
      quiet_shell()
      {_m, _row, snapshot} = send_full_copy(ctx, @bytes)
      donor = media_file(ctx.bob, @bytes)
      object = Path.join(bucket_root(), donor_key(donor))
      File.write!(object, "the object was damaged")

      assert {:ok, report} = Maintenance.relink(apply: true, manifest: ctx.manifest)

      assert %{relinked: 1, verified: 0} = report
      assert [error] = report.errors
      assert error =~ snapshot.uuid
      assert [%{"verified" => false}] = read_manifest(ctx.manifest)["entries"]

      assert {:shutdown, 1} =
               catch_exit(
                 MixTask.run([
                   "--apply",
                   "--manifest",
                   ctx.manifest
                 ])
               )

      # Phase 2 leaves what an unverified record names.
      assert {:ok, %{keys: 0, deleted: 0, unverified: 1}} = Maintenance.purge_old(ctx.manifest)

      File.write!(object, @bytes)

      assert {:ok, %{relinked: 0, verified: 1, errors: []}} =
               Maintenance.relink(apply: true, manifest: ctx.manifest)

      assert [%{"verified" => true}] = read_manifest(ctx.manifest)["entries"]
      assert {:ok, %{deleted: 1}} = Maintenance.purge_old(ctx.manifest)
    end

    test "a donor that cannot be used is passed over for the next", ctx do
      {_m, _row, snapshot} = send_full_copy(ctx, @bytes)
      broken = media_file(ctx.bob, @bytes)
      _good = second_media_file(user_fixture(), @bytes)
      Repo.delete_all(from(i in FileInstance, where: i.file_uuid == ^broken.uuid))

      assert {:ok, %{relinked: 1, errors: []}} =
               Maintenance.relink(apply: true, manifest: ctx.manifest)

      assert read_sha(Storage.get_file(snapshot.uuid)) == sha256(@bytes)
    end

    test "a snapshot that does not qualify is skipped, not an error", ctx do
      quiet_shell()
      {_m, _row, snapshot} = send_full_copy(ctx, @bytes)
      _donor = media_file(ctx.bob, @bytes)
      snapshot |> Ecto.Changeset.change(status: "processing") |> Repo.update!()

      assert {:ok, report} = Maintenance.relink(apply: true, manifest: ctx.manifest)

      assert %{records: 0, relinked: 0, errors: []} = report
      assert [text] = report.skipped
      assert text =~ snapshot.uuid

      assert :ok =
               MixTask.run([
                 "--apply",
                 "--manifest",
                 ctx.manifest
               ])
    end

    test "a record is on the manifest before it is moved, so a failed move leaves its keys",
         ctx do
      {_m, _row, snapshot} = send_full_copy(ctx, @bytes)
      donor = media_file(ctx.bob, @bytes)
      Repo.delete_all(from(i in FileInstance, where: i.file_uuid == ^donor.uuid))
      keys = keys(snapshot)

      assert {:ok, report} = Maintenance.relink(apply: true, manifest: ctx.manifest)

      assert %{relinked: 0} = report
      assert [error] = report.errors
      assert error =~ snapshot.uuid

      assert [%{"uuid" => uuid, "old_keys" => ^keys, "verified" => false}] =
               read_manifest(ctx.manifest)["entries"]

      assert uuid == snapshot.uuid
    end

    test "an entry whose record was deleted is marked gone, not an error", ctx do
      quiet_shell()
      {_m, _row, snapshot} = send_full_copy(ctx, @bytes)
      donor = media_file(ctx.bob, @bytes)
      File.write!(Path.join(bucket_root(), donor_key(donor)), "damaged")
      assert {:ok, %{verified: 0}} = Maintenance.relink(apply: true, manifest: ctx.manifest)
      old_keys = hd(read_manifest(ctx.manifest)["entries"])["old_keys"]

      Repo.delete_all(from(f in Storage.File, where: f.uuid == ^snapshot.uuid))

      assert {:ok, %{errors: []}} = Maintenance.relink(apply: true, manifest: ctx.manifest)
      assert [%{"gone" => true, "verified" => false}] = read_manifest(ctx.manifest)["entries"]
      assert :ok = MixTask.run(["--apply", "--manifest", ctx.manifest])

      # Its keys are deleted like a verified record's, as nothing names them now.
      assert {:ok, %{deleted: deleted}} = Maintenance.purge_old(ctx.manifest)
      assert deleted == length(old_keys)
      refute Enum.any?(old_keys, &stored?/1)
    end

    test "a manifest in use is not taken, and the lock goes when the run ends", ctx do
      %{messages: [{_, s1}, _]} = group_fixture(ctx)
      File.write!(ctx.manifest <> ".lock", "")

      assert {:error, {:manifest_locked, _}} =
               Maintenance.relink(apply: true, manifest: ctx.manifest)

      assert Storage.get_file(s1.uuid).file_path == s1.file_path
      File.rm!(ctx.manifest <> ".lock")

      assert {:ok, %{relinked: 3}} = Maintenance.relink(apply: true, manifest: ctx.manifest)
      refute File.exists?(ctx.manifest <> ".lock")
      assert Path.wildcard(ctx.manifest <> ".*.tmp") == []
    end

    test "a manifest of a format this version does not know is refused", ctx do
      %{messages: [{_, s1}, _]} = group_fixture(ctx)
      assert {:ok, _} = Maintenance.relink(apply: true, manifest: ctx.manifest)
      manifest = read_manifest(ctx.manifest)
      File.write!(ctx.manifest, Jason.encode!(%{manifest | "version" => 2}))

      assert {:error, :manifest_version} = Maintenance.purge_old(ctx.manifest)
      assert {:error, :manifest_version} = Maintenance.relink(apply: true, manifest: ctx.manifest)
      assert Storage.get_file(s1.uuid)
    end

    test "an error the task does not know is printed, not a crash" do
      assert MixTask.error_message(:something_new) =~ "Failed: :something_new"
    end

    test "only old keys under the library's prefix go on the manifest", ctx do
      {_m, _row, snapshot} = send_full_copy(ctx, @bytes)
      _donor = media_file(ctx.bob, @bytes)
      add_instance(snapshot, "other", "somebody-else/old.bin", 5)
      add_instance(snapshot, "sneaky", prefix() <> "../escape.bin", 5)

      assert {:ok, %{relinked: 1}} = Maintenance.relink(apply: true, manifest: ctx.manifest)

      [entry] = read_manifest(ctx.manifest)["entries"]
      assert Enum.all?(entry["old_keys"], &String.starts_with?(&1, prefix()))
      refute Enum.any?(entry["old_keys"], &String.contains?(&1, ".."))
    end

    test "messages are filed when the host's hook has nothing to answer", ctx do
      Application.put_env(:phoenix_kit_inbox, :attachment_folder, {NilHook, :folder})
      {message, _row, snapshot} = send_full_copy(ctx, @bytes)
      _donor = media_file(ctx.bob, @bytes)
      unfile(message, snapshot)

      assert {:ok, %{laid_out: 1, errors: []}} =
               Maintenance.relink(apply: true, manifest: ctx.manifest)

      assert Repo.get!(Message, message.uuid).metadata["attachments_folder_uuid"]
    end

    test "variants' keys: the snapshot's go on the manifest and are deleted, the donor's stay",
         ctx do
      {_m, _row, snapshot} = send_full_copy(ctx, @bytes)
      donor = media_file(ctx.bob, @bytes)
      variant_key = prefix() <> "variants/thumb.jpg"
      add_instance(snapshot, "thumbnail", variant_key, 111)
      donor_variant = "media-variants/#{System.unique_integer([:positive])}/thumb.jpg"
      add_instance(donor, "thumbnail", donor_variant, 77)

      assert {:ok, report} = Maintenance.relink(apply: true, manifest: ctx.manifest)
      assert report.bytes == byte_size(@bytes) + 111

      [entry] = read_manifest(ctx.manifest)["entries"]
      assert variant_key in entry["old_keys"]

      assert {:ok, %{deleted: 2}} = Maintenance.purge_old(ctx.manifest)
      refute stored?(variant_key)
      assert stored?(donor_variant)
      assert stored?(donor_key(donor))
    end
  end

  describe "phase 2" do
    setup ctx do
      fixture = group_fixture(ctx)
      assert {:ok, _} = Maintenance.relink(apply: true, manifest: ctx.manifest)

      old_keys =
        ctx.manifest
        |> read_manifest()
        |> Map.fetch!("entries")
        |> Enum.flat_map(& &1["old_keys"])

      Map.merge(fixture, %{old_keys: Enum.uniq(old_keys)})
    end

    test "deletes the old keys nothing names", ctx do
      assert ctx.old_keys != []
      assert Enum.all?(ctx.old_keys, &stored?/1)

      assert {:ok, report} = Maintenance.purge_old(ctx.manifest)

      assert %{keys: keys, kept: 0, deleted: keys, outside_prefix: 0, errors: []} = report
      assert keys == length(ctx.old_keys)
      refute Enum.any?(ctx.old_keys, &stored?/1)

      # The donor's object is still there, and the snapshots still read.
      assert stored?(ctx.donor.file_path)
      [{_, s1}, _] = ctx.messages
      assert read_sha(Storage.get_file(s1.uuid)) == sha256(@bytes)

      assert {:ok, %{deleted: 0, already_gone: 1}} = Maintenance.purge_old(ctx.manifest)
    end

    test "a key a record named again stays", ctx do
      [key | rest] = ctx.old_keys

      %FileInstance{}
      |> FileInstance.changeset(%{
        variant_name: "probe",
        file_name: key,
        mime_type: "text/plain",
        ext: "txt",
        checksum: sha256(@bytes),
        size: byte_size(@bytes),
        file_uuid: ctx.donor.uuid
      })
      |> Repo.insert!()

      assert {:ok, report} = Maintenance.purge_old(ctx.manifest)

      assert report.kept == 1
      assert report.deleted == length(rest)
      assert stored?(key)
      refute Enum.any?(rest, &stored?/1)
    end

    test "a key outside the library's prefix is dropped", ctx do
      stray = "somebody-else/stray.bin"
      stray_path = Path.join(bucket_root(), stray)
      File.mkdir_p!(Path.dirname(stray_path))
      File.write!(stray_path, "not ours")

      manifest = read_manifest(ctx.manifest)
      [first | rest] = manifest["entries"]
      forged = [%{first | "old_keys" => [stray | first["old_keys"]]} | rest]
      File.write!(ctx.manifest, Jason.encode!(%{manifest | "entries" => forged}))

      assert {:ok, report} = Maintenance.purge_old(ctx.manifest)

      assert report.outside_prefix == 1
      assert stored?(stray)
      refute Enum.any?(ctx.old_keys, &stored?/1)
    end

    test "an entry that did not verify is left alone", ctx do
      manifest = read_manifest(ctx.manifest)
      entries = Enum.map(manifest["entries"], &Map.put(&1, "verified", false))
      File.write!(ctx.manifest, Jason.encode!(%{manifest | "entries" => entries}))

      assert {:ok, report} = Maintenance.purge_old(ctx.manifest)

      assert %{deleted: 0, keys: 0} = report
      assert report.unverified == length(ctx.old_keys)
      assert Enum.all?(ctx.old_keys, &stored?/1)
    end

    test "a key with a dot segment cannot reach another object", ctx do
      outside = ctx.donor |> donor_key()
      forged = prefix() <> "../" <> outside
      assert stored?(forged)

      rewrite_manifest(ctx.manifest, fn [first | rest] ->
        [%{first | "old_keys" => [forged | first["old_keys"]]} | rest]
      end)

      assert {:ok, report} = Maintenance.purge_old(ctx.manifest)

      assert report.outside_prefix == 1
      assert stored?(outside)
    end

    test "a key an unverified entry names is not deleted, whoever else names it", ctx do
      rewrite_manifest(ctx.manifest, fn [first | rest] ->
        [Map.put(first, "verified", false) | rest]
      end)

      assert {:ok, report} = Maintenance.purge_old(ctx.manifest)

      assert report.deleted == 0
      assert Enum.all?(ctx.old_keys, &stored?/1)
    end

    test "an entry not marked verified is unverified, one without a uuid is reported", ctx do
      rewrite_manifest(ctx.manifest, fn entries ->
        entries
        |> Enum.map(&Map.put(&1, "verified", nil))
        |> Kernel.++([%{"old_keys" => ["x"]}, "junk"])
      end)

      assert {:ok, report} = Maintenance.purge_old(ctx.manifest)

      assert report.deleted == 0
      assert length(report.errors) == 2
      assert Enum.all?(ctx.old_keys, &stored?/1)
    end

    test "a manifest of another library is refused", ctx do
      manifest = read_manifest(ctx.manifest)
      File.write!(ctx.manifest, Jason.encode!(%{manifest | "library_uuid" => UUIDv7.generate()}))

      assert {:error, :manifest_other_library} = Maintenance.purge_old(ctx.manifest)
      assert Enum.all?(ctx.old_keys, &stored?/1)
    end

    test "a dry run deletes nothing", ctx do
      assert {:ok, report} = Maintenance.purge_old(ctx.manifest, apply: false)

      assert report.deleted == length(ctx.old_keys)
      assert Enum.all?(ctx.old_keys, &stored?/1)
    end

    test "a manifest that is not one is refused", ctx do
      File.write!(ctx.manifest, ~s({"entries": "no"}))
      assert {:error, {:manifest_unreadable, _}} = Maintenance.purge_old(ctx.manifest)
    end
  end
end
