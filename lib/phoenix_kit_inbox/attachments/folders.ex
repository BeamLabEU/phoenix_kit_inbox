defmodule PhoenixKitInbox.Attachments.Folders do
  @moduledoc """
  Where the snapshots of a message are filed in the Inbox library, which Media
  shows (`PhoenixKitInbox.Attachments.ensure_library/0`).

  A sent message's files go to

      <mailbox "name (slug)"> / <YYYY-MM> / <YYYY-MM-DD HH:MM — subject>

  in the site's time zone (the core's `time_zone` setting). The subject is cut
  to 80 characters, `/` and control characters are left out, and a blank one is
  "(no subject)". A draft's new snapshots go to `<mailbox> / Drafts`. Both
  words are in the site's default language, whoever sends.

  A host that files mail its own way sets

      config :phoenix_kit_inbox, attachment_folder: {MyApp.Inbox, :attachment_folder}

  The function gets the `%Message{}` and the sending `%Mailbox{}` in the
  process that sends, after the commit, and returns a list of folder names
  (`["Orders", "order-123"]`) that replaces `<mailbox>/<YYYY-MM>`, or `nil`
  for the default. A name must be a string, not blank after trimming, at most
  255 characters, without `/` or control characters; an answer that is not a
  non-empty list of such names, and a function that raises, exits or throws,
  keep the default path (and log a warning).

  ## What is done, and when

  After the send's commit (and after a draft save's), in **one** transaction of
  its own: the folders, the message's `"attachments_folder_uuid"`, the moves
  and the links. Any error rolls all of it back, is logged, and leaves the
  files where they were and the send untouched; nothing retries it by itself.
  A core without managed libraries files nothing.

    * The levels of the path are found or made — an insert that loses a race
      to another message's is looked up again. The message's own folder is
      always new: when its name is taken it becomes `" (2)"`, `" (3)"` … and,
      after 20 tries, ends in the last 12 characters of the message's uuid.
    * The folder's uuid is written to the message's metadata
      (`"attachments_folder_uuid"`, server-written: the caller's copy of the
      key is dropped) with `jsonb_set`, so a second filing of the message uses
      the same folder. A draft has no such key.
    * A snapshot is filed with the **first sent message that names it**
      (by `sent_at`, then by message uuid; drafts do not count), wherever it
      lies now — the root, a `Drafts` folder of any name or language, another
      message's folder. That message moves it into its folder. Every later
      message that attaches it (a forward, a sent message's file attached
      again, a draft's file also in a second draft) leaves it where it is and
      gets a `FolderLink` in its folder, unless it has one. When a file is
      moved out of another message's folder, a link stays there.
    * Inside a caller's transaction nothing is filed (a failure there would
      abort theirs): the files stay in the root or in `Drafts` until a later
      filing.
    * Folders are made without an owner; a viewer who sees only their own files
      sees the folders that lead to them.

  A mailbox renamed since its folder was made gets a new folder for new mail;
  the old stays.
  """

  use Gettext, backend: PhoenixKitInbox.Gettext

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.TimeZone
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Schemas.Attachment
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Schemas.Message

  @folder_key "attachments_folder_uuid"
  @owner [managed: :owner]
  @subject_length 80
  @name_length 255
  @suffix_limit 20

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # Test seam, unset in production: stands in for `Storage` for the folder
  # and file calls made here.
  defp storage, do: Application.get_env(:phoenix_kit_inbox, :folder_storage, Storage)

  @doc "The metadata key of a sent message's folder."
  @spec folder_key() :: String.t()
  def folder_key, do: @folder_key

  # ── a sent message ──────────────────────────────────────────────────────────

  @doc false
  # Internal, after a commit (and for maintenance): it trusts the structs it
  # is handed. Files the snapshots of a sent `message` in its folder (see the
  # moduledoc). Best effort: always `:ok`; a failure is logged and nothing is
  # changed. Inside a caller's transaction it does nothing (see `guarded/2`).
  @spec lay_out_sent(Message.t(), Mailbox.t()) :: :ok
  def lay_out_sent(%Message{} = message, %Mailbox{} = mailbox) do
    guarded("message #{message.uuid}", fn ->
      case Attachments.list_for_message(message.uuid) do
        [] -> :ok
        rows -> file_message(message, mailbox, rows)
      end
    end)
  end

  defp file_message(message, mailbox, rows) do
    with {:ok, library} <- Attachments.ensure_library() do
      library_uuid = to_string(library.uuid)

      # Nothing in the library to file: no folder either.
      case library_files(rows, library_uuid) do
        [] -> :ok
        files -> file_rows(message, mailbox, files, library_uuid)
      end
    end
  end

  @doc false
  # Whether the snapshots of a sent `message` are filed: it has a live folder
  # and each file of the library lies in it, or is linked there when another
  # message is the first to send it. What `lay_out_sent/2` would have nothing
  # left to do for; read-only. For the maintenance task.
  @spec laid_out?(Message.t()) :: boolean()
  def laid_out?(%Message{} = message) do
    with true <- Attachments.managed_libraries?(),
         %{uuid: uuid} <- Attachments.existing_library() do
      library_uuid = to_string(uuid)

      case message.uuid |> Attachments.list_for_message() |> library_files(library_uuid) do
        [] -> true
        files -> filed?(message, files, library_uuid)
      end
    else
      # Nothing can be filed without a managed library, or without a library.
      _ -> true
    end
  end

  defp filed?(message, files, library_uuid) do
    case live_recorded_folder(message.uuid, library_uuid) do
      nil -> false
      folder -> Enum.all?(files, &in_place?(&1, folder, message))
    end
  end

  defp in_place?(file, folder, message) do
    to_string(file.folder_uuid) == folder.uuid or
      (not first_to_send?(file.uuid, message.uuid) and
         storage().folder_link(folder.uuid, file.uuid) != nil)
  end

  defp library_files(rows, library_uuid) do
    for row <- rows,
        %Storage.File{library_uuid: ^library_uuid} = file <- [library_file(row.file_uuid)],
        do: file
  end

  defp file_rows(message, mailbox, files, library_uuid) do
    # The host is asked here, outside the transaction, unless the message
    # has a live folder already.
    path =
      if live_recorded_folder(message.uuid, library_uuid),
        do: nil,
        else: folder_path(message, mailbox)

    transaction(fn ->
      folder = message_folder(message, mailbox, library_uuid, path)
      # One order of the file rows' locks for every filing: two messages
      # naming the same files in different orders cannot wait for each other.
      files |> Enum.sort_by(& &1.uuid) |> Enum.each(&place(&1, folder, message))
    end)
  end

  defp library_file(file_uuid) do
    case storage().get_file(file_uuid) do
      %Storage.File{library_uuid: library} = file -> %{file | library_uuid: to_string(library)}
      _ -> nil
    end
  end

  defp live_recorded_folder(message_uuid, library_uuid) do
    repo().one(from(m in Message, where: m.uuid == ^message_uuid, select: m.metadata))
    |> case do
      %{@folder_key => uuid} when is_binary(uuid) -> live_folder(uuid, library_uuid)
      _ -> nil
    end
  end

  # The folder the message already has, else a new one under `path`.
  defp message_folder(message, mailbox, library_uuid, path) do
    # Two fillings of one message run one after the other.
    metadata =
      repo().one(
        from(m in Message, where: m.uuid == ^message.uuid, select: m.metadata, lock: "FOR UPDATE")
      )

    with uuid when is_binary(uuid) <- metadata && metadata[@folder_key],
         %Folder{} = folder <- live_folder(uuid, library_uuid) do
      folder
    else
      _ -> new_message_folder(message, mailbox, library_uuid, path)
    end
  end

  # `path` is nil only when the folder died since it was looked at, a moment
  # ago: the default path then, without asking the host inside the transaction.
  defp new_message_folder(message, mailbox, library_uuid, path) do
    names = path || default_path(message, mailbox)

    parent =
      Enum.reduce(names, nil, fn name, parent ->
        find_or_create(name, parent && parent.uuid, library_uuid)
      end)

    folder =
      create_unique(
        message_folder_name(message),
        parent && parent.uuid,
        library_uuid,
        message.uuid
      )

    record_folder(message.uuid, folder.uuid)
    folder
  end

  defp live_folder(uuid, library_uuid) do
    repo().one(
      from(f in Folder,
        where: f.uuid == ^uuid and f.library_uuid == ^library_uuid and is_nil(f.trashed_at)
      )
    )
  end

  # Atomic: other keys of the metadata are not read, so none is lost.
  defp record_folder(message_uuid, folder_uuid) do
    {1, _} =
      from(m in Message, where: m.uuid == ^message_uuid)
      |> repo().update_all(
        set: [
          metadata:
            dynamic(
              [m],
              fragment(
                "jsonb_set(coalesce(?, '{}'::jsonb), ?, to_jsonb(?::text), true)",
                m.metadata,
                ^[@folder_key],
                ^folder_uuid
              )
            )
        ]
      )

    :ok
  end

  # One file of the message: into its folder, or linked there. The file's
  # row is locked, so two filings of one file run one after the other.
  defp place(file, folder, message) do
    case lock_home(file.uuid) do
      %{home: home} when home != folder.uuid ->
        if first_to_send?(file.uuid, message.uuid),
          do: move_keeping_link(file, home, folder),
          else: link(file, folder)

      _ ->
        :ok
    end
  end

  defp lock_home(file_uuid) do
    repo().one(
      from(f in Storage.File,
        where: f.uuid == ^file_uuid,
        lock: "FOR UPDATE",
        select: %{home: f.folder_uuid}
      )
    )
  end

  # Moved out of another message's folder (that message was filed before it
  # was known to be second), the file stays reachable there by a link.
  defp move_keeping_link(file, home, folder) do
    move(file, folder)
    if home && message_folder?(home, file.uuid), do: link(file, %{uuid: home})
    :ok
  end

  # A file lies in a message's folder only as that message's attachment, so
  # only the messages naming the file (indexed by `file_uuid`) are looked at.
  defp message_folder?(folder_uuid, file_uuid) do
    repo().exists?(
      from(a in Attachment,
        join: m in Message,
        on: m.uuid == a.message_uuid,
        where:
          a.file_uuid == ^file_uuid and
            fragment("?->>? = ?", m.metadata, ^@folder_key, ^folder_uuid)
      )
    )
  end

  # A snapshot is filed with the first sent message that names it, wherever
  # it lies now (the root, any Drafts folder); a later message that attaches
  # it again only links it. Drafts do not count. The rule relies on a message
  # staying "sent": nothing writes the status "deleted" (a purge marks the
  # delivery); if a delete-for-everyone ever does, this must skip it.
  defp first_to_send?(file_uuid, message_uuid) do
    first_sent_message(file_uuid) in [nil, message_uuid]
  end

  defp first_sent_message(file_uuid) do
    repo().one(
      from(a in Attachment,
        join: m in Message,
        on: m.uuid == a.message_uuid,
        where: a.file_uuid == ^file_uuid and m.status == "sent",
        order_by: [asc: m.sent_at, asc: m.uuid],
        limit: 1,
        select: m.uuid
      )
    )
  end

  defp move(file, folder) do
    case storage().move_file_to_folder(file.uuid, folder.uuid, nil, @owner) do
      {:ok, _} -> :ok
      other -> rollback({:move_failed, file.uuid, other})
    end
  end

  defp link(file, folder) do
    if storage().folder_link(folder.uuid, file.uuid) do
      :ok
    else
      case storage().create_folder_link(folder.uuid, file.uuid, nil, @owner) do
        {:ok, _} -> :ok
        # Made by someone else meanwhile.
        {:error, %Ecto.Changeset{}} = error -> linked_or_rollback(folder, file, error)
        other -> rollback({:link_failed, file.uuid, other})
      end
    end
  end

  defp linked_or_rollback(folder, file, error) do
    if storage().folder_link(folder.uuid, file.uuid),
      do: :ok,
      else: rollback({:link_failed, file.uuid, error})
  end

  # ── a draft ─────────────────────────────────────────────────────────────────

  @doc false
  # Internal, like `lay_out_sent/2`. Files the snapshots a draft save made
  # (`file_uuids`) in `<mailbox> / Drafts`. Best effort: always `:ok`.
  @spec lay_out_draft(Mailbox.t(), [binary()]) :: :ok
  def lay_out_draft(_mailbox, []), do: :ok

  def lay_out_draft(%Mailbox{} = mailbox, file_uuids) do
    guarded("the draft of mailbox #{mailbox.uuid}", fn ->
      with {:ok, library} <- Attachments.ensure_library() do
        file_drafts(mailbox, file_uuids, to_string(library.uuid))
      end
    end)
  end

  defp file_drafts(mailbox, file_uuids, library_uuid) do
    transaction(fn ->
      drafts = drafts_folder(mailbox, library_uuid)
      file_uuids |> Enum.sort() |> Enum.each(&file_draft(&1, drafts, library_uuid))
    end)
  end

  # Serialize with sent filings, then re-read: another page may have sent
  # the snapshot since this draft save committed.
  defp file_draft(file_uuid, drafts, library_uuid) do
    with %{home: nil} <- lock_home(file_uuid),
         nil <- first_sent_message(file_uuid),
         %Storage.File{library_uuid: ^library_uuid} = file <- library_file(file_uuid) do
      move(file, drafts)
    else
      _ -> :ok
    end
  end

  defp drafts_folder(mailbox, library_uuid) do
    parent = find_or_create(mailbox_folder_name(mailbox), nil, library_uuid)
    find_or_create(text(:drafts), parent.uuid, library_uuid)
  end

  # ── the transaction ─────────────────────────────────────────────────────────

  # Not inside a caller's transaction: a failure here would abort theirs (a
  # nested transaction is no savepoint), and its locks would wait for their
  # commit. The files stay in the root or in Drafts for a later filing.
  defp guarded(what, fun) do
    cond do
      not Attachments.managed_libraries?() ->
        :ok

      repo().in_transaction?() ->
        Logger.debug("[Inbox] not filing the attachments of #{what}: inside a transaction")
        :ok

      true ->
        run(what, fun)
    end
  end

  defp run(what, fun) do
    case fun.() do
      :ok -> :ok
      {:ok, _} -> :ok
      nil -> :ok
      {:error, reason} -> failed(what, reason)
      other -> failed(what, other)
    end
  rescue
    e -> failed(what, Exception.format(:error, e, __STACKTRACE__))
  catch
    kind, reason -> failed(what, {kind, reason})
  end

  defp failed(what, reason) do
    Logger.warning(
      "[Inbox] could not file the attachments of #{what}, they stay where they are: " <>
        inspect(reason, limit: 20, printable_limit: 500)
    )

    :ok
  end

  defp transaction(fun), do: repo().transaction(fun)

  defp rollback(reason), do: repo().rollback(reason)

  # ── folders ─────────────────────────────────────────────────────────────────

  defp find_folder(name, parent_uuid, library_uuid) do
    query =
      from(f in Folder,
        where: f.library_uuid == ^library_uuid and f.name == ^name and is_nil(f.trashed_at)
      )

    query =
      if parent_uuid,
        do: where(query, [f], f.parent_uuid == ^parent_uuid),
        else: where(query, [f], is_nil(f.parent_uuid))

    repo().one(query)
  end

  # A level of the path shared by many messages: found, else made; an insert
  # that lost to another message's is found again.
  defp find_or_create(name, parent_uuid, library_uuid) do
    case find_folder(name, parent_uuid, library_uuid) do
      %Folder{} = folder ->
        folder

      nil ->
        case create_folder(name, parent_uuid, library_uuid) do
          {:ok, folder} ->
            folder

          {:error, %Ecto.Changeset{} = changeset} ->
            found_after_conflict(changeset, name, parent_uuid, library_uuid)

          other ->
            rollback({:folder_failed, name, other})
        end
    end
  end

  defp found_after_conflict(changeset, name, parent_uuid, library_uuid) do
    with true <- name_taken?(changeset),
         %Folder{} = folder <- find_folder(name, parent_uuid, library_uuid) do
      folder
    else
      _ -> rollback({:folder_failed, name, changeset})
    end
  end

  # The message's own folder is new: a taken name gets the next suffix, and
  # after @suffix_limit tries a short piece of the message's uuid.
  defp create_unique(base, parent_uuid, library_uuid, message_uuid, n \\ 1) do
    name =
      cond do
        n == 1 -> base
        n <= @suffix_limit -> "#{base} (#{n})"
        true -> "#{base} (#{String.slice(message_uuid, -12, 12)})"
      end

    case create_folder(name, parent_uuid, library_uuid) do
      {:ok, folder} ->
        folder

      {:error, %Ecto.Changeset{} = changeset} ->
        if name_taken?(changeset) and n <= @suffix_limit,
          do: create_unique(base, parent_uuid, library_uuid, message_uuid, n + 1),
          else: rollback({:folder_failed, name, changeset})

      other ->
        rollback({:folder_failed, name, other})
    end
  end

  # Without an owner: the folders belong to the library, not to a sender.
  defp create_folder(name, parent_uuid, library_uuid) do
    attrs = %{name: name, library_uuid: library_uuid}
    attrs = if parent_uuid, do: Map.put(attrs, :parent_uuid, parent_uuid), else: attrs
    storage().create_folder(attrs, nil, @owner)
  end

  defp name_taken?(%Ecto.Changeset{errors: errors}), do: Keyword.has_key?(errors, :name)

  # ── names ───────────────────────────────────────────────────────────────────

  # `<mailbox>/<month>`, or what the host's hook answered.
  defp folder_path(message, mailbox) do
    host_path(message, mailbox) || default_path(message, mailbox)
  end

  defp default_path(message, mailbox), do: [mailbox_folder_name(mailbox), month(message)]

  defp host_path(message, mailbox) do
    case Application.get_env(:phoenix_kit_inbox, :attachment_folder) do
      {mod, fun} when is_atom(mod) and is_atom(fun) -> ask_host(mod, fun, [message, mailbox])
      _ -> nil
    end
  end

  defp ask_host(mod, fun, args) do
    case apply(mod, fun, args) do
      nil ->
        nil

      answer ->
        case valid_names(answer) do
          {:ok, names} ->
            names

          :error ->
            Logger.warning(
              "[Inbox] attachment_folder answered no list of folder names, using the default path: " <>
                inspect(answer, limit: 20, printable_limit: 200)
            )

            nil
        end
    end
  catch
    kind, reason ->
      Logger.warning(
        "[Inbox] attachment_folder failed, using the default path: " <>
          Exception.format_banner(kind, reason)
      )

      nil
  end

  defp valid_names([_ | _] = names) do
    names
    |> Enum.reduce_while([], fn name, acc ->
      case valid_name(name) do
        {:ok, name} -> {:cont, [name | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      acc -> {:ok, Enum.reverse(acc)}
    end
  end

  defp valid_names(_), do: :error

  defp valid_name(name) when is_binary(name) do
    if String.valid?(name), do: checked_name(name), else: :error
  end

  defp valid_name(_), do: :error

  defp checked_name(name) do
    trimmed = name |> String.trim() |> drop_format_characters() |> String.trim()

    if trimmed != "" and String.length(trimmed) <= @name_length and
         not String.contains?(trimmed, "/") and not String.match?(trimmed, ~r/[[:cntrl:]]/u),
       do: {:ok, trimmed},
       else: :error
  end

  defp mailbox_folder_name(%Mailbox{name: name, slug: slug}) do
    suffix = " (#{slug})"
    room = max(@name_length - String.length(suffix), 1)
    clean = name |> clean_text() |> String.slice(0, room) |> String.trim()
    if(clean == "", do: "?", else: clean) <> suffix
  end

  defp month(message), do: message |> local_time() |> Calendar.strftime("%Y-%m")

  defp message_folder_name(message) do
    stamp = message |> local_time() |> Calendar.strftime("%Y-%m-%d %H:%M")

    subject =
      (message.subject || "")
      |> clean_text()
      |> String.slice(0, @subject_length)
      |> String.trim()

    "#{stamp} — #{if subject == "", do: text(:no_subject), else: subject}"
  end

  # `/` and control characters are left out (a control character between words
  # is a space); runs of white space are one.
  defp clean_text(text) do
    text
    |> to_string()
    |> String.replace(~r/[[:cntrl:]]/u, " ")
    |> String.replace("/", "")
    |> drop_format_characters()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # Bidi overrides and zero-width characters (Unicode Cf) make a name read
  # as another one.
  defp drop_format_characters(text), do: String.replace(text, ~r/\p{Cf}/u, "")

  # The moment in the site's time zone.
  defp local_time(%Message{sent_at: sent_at}) do
    utc = sent_at || DateTime.utc_now()

    try do
      TimeZone.shift(utc, Settings.get_setting("time_zone", "0"))
    rescue
      _ -> utc
    end
  end

  # The words of the folders are in the site's default language, not in the
  # language of whoever is sending (or of this process).
  defp text(which) do
    Gettext.with_locale(PhoenixKitInbox.Gettext, site_language(), fn ->
      case which do
        :drafts -> gettext("Drafts")
        :no_subject -> gettext("(no subject)")
      end
    end)
  end

  defp site_language do
    case Settings.get_content_language() do
      code when is_binary(code) and code != "" -> code |> String.split(["-", "_"]) |> hd()
      _ -> "en"
    end
  rescue
    _ -> "en"
  catch
    :exit, _ -> "en"
  end
end
