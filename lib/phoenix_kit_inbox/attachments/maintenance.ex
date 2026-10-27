defmodule PhoenixKitInbox.Attachments.Maintenance do
  @moduledoc """
  Moves the snapshots that were stored as full copies onto the stored objects
  of a Storage file that holds the same bytes, and files every sent message's
  snapshots in folders. The functions behind
  `mix phoenix_kit_inbox.relink_attachments`; it is the way to run them. In a
  release without Mix, call them from `bin/<app> eval`.

  Two phases, so nothing is deleted before it has been checked:

    1. `relink/1` — for each snapshot (active, not system-managed, not being
       edited) whose keys lie under the library's own `key_prefix` and whose
       bytes (same `file_checksum` and `size`) another active file outside
       that prefix holds — a Media file, or a snapshot already on Media's
       keys — the snapshot's record is moved onto the donor's objects with
       `Storage.relink_file/3` (`delete_old: false`: the old objects stay
       where they are, named by nothing). The snapshots of a checksum are
       moved as a group, including those that name another full snapshot's
       keys. Then every sent message whose snapshots are not yet filed in its
       folder is filed (`PhoenixKitInbox.Attachments.Folders`; the host's
       `attachment_folder` hook is asked outside the sending process, and may
       answer `nil`, which is the default path). A snapshot that does not
       qualify, and a message whose sending mailbox is gone, are reported as
       skipped, not as errors.

       The manifest (JSON) is checked for being writable **before** anything
       is moved, and each record is put on it (a temporary file, then a
       rename) both **before** its `relink_file`, as an unverified entry with
       the keys it names, and right after, with its `uuid`, `file_checksum`
       and the old keys **under the library's prefix** only. A `.lock` file
       beside the manifest keeps two `--apply` runs from sharing it (delete
       it if a run was killed). An entry whose record has been deleted since
       is marked `"gone"`; its keys go in phase 2 like a verified one's, if
       nothing names them.
       Each moved attachment is then read back and its sha256 compared with
       the manifest's `file_checksum`; `"verified": true` is written only on
       a match. A run that is cut short can be run again: it re-checks every
       manifest entry that is not verified.
    2. `purge_old/2` — reads the manifest, drops every key that is not a
       canonical key under the library's prefix (no `.`, `..` or empty
       segment, no backslash, no control character: a forged manifest cannot
       name another module's objects), keeps every key an unverified entry
       names, and has Storage delete the keys nothing names
       (`Storage.delete_unreferenced_keys/1`, which checks again under its
       lock).

  A record whose bytes did not check stays relinked to the donor's objects;
  its old objects stay where they are and phase 2 never deletes them. The
  tool cannot move it back: restore the database dump, or look at the donor.
  Fix the cause and run `--apply` again to re-check it.

  Before phase 2 copy the library's directory in the bucket (`<bucket>/<key
  prefix>/` for a local bucket) and keep the database dump from before phase
  1: until then the old objects are all still there.

  A run changes nothing it has already changed: a second run finds no
  candidates and nothing to file. A failure on one record is reported and the
  others go on. A dry run only reads — it does not even make the library.
  Needs a core with `Storage.relink_file/3` and
  `Storage.delete_unreferenced_keys/1`; without them `{:error,
  :core_unsupported}` and nothing is done.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.Manager
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Attachments.Folders
  alias PhoenixKitInbox.Schemas.Attachment
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Schemas.Message

  @donor_limit 5
  @manifest_version 1

  @type report :: %{
          apply?: boolean(),
          records: non_neg_integer(),
          relinked: non_neg_integer(),
          without_donor: non_neg_integer(),
          skipped: [String.t()],
          laid_out: non_neg_integer(),
          verified: non_neg_integer(),
          bytes: non_neg_integer(),
          manifest: Path.t() | nil,
          errors: [String.t()]
        }

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Whether the core has what the maintenance needs."
  @spec supported?() :: boolean()
  def supported? do
    Code.ensure_loaded?(Storage) and function_exported?(Storage, :relink_file, 3) and
      function_exported?(Storage, :delete_unreferenced_keys, 1)
  end

  # ── phase 1 ─────────────────────────────────────────────────────────────────

  @doc """
  Phase 1. Options: `apply: true` to write (default: plan only), `manifest:`
  the manifest's path (needed to apply; an existing manifest is added to, not
  replaced). Returns the report. Applying inside a caller's transaction is
  refused with `{:error, :in_transaction}`: its rollback cannot undo the manifest.
  """
  @spec relink(keyword()) :: {:ok, report()} | {:error, term()}
  def relink(opts \\ []) do
    apply? = Keyword.get(opts, :apply, false)
    manifest = Keyword.get(opts, :manifest)

    with :ok <- check_supported(),
         :ok <- check_manifest_given(apply?, manifest),
         :ok <- check_transaction(apply?) do
      relink_library(Attachments.existing_library(), apply?, manifest)
    end
  end

  defp relink_library(nil, apply?, _manifest), do: {:ok, empty_report(apply?)}

  defp relink_library(library, apply?, manifest),
    do: locked(apply?, manifest, fn -> relink_in(library, apply?, manifest) end)

  # Two `--apply` runs on one manifest would write over each other's records.
  defp locked(false, _manifest, fun), do: fun.()

  defp locked(true, manifest, fun) do
    lock = manifest <> ".lock"

    case File.open(lock, [:write, :exclusive]) do
      {:ok, io} ->
        File.close(io)

        try do
          fun.()
        after
          File.rm(lock)
        end

      {:error, :eexist} ->
        {:error, {:manifest_locked, lock}}

      {:error, reason} ->
        {:error, {:manifest_unwritable, reason}}
    end
  end

  defp relink_in(library, apply?, manifest) do
    library_uuid = to_string(library.uuid)

    with {:ok, prefix} <- library_prefix(library),
         {:ok, previous} <- load_for_apply(apply?, manifest, library_uuid),
         :ok <- preflight(apply?, manifest, previous.entries, library_uuid, prefix) do
      {:ok, run_relink(apply?, manifest, previous, library_uuid, prefix)}
    end
  end

  defp empty_report(apply?) do
    %{
      apply?: apply?,
      records: 0,
      relinked: 0,
      without_donor: 0,
      skipped: [],
      laid_out: 0,
      verified: 0,
      bytes: 0,
      manifest: nil,
      errors: []
    }
  end

  defp check_supported, do: if(supported?(), do: :ok, else: {:error, :core_unsupported})

  defp check_transaction(true) do
    if repo().in_transaction?(), do: {:error, :in_transaction}, else: :ok
  end

  defp check_transaction(false), do: :ok

  defp check_manifest_given(true, nil), do: {:error, :manifest_required}
  defp check_manifest_given(_, _), do: :ok

  defp library_prefix(library) do
    case Attachments.key_prefix(library) do
      nil -> {:error, :no_key_prefix}
      prefix -> {:ok, prefix}
    end
  end

  defp load_for_apply(true, manifest, library_uuid),
    do: read_manifest(manifest, library_uuid, :absent_ok)

  defp load_for_apply(false, _, _), do: {:ok, %{entries: %{}, errors: []}}

  # Nothing is moved if the manifest cannot be written.
  defp preflight(true, manifest, entries, library_uuid, prefix) do
    case write_manifest(manifest, entries, library_uuid, prefix) do
      :ok -> :ok
      {:error, reason} -> {:error, {:manifest_unwritable, reason}}
    end
  end

  defp preflight(false, _, _, _, _), do: :ok

  defp run_relink(apply?, manifest, previous, library_uuid, prefix) do
    {groups, skipped} = candidate_groups(library_uuid, prefix)
    {with_donor, without} = Enum.split_with(groups, &(&1.donors != []))
    records = with_donor |> Enum.flat_map(& &1.files) |> length()
    sizes = key_sizes(with_donor, prefix)

    base = %{
      empty_report(apply?)
      | records: records,
        without_donor: without |> Enum.flat_map(& &1.files) |> length(),
        skipped: skipped,
        errors: previous.errors
    }

    if apply? do
      apply_relink(base, with_donor, sizes, manifest, previous.entries, library_uuid, prefix)
    else
      uuids = with_donor |> Enum.flat_map(& &1.files) |> MapSet.new(& &1.uuid)
      {fileable, no_mailbox} = unlaid_messages(library_uuid)

      %{
        base
        | relinked: records,
          laid_out: length(fileable),
          skipped: base.skipped ++ no_mailbox,
          bytes: freed_bytes(sizes, uuids)
      }
    end
  end

  defp apply_relink(base, groups, sizes, manifest, previous, library_uuid, prefix) do
    {new, entries, errors} = relink_groups(groups, manifest, previous, library_uuid, prefix)

    {entries, check_errors, verified} = verify(new, entries, previous)
    final = write_manifest(manifest, entries, library_uuid, prefix)
    {laid_out, layout_skipped, layout_errors} = lay_out_all(library_uuid)

    %{
      base
      | manifest: manifest,
        relinked: length(new),
        laid_out: laid_out,
        verified: verified,
        skipped: base.skipped ++ layout_skipped,
        bytes: freed_bytes(sizes, MapSet.new(new, & &1.uuid)),
        errors: base.errors ++ errors ++ check_errors ++ write_errors(final) ++ layout_errors
    }
  end

  defp write_errors(:ok), do: []

  defp write_errors({:error, reason}),
    do: ["the manifest could not be written: #{inspect(reason)}"]

  # ── candidates ──────────────────────────────────────────────────────────────

  # Snapshots under the library's prefix that qualify, by the bytes they hold,
  # each group with the files outside the prefix that hold the same bytes; and
  # the snapshots that do not qualify, as text.
  defp candidate_groups(library_uuid, prefix) do
    length = String.length(prefix)

    {eligible, others} =
      from(f in Storage.File,
        where:
          f.library_uuid == ^library_uuid and not is_nil(f.file_checksum) and
            not is_nil(f.file_path) and fragment("left(?, ?)", f.file_path, ^length) == ^prefix,
        order_by: [asc: f.inserted_at, asc: f.uuid]
      )
      |> repo().all()
      |> Enum.split_with(&relinkable?/1)

    groups =
      eligible
      |> Enum.group_by(&{&1.file_checksum, &1.size})
      |> Enum.map(fn {{checksum, size}, files} ->
        %{
          checksum: checksum,
          size: size,
          files: files,
          donors: donors(checksum, size, library_uuid, prefix)
        }
      end)
      |> Enum.sort_by(& &1.checksum)

    {groups,
     Enum.map(others, &"snapshot #{&1.uuid}: not active, or system-managed, or being edited")}
  end

  defp relinkable?(file),
    do: file.status == "active" and not file.system_managed and is_nil(file.edit_state)

  # Media's files first (oldest first), then snapshots that already name
  # keys outside the prefix.
  defp donors(checksum, size, library_uuid, prefix) do
    media = Libraries.media_uuid()
    length = String.length(prefix)

    base =
      from(f in Storage.File,
        where:
          f.file_checksum == ^checksum and f.size == ^size and f.status == "active" and
            f.system_managed == false and is_nil(f.edit_state) and is_nil(f.trashed_at) and
            not is_nil(f.file_path),
        order_by: [asc: f.inserted_at, asc: f.uuid],
        limit: @donor_limit
      )

    in_media = repo().all(where(base, [f], f.library_uuid == ^media))

    foreign =
      repo().all(
        where(
          base,
          [f],
          f.library_uuid == ^library_uuid and
            fragment("left(?, ?)", f.file_path, ^length) != ^prefix
        )
      )

    in_media ++ foreign
  end

  # ── relinking ───────────────────────────────────────────────────────────────

  # One record at a time, each put on the manifest right after it moved. A
  # manifest that cannot be written stops the run: the old keys of what moved
  # next would be on no record.
  defp relink_groups(groups, manifest, previous, library_uuid, prefix) do
    files = for group <- groups, file <- group.files, do: {file, group.donors}
    target = {manifest, library_uuid, prefix}

    %{new: new, entries: entries, errors: errors} =
      Enum.reduce_while(files, %{new: [], entries: previous, errors: []}, &step(&1, &2, target))

    {Enum.reverse(new), entries, errors}
  end

  # The record goes on the manifest before it is moved, with the keys it
  # names now, and again after: a run cut short never leaves old keys that
  # no manifest names. If the move does not happen, the entry stays
  # unverified and the next run checks the full copy.
  defp step({file, donors}, state, {_, _, prefix} = target) do
    intent = %{
      uuid: to_string(file.uuid),
      file_checksum: file.file_checksum,
      old_keys: current_keys(file, prefix),
      gone: false,
      verified: false
    }

    case put_entry(intent, state, target, "before moving") do
      {:cont, state} -> file |> relink_one(donors, prefix) |> record(state, target)
      halt -> halt
    end
  end

  defp current_keys(file, prefix) do
    from(i in FileInstance, where: i.file_uuid == ^file.uuid, select: i.file_name)
    |> repo().all()
    |> Enum.filter(&canonical_key?(&1, prefix))
    |> Enum.uniq()
  end

  defp record(%{error: error}, state, _target),
    do: {:cont, %{state | errors: state.errors ++ [error]}}

  defp record(%{uuid: _} = entry, state, target) do
    state = %{state | new: [entry | state.new]}
    put_entry(entry, state, target, "after moving")
  end

  defp put_entry(entry, state, {manifest, library_uuid, prefix}, when_) do
    entries = merge_entry(state.entries, entry)
    state = %{state | entries: entries}

    case write_manifest(manifest, entries, library_uuid, prefix) do
      :ok ->
        {:cont, state}

      {:error, reason} ->
        message =
          "the manifest could not be written #{when_} #{entry.uuid} (#{inspect(reason)}); " <>
            "stopped. Its old keys: #{inspect(entry.old_keys)}"

        {:halt, %{state | errors: state.errors ++ [message]}}
    end
  end

  defp relink_one(file, donors, prefix) do
    case try_donors(file, donors) do
      {:ok, _relinked, old_keys} ->
        %{
          uuid: to_string(file.uuid),
          file_checksum: file.file_checksum,
          old_keys: Enum.filter(old_keys, &canonical_key?(&1, prefix)),
          gone: false,
          verified: false
        }

      {:error, reason} ->
        %{error: "#{file.uuid}: not relinked (#{format_reason(reason)})"}
    end
  rescue
    e -> %{error: "#{file.uuid}: not relinked (#{Exception.message(e)})"}
  catch
    kind, reason -> %{error: "#{file.uuid}: not relinked (#{kind}: #{inspect(reason)})"}
  end

  # The first donor that takes the record. A donor that changed or is
  # unavailable is passed over. `:incompatible` is about the donor's library
  # (its storage profile and variant set), so it rules out the donors of that
  # library, not those of another.
  defp try_donors(file, donors) do
    opts = [delete_old: false] ++ Attachments.owner_opts()

    {result, _} =
      Enum.reduce_while(donors, {{:error, :no_donor_accepted}, []}, fn donor, {last, ruled_out} ->
        library = to_string(donor.library_uuid)

        if library in ruled_out,
          do: {:cont, {last, ruled_out}},
          else: relink_with(file, donor, opts, library, ruled_out)
      end)

    result
  end

  defp relink_with(file, donor, opts, library, ruled_out) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(Storage, :relink_file, [file, donor, opts]) do
      {:ok, _, _} = ok ->
        {:halt, {ok, ruled_out}}

      {:error, :incompatible} ->
        {:cont, {{:error, :incompatible}, [library | ruled_out]}}

      {:error, reason} when reason in [:donor_changed, :donor_unavailable] ->
        {:cont, {{:error, reason}, ruled_out}}

      {:error, reason} ->
        {:halt, {{:error, reason}, ruled_out}}

      other ->
        {:halt, {{:error, {:unexpected_answer, other}}, ruled_out}}
    end
  end

  defp format_reason(%Ecto.Changeset{} = changeset), do: inspect(changeset.errors)
  defp format_reason(reason), do: inspect(reason)

  # Whether `key` is a key of the library's own: under its prefix, and
  # nothing in it that a file system would read as anything but a name.
  defp canonical_key?(key, prefix) when is_binary(key) do
    String.valid?(key) and String.starts_with?(key, prefix) and
      not String.contains?(key, "\\") and not String.match?(key, ~r/[\x00-\x1f\x7f]/) and
      not Enum.any?(String.split(key, "/"), &(&1 in ["", ".", ".."]))
  end

  defp canonical_key?(_, _), do: false

  # ── bytes to free ───────────────────────────────────────────────────────────

  # `%{key => size}` of the instances of the records about to be relinked
  # that lie under the prefix.
  defp key_sizes(groups, prefix) do
    uuids = groups |> Enum.flat_map(& &1.files) |> Enum.map(& &1.uuid)

    from(i in FileInstance,
      where: i.file_uuid in ^uuids and like(i.file_name, ^(escape_like(prefix) <> "%")),
      select: {i.file_name, i.size}
    )
    |> repo().all()
    |> Enum.filter(fn {key, _} -> canonical_key?(key, prefix) end)
    |> Map.new(fn {key, size} -> {key, size || 0} end)
  end

  defp escape_like(text), do: String.replace(text, ["\\", "%", "_"], &"\\#{&1}")

  # The size of the keys no instance of a record outside `moving` names (the
  # records being moved give theirs up).
  defp freed_bytes(sizes, moving) do
    excluded = MapSet.to_list(moving)
    keys = Map.keys(sizes)

    named =
      from(i in FileInstance,
        where: i.file_name in ^keys and i.file_uuid not in ^excluded,
        select: i.file_name,
        distinct: true
      )
      |> repo().all()
      |> MapSet.new()

    sizes
    |> Enum.reject(fn {key, _} -> MapSet.member?(named, key) end)
    |> Enum.sum_by(&elem(&1, 1))
  end

  # ── check ───────────────────────────────────────────────────────────────────

  # Reads each record moved by this run, and each entry of an earlier
  # manifest that never verified, back and compares the bytes with the
  # checksum on the manifest. Returns the entries with the flag set, the
  # errors, and how many entries verified.
  defp verify(new, entries, previous) do
    new_uuids = MapSet.new(new, & &1.uuid)

    pending =
      for {uuid, entry} <- previous,
          not entry.verified,
          not entry.gone,
          not MapSet.member?(new_uuids, uuid),
          do: entry

    Enum.reduce(new ++ pending, {entries, [], 0}, fn entry, {acc, errors, count} ->
      case check_or_gone(entry) do
        :gone ->
          {Map.update!(acc, entry.uuid, &%{&1 | gone: true}), errors, count}

        :ok ->
          {Map.update!(acc, entry.uuid, &%{&1 | verified: true}), errors, count + 1}

        {:error, text} ->
          {acc, errors ++ ["#{entry.uuid}: #{text}"], count}
      end
    end)
  end

  # A record that was deleted since (a discarded draft's snapshot) has
  # nothing left to check; what its old keys still name is for phase 2 to see.
  defp check_or_gone(entry) do
    if Storage.get_file(entry.uuid), do: check(entry), else: :gone
  end

  defp check(%{file_checksum: checksum}) when not is_binary(checksum),
    do: {:error, "the manifest has no checksum for it"}

  defp check(%{uuid: uuid, file_checksum: checksum}) do
    case sha256_of(uuid) do
      {:ok, ^checksum} ->
        :ok

      {:ok, sha} ->
        {:error, "read back as #{sha}, the manifest says #{checksum}; left unverified"}

      {:error, reason} ->
        {:error, "could not be read back (#{inspect(reason)}); left unverified"}
    end
  end

  defp sha256_of(file_uuid) do
    with {:ok, path} <- Attachments.read_file(%Attachment{file_uuid: file_uuid}) do
      try do
        {:ok, hash_file(path)}
      after
        File.rm(path)
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp hash_file(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # ── filing ──────────────────────────────────────────────────────────────────

  # The sent messages with a snapshot that are not filed in their folder yet:
  # `{[{message, mailbox}], [text of those that cannot be filed]}`.
  defp unlaid_messages(library_uuid) do
    uuids =
      from(m in Message,
        join: a in Attachment,
        on: a.message_uuid == m.uuid,
        join: f in Storage.File,
        on: f.uuid == a.file_uuid,
        where: m.status == "sent" and f.library_uuid == ^library_uuid,
        distinct: true,
        select: m.uuid
      )
      |> repo().all()

    from(m in Message, where: m.uuid in ^uuids, order_by: [asc: m.sent_at, asc: m.uuid])
    |> repo().all()
    |> Enum.reject(&Folders.laid_out?/1)
    |> Enum.map(&{&1, mailbox_of(&1)})
    |> Enum.split_with(fn {_, mailbox} -> mailbox end)
    |> then(fn {fileable, orphans} ->
      {fileable,
       Enum.map(orphans, fn {m, _} -> "message #{m.uuid}: its sending mailbox is gone" end)}
    end)
  end

  defp mailbox_of(%Message{sender_mailbox_uuid: nil}), do: nil
  defp mailbox_of(message), do: repo().get(Mailbox, message.sender_mailbox_uuid)

  defp lay_out_all(library_uuid) do
    {fileable, skipped} = unlaid_messages(library_uuid)

    {done, errors} =
      Enum.reduce(fileable, {0, []}, fn {message, mailbox}, {done, errors} ->
        Folders.lay_out_sent(message, mailbox)

        if Folders.laid_out?(message),
          do: {done + 1, errors},
          else: {done, errors ++ ["message #{message.uuid}: not filed (see the log)"]}
      end)

    {done, skipped, errors}
  end

  # ── the manifest ────────────────────────────────────────────────────────────

  defp read_manifest(path, library_uuid, :absent_ok) do
    if File.exists?(path),
      do: read_manifest(path, library_uuid),
      else: {:ok, %{entries: %{}, errors: []}}
  end

  # `{:ok, %{entries: %{uuid => entry}, errors: [text]}}`. An entry without a
  # uuid is skipped and reported; one that is not marked `"verified": true`
  # is unverified.
  defp read_manifest(path, library_uuid) do
    with {:ok, text} <- File.read(path),
         {:ok, doc} <- Jason.decode(text),
         {:ok, entries} <- manifest_entries(doc),
         :ok <- same_library(doc, library_uuid),
         :ok <- same_version(doc) do
      decode_entries(entries)
    else
      {:error, reason} when reason in [:manifest_other_library, :manifest_version] ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:manifest_unreadable, reason}}
    end
  end

  defp manifest_entries(%{"entries" => entries}) when is_list(entries), do: {:ok, entries}
  defp manifest_entries(_), do: {:error, :not_a_manifest}

  defp same_library(%{"library_uuid" => uuid}, uuid), do: :ok
  defp same_library(_, _), do: {:error, :manifest_other_library}

  defp same_version(%{"version" => @manifest_version}), do: :ok
  defp same_version(_), do: {:error, :manifest_version}

  defp decode_entries(entries) do
    entries
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{entries: %{}, errors: []}}, fn
      {%{"uuid" => uuid} = entry, _}, {:ok, acc} when is_binary(uuid) ->
        if Map.has_key?(acc.entries, uuid) do
          {:halt, {:error, {:manifest_unreadable, {:duplicate_uuid, uuid}}}}
        else
          decoded = %{
            uuid: uuid,
            file_checksum: entry["file_checksum"],
            old_keys:
              entry |> Map.get("old_keys", []) |> List.wrap() |> Enum.filter(&is_binary/1),
            gone: entry["gone"] == true,
            verified: entry["verified"] == true
          }

          {:cont, {:ok, put_in(acc.entries[uuid], decoded)}}
        end

      {_, index}, {:ok, acc} ->
        {:cont,
         {:ok, %{acc | errors: acc.errors ++ ["manifest entry #{index} has no uuid: skipped"]}}}
    end)
  end

  defp merge_entry(entries, entry) do
    Map.update(entries, entry.uuid, entry, fn old ->
      %{entry | old_keys: Enum.uniq(old.old_keys ++ entry.old_keys)}
    end)
  end

  # Atomic: the manifest is whole before and after, never half written.
  defp write_manifest(path, entries, library_uuid, prefix) do
    json =
      Jason.encode!(
        %{
          "version" => @manifest_version,
          "library_uuid" => library_uuid,
          "key_prefix" => prefix,
          "entries" =>
            entries
            |> Map.values()
            |> Enum.sort_by(& &1.uuid)
            |> Enum.map(&Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))
        },
        pretty: true
      )

    temporary = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.write(temporary, json),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, _} = error ->
        File.rm(temporary)
        error
    end
  end

  # ── phase 2 ─────────────────────────────────────────────────────────────────

  @doc """
  Phase 2. Reads the manifest at `path` and deletes the old keys nothing names
  any more. Options: `apply: false` reports without deleting (default
  `true`). Returns `{:ok, %{keys: n, outside_prefix: n, unverified: n,
  kept: n, already_gone: n, deleted: n, left: n, errors: [..]}}`: `deleted`
  are the keys that are gone after the call, `left` those Storage kept
  because something named them again meanwhile. Applying inside a caller's
  transaction is refused with `{:error, :in_transaction}`.
  """
  @spec purge_old(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def purge_old(path, opts \\ []) do
    apply? = Keyword.get(opts, :apply, true)

    with :ok <- check_supported(),
         :ok <- check_transaction(apply?),
         {:ok, library} <- existing_library(),
         {:ok, prefix} <- library_prefix(library),
         {:ok, manifest} <- read_manifest(path, to_string(library.uuid)) do
      {:ok, run_purge(manifest, prefix, apply?)}
    end
  end

  defp existing_library do
    case Attachments.existing_library() do
      nil -> {:error, :no_library}
      library -> {:ok, library}
    end
  end

  defp run_purge(%{entries: entries, errors: errors}, prefix, apply?) do
    {verified, unverified} = entries |> Map.values() |> Enum.split_with(&(&1.verified or &1.gone))
    unverified_keys = unverified |> Enum.flat_map(& &1.old_keys) |> MapSet.new()

    # A key an unverified entry names is never deleted, whoever else names it.
    keys =
      verified
      |> Enum.flat_map(& &1.old_keys)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(unverified_keys, &1))

    {inside, outside} = Enum.split_with(keys, &canonical_key?(&1, prefix))
    named = named_keys(inside)
    {kept, unnamed} = Enum.split_with(inside, &(&1 in named))
    {free, gone} = Enum.split_with(unnamed, &Manager.file_exists?/1)

    report = %{
      apply?: apply?,
      keys: length(keys),
      outside_prefix: length(outside),
      unverified: MapSet.size(unverified_keys),
      kept: length(kept),
      already_gone: length(gone),
      deleted: if(apply?, do: 0, else: length(free)),
      left: 0,
      errors: errors
    }

    if apply? and free != [], do: delete(report, free), else: report
  end

  defp delete(report, free) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    answer = apply(Storage, :delete_unreferenced_keys, [free])
    {still, removed} = Enum.split_with(free, &Manager.file_exists?/1)
    report = %{report | deleted: length(removed), left: length(still)}

    case answer do
      :ok ->
        report

      {:error, reason} ->
        %{report | errors: report.errors ++ ["could not delete every key: #{inspect(reason)}"]}
    end
  end

  defp named_keys([]), do: []

  defp named_keys(keys) do
    from(i in FileInstance, where: i.file_name in ^keys, select: i.file_name, distinct: true)
    |> repo().all()
  end
end
