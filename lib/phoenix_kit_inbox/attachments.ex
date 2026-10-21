defmodule PhoenixKitInbox.Attachments do
  @moduledoc """
  Files attached to messages.

  ## Where the files live

  Every attachment is a file in the module's own **hidden system library** in
  Storage (slug `"phoenix-kit-inbox"`, made on first use by
  `ensure_library/0`). A hidden library's files are not listed in Media, have
  no permanent URL, and are read only by their uploader and an Owner/Admin
  (`PhoenixKit.Modules.Storage.Libraries.can?/3`) — the module serves them to
  the people on a message itself, through `PhoenixKitInbox.Web.AttachmentController`.

  A message stores references (`PhoenixKitInbox.Schemas.Attachment` rows), not
  bytes, so an internal message has no size limit beyond the per-file
  `inbox_max_upload_bytes` setting (default 200 MB) and 50 files.

  ## How a file gets into a message

  Everything is a **snapshot** in the Inbox library, so what was sent does not
  change when the file it came from is later edited, replaced or deleted:

    1. an upload in compose (`store_upload/4`) is stored in the Inbox library
       straight away, the uploader being the sender — it is its own snapshot;
    2. an existing Storage file named in the form's `"attachments"` is copied,
       if the sender may read it (`Libraries.can?(scope, file, :read)`);
    3. a file the host checked itself is copied when its uuid comes in the
       server-side `attachments_authorized:` option — never from the form;
    4. bytes the host made (`attachments_data:`) are stored as they are;
    5. a file already attached to a message the sender sent, or still holds
       a copy of (a non-deleted delivery in a mailbox they can read), is
       forwarded as the same snapshot, flags and all.

  A file in the trash or a system-managed one is refused in paths 2 and 3
  (`{:error, {:attachment_unavailable, uuid}}`); anything else that does not
  qualify is `{:error, {:attachment_forbidden, uuid}}`.

  Snapshots are stored *before* the message transaction (Storage takes a
  directory lock for each, which must not be held across the send) and are
  deleted again if the transaction rolls back. Snapshots of a sent message
  are never deleted — sent messages are permanent; a discarded draft takes
  its snapshots with it unless another row still names them.

  ## Flags and the host's policy

  `flags` on a row is a map only server code sets (`attachment_flags:`,
  `attachments_data:`); a forward copies it. A host that must keep some
  files from some recipients sets

      config :phoenix_kit_inbox, attachment_policy: {MyApp.Inbox, :check_attachments}

  The function is called on every send and forward that carries attachments
  with the sender's scope, every user the message reaches (the owners of the
  personal mailboxes addressed in To/Cc/Bcc, and the owner and grantees of
  each shared mailbox addressed) and the attachment rows with their flags.
  It is called before any snapshot is stored, so a row about to be copied
  has no `file_uuid` yet. `:ok` lets the send go ahead; `{:error, reason}`
  refuses it with `{:error, {:attachment_refused, reason}}`; a raise or any
  other answer refuses it too.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.Library
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Schemas.Attachment
  alias PhoenixKitInbox.Schemas.Delivery
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Schemas.MailboxGrant
  alias PhoenixKitInbox.Schemas.Message

  @library_slug "phoenix-kit-inbox"
  # System libraries share one namespace of names; a module prefix keeps a
  # site's own "Inbox" library from blocking this one (and the reverse).
  @library_name "PhoenixKit Inbox"
  @max_files 50
  @max_upload_setting "inbox_max_upload_bytes"
  @default_max_upload_bytes 200_000_000
  @max_filename 255

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── the library ─────────────────────────────────────────────────────────────

  @doc "The slug of the module's hidden Storage library."
  @spec library_slug() :: String.t()
  def library_slug, do: @library_slug

  @doc """
  The module's hidden library, made on first call. Idempotent and safe to
  race: a caller that loses the insert finds the winner's library.
  """
  @spec ensure_library() :: {:ok, Library.t()} | {:error, term()}
  def ensure_library do
    case library() do
      nil -> create_library()
      library -> {:ok, library}
    end
  end

  defp library, do: Libraries.get_hidden_library_by_slug(@library_slug)

  defp create_library do
    case Libraries.create_system_library(
           %{"name" => @library_name, "slug" => @library_slug},
           hidden: true
         ) do
      {:ok, library} ->
        {:ok, library}

      {:error, reason} ->
        case library() do
          nil -> {:error, {:library_unavailable, reason}}
          library -> {:ok, library}
        end
    end
  end

  defp library_uuid do
    case library() do
      nil -> nil
      library -> to_string(library.uuid)
    end
  end

  defp in_library?(%{library_uuid: uuid}, library_uuid) when is_binary(library_uuid),
    do: to_string(uuid) == library_uuid

  defp in_library?(_file, _library_uuid), do: false

  # ── limits ──────────────────────────────────────────────────────────────────

  @doc "Most files one message may carry."
  @spec max_files() :: pos_integer()
  def max_files, do: @max_files

  @doc """
  Largest file accepted, in bytes — the `inbox_max_upload_bytes` setting,
  #{@default_max_upload_bytes} by default.
  """
  @spec max_upload_bytes() :: pos_integer()
  def max_upload_bytes do
    case PhoenixKit.Settings.get_integer_setting(@max_upload_setting, @default_max_upload_bytes) do
      bytes when is_integer(bytes) and bytes > 0 -> bytes
      _ -> @default_max_upload_bytes
    end
  rescue
    _ -> @default_max_upload_bytes
  catch
    :exit, _ -> @default_max_upload_bytes
  end

  # ── reads ───────────────────────────────────────────────────────────────────

  @doc "A message's attachments, in order."
  @spec list_for_message(binary()) :: [Attachment.t()]
  def list_for_message(message_uuid) when is_binary(message_uuid) do
    from(a in Attachment,
      where: a.message_uuid == ^message_uuid,
      order_by: [asc: a.position, asc: a.inserted_at]
    )
    |> repo().all()
  end

  def list_for_message(_), do: []

  @doc """
  The attachment `attachment_uuid` if `scope` may download it, else
  `{:error, :not_found}` — the same answer whether the row is missing or
  someone else's.

  Allowed when the module is on, the scope holds `"inbox"`, and its user
  sent the message or holds a non-deleted copy of it (a delivery) in a
  mailbox they can read.
  """
  @spec fetch_for_download(Scope.t() | nil, term()) ::
          {:ok, Attachment.t()} | {:error, :not_found}
  def fetch_for_download(scope, attachment_uuid) do
    with true <- PhoenixKitInbox.enabled?(),
         true <- Scope.can?(scope, "inbox"),
         {:ok, user_uuid} <- Mailboxes.scope_user_uuid(scope),
         {:ok, uuid} <- Ecto.UUID.cast(attachment_uuid),
         %Attachment{} = attachment <- repo().get(Attachment, uuid),
         true <- participant?(attachment.message_uuid, user_uuid) do
      {:ok, attachment}
    else
      _ -> {:error, :not_found}
    end
  end

  defp participant?(message_uuid, user_uuid) do
    from(m in Message, as: :message, where: m.uuid == ^message_uuid)
    |> where_participant(user_uuid)
    |> repo().exists?()
  end

  # The message (bound as `:message`) was sent by the user, or the user holds
  # an active copy of it in a mailbox they can open.
  defp where_participant(query, user_uuid) do
    readable = user_uuid |> Mailboxes.list_accessible_mailboxes() |> Enum.map(& &1.uuid)

    copies =
      from(d in Delivery,
        where: d.status == "active" and d.mailbox_uuid in ^readable,
        select: d.message_uuid
      )

    where(
      query,
      [message: m],
      m.sender_user_uuid == ^user_uuid or m.uuid in subquery(copies)
    )
  end

  @doc """
  Copies the bytes of `attachment` out of Storage into a temporary file and
  returns its path — the caller deletes it. `{:error, :not_found}` when the
  snapshot is gone or is not a file of the Inbox library.
  """
  @spec read_file(Attachment.t()) :: {:ok, Path.t()} | {:error, :not_found}
  def read_file(%Attachment{file_uuid: file_uuid}) do
    with %Storage.File{system_managed: false} = file <- Storage.get_file(to_string(file_uuid)),
         true <- in_library?(file, library_uuid()),
         {:ok, path, _file} <- Storage.retrieve_file(file.uuid) do
      {:ok, path}
    else
      _ -> {:error, :not_found}
    end
  end

  # ── uploads ─────────────────────────────────────────────────────────────────

  @doc """
  Stores an upload from compose (the temporary file at `path`) in the Inbox
  library as `scope`'s user — the snapshot itself, attached later by its
  uuid. Needs the `"inbox"` permission; refused over `max_upload_bytes/0`.
  The file at `path` is left where it is.
  """
  @spec store_upload(Scope.t(), Path.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Storage.File.t()} | {:error, term()}
  def store_upload(%Scope{} = scope, path, filename, content_type) do
    filename = clean_filename(filename)

    with {:ok, user_uuid} <- Mailboxes.scope_user_uuid(scope),
         :ok <- authorize_inbox(scope),
         {:ok, %{size: size}} <- File.stat(path),
         :ok <- check_size(filename, size),
         {:ok, library} <- ensure_library() do
      store_snapshot(path, filename, content_type, user_uuid, to_string(library.uuid))
    end
  end

  def store_upload(_scope, _path, _filename, _content_type), do: {:error, :forbidden}

  @doc """
  Deletes an upload taken off a message before it was sent or saved: only
  `scope`'s own file in the Inbox library that no attachment row names.
  Anything else is left alone. Always `:ok`.
  """
  @spec discard_upload(Scope.t(), term()) :: :ok
  def discard_upload(scope, file_uuid) do
    with {:ok, user_uuid} <- Mailboxes.scope_user_uuid(scope),
         {:ok, uuid} <- Ecto.UUID.cast(file_uuid),
         %Storage.File{} = file <- Storage.get_file(uuid),
         true <- to_string(file.user_uuid) == user_uuid do
      release([uuid])
    end

    :ok
  end

  @doc """
  Whether `scope` may attach the Storage file `file_uuid`, checked exactly
  as a send would check it, and what a compose chip shows for it:
  `{:ok, %{file_uuid: uuid_to_submit, filename: name, size_bytes: size}}`.
  For the media picker, which lists files without regard to who may read
  them.
  """
  @spec describe(Scope.t(), term()) :: {:ok, map()} | {:error, term()}
  def describe(%Scope{} = scope, file_uuid) do
    with {:ok, user_uuid} <- Mailboxes.scope_user_uuid(scope),
         :ok <- authorize_inbox(scope),
         {:ok, [item]} <-
           plan(scope, user_uuid, nil, %{"attachments" => [%{"file_uuid" => file_uuid}]}, []) do
      {:ok, %{file_uuid: item.key, filename: item.filename, size_bytes: item.size_bytes}}
    end
  end

  def describe(_scope, _file_uuid), do: {:error, :forbidden}

  defp authorize_inbox(scope) do
    if Scope.can?(scope, "inbox"), do: :ok, else: {:error, :forbidden}
  end

  # ── admission (called by Messages) ──────────────────────────────────────────

  @doc false
  # Works out the attachments a send or draft save ends up with, checking
  # every path, without storing anything: a list of planned rows (`plan/5`).
  # `message` is the draft being saved or promoted, or nil.
  @spec plan(Scope.t(), binary(), Message.t() | nil, map(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def plan(scope, user_uuid, message, attrs, opts) do
    existing = if message, do: list_for_message(message.uuid), else: []
    flags = opts |> Keyword.get(:attachment_flags, %{}) |> normalize_flags_map()
    context = %{scope: scope, user_uuid: user_uuid, flags: flags, library: library_uuid()}

    with {:ok, form} <- form_items(attrs, existing, context),
         {:ok, authorized} <-
           authorized_items(Keyword.get(opts, :attachments_authorized, []), context),
         {:ok, data} <- data_items(Keyword.get(opts, :attachments_data, [])) do
      items = dedupe(form ++ authorized) ++ data

      with :ok <- check_count(items),
           :ok <- check_sizes(items) do
        {:ok, items}
      end
    end
  end

  # Without an "attachments" key a draft keeps what it has; with one, the
  # list is the new set.
  defp form_items(attrs, existing, context) do
    case Map.fetch(attrs, "attachments") do
      :error ->
        {:ok, Enum.map(existing, &keep_item/1)}

      {:ok, entries} ->
        with {:ok, uuids} <- form_uuids(entries) do
          collect(uuids, &form_item(&1, existing, context))
        end
    end
  end

  defp form_uuids(nil), do: {:ok, []}

  defp form_uuids(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case entry_uuid(entry) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        :error -> {:halt, {:error, :invalid_attachments}}
      end
    end)
    |> case do
      {:ok, uuids} -> {:ok, Enum.reverse(uuids)}
      error -> error
    end
  end

  defp form_uuids(entries) when is_map(entries), do: entries |> Map.values() |> form_uuids()
  defp form_uuids(_), do: {:error, :invalid_attachments}

  defp entry_uuid(%{"file_uuid" => uuid}) when is_binary(uuid), do: {:ok, uuid}
  defp entry_uuid(%{file_uuid: uuid}) when is_binary(uuid), do: {:ok, uuid}
  defp entry_uuid(_), do: :error

  defp form_item(raw, existing, context) do
    with {:ok, uuid} <- cast_file_uuid(raw) do
      case Enum.find(existing, &(to_string(&1.file_uuid) == uuid)) do
        %Attachment{} = row -> {:ok, keep_item(row)}
        nil -> storage_item(uuid, context)
      end
    end
  end

  defp storage_item(uuid, context) do
    with {:ok, file} <- fetch_file(uuid) do
      if in_library?(file, context.library),
        do: inbox_item(file, context),
        else: readable_item(file, context)
    end
  end

  # A file already in the Inbox library: one the sender may forward (path
  # 5), or their own upload (path 1). Nothing else, whoever's it is.
  defp inbox_item(file, context) do
    uuid = to_string(file.uuid)

    cond do
      row = forwardable_row(uuid, context.user_uuid) ->
        {:ok, reuse_item(row)}

      to_string(file.user_uuid) == context.user_uuid ->
        {:ok, upload_item(file, Map.get(context.flags, uuid, %{}))}

      true ->
        {:error, {:attachment_forbidden, uuid}}
    end
  end

  # Path 2: someone's Storage file, if the sender may read it.
  defp readable_item(file, context) do
    uuid = to_string(file.uuid)

    cond do
      not Libraries.can?(context.scope, file, :read) -> {:error, {:attachment_forbidden, uuid}}
      unavailable?(file) -> {:error, {:attachment_unavailable, uuid}}
      true -> {:ok, file_item(file, Map.get(context.flags, uuid, %{}))}
    end
  end

  # Path 3: the host vouched for these; only the state of the file is checked.
  defp authorized_items(uuids, context) when is_list(uuids),
    do: collect(uuids, &authorized_item(&1, context))

  defp authorized_items(_, _context), do: {:error, :invalid_attachments}

  defp authorized_item(raw, context) do
    with {:ok, uuid} <- cast_file_uuid(raw),
         {:ok, file} <- fetch_file(uuid) do
      if unavailable?(file),
        do: {:error, {:attachment_unavailable, uuid}},
        else: {:ok, file_item(file, Map.get(context.flags, uuid, %{}))}
    end
  end

  defp fetch_file(uuid) do
    case Storage.get_file(uuid) do
      nil -> {:error, {:attachment_forbidden, uuid}}
      file -> {:ok, file}
    end
  end

  # Path 4: bytes from the host.
  defp data_items(entries) when is_list(entries) do
    collect(entries, fn entry ->
      entry = Map.new(entry, fn {k, v} -> {to_string(k), v} end)
      filename = clean_filename(entry["filename"])

      source =
        case entry do
          %{"binary" => binary} when is_binary(binary) -> {:binary, binary}
          %{"path" => path} when is_binary(path) -> {:path, path}
          _ -> nil
        end

      with {:ok, size} <- data_size(source) do
        {:ok,
         %{
           mode: :snapshot,
           source: source,
           file_uuid: nil,
           source_file_uuid: nil,
           filename: filename,
           content_type: entry["content_type"] || MIME.from_path(filename),
           size_bytes: size,
           flags: normalize_flags(entry["flags"]),
           key: nil
         }}
      end
    end)
  end

  defp data_items(_), do: {:error, :invalid_attachments}

  defp data_size({:binary, binary}), do: {:ok, byte_size(binary)}

  defp data_size({:path, path}) do
    case File.stat(path) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, _} -> {:error, :invalid_attachments}
    end
  end

  defp data_size(nil), do: {:error, :invalid_attachments}

  defp keep_item(%Attachment{} = row) do
    %{
      mode: :keep,
      row: row,
      file_uuid: to_string(row.file_uuid),
      source_file_uuid: row.source_file_uuid,
      filename: row.filename,
      content_type: row.content_type,
      size_bytes: row.size_bytes,
      flags: row.flags || %{},
      key: to_string(row.file_uuid)
    }
  end

  defp reuse_item(%Attachment{} = row) do
    %{keep_item(row) | mode: :reuse} |> Map.delete(:row)
  end

  defp upload_item(file, flags) do
    %{
      mode: :reuse,
      file_uuid: to_string(file.uuid),
      source_file_uuid: nil,
      filename: file_filename(file),
      content_type: file.mime_type,
      size_bytes: file.size || 0,
      flags: flags,
      key: to_string(file.uuid)
    }
  end

  defp file_item(file, flags) do
    %{
      mode: :snapshot,
      source: {:file, file},
      file_uuid: nil,
      source_file_uuid: to_string(file.uuid),
      filename: file_filename(file),
      content_type: file.mime_type,
      size_bytes: file.size || 0,
      flags: normalize_flags(flags),
      key: to_string(file.uuid)
    }
  end

  defp file_filename(file),
    do: clean_filename(file.original_file_name || file.file_name)

  # An attachment row the user may forward: on a sent message they sent or
  # still hold a copy of.
  defp forwardable_row(file_uuid, user_uuid) do
    from(a in Attachment,
      join: m in Message,
      as: :message,
      on: m.uuid == a.message_uuid,
      where: a.file_uuid == ^file_uuid and m.status == "sent",
      order_by: [asc: a.inserted_at],
      limit: 1
    )
    |> where_participant(user_uuid)
    |> repo().one()
  end

  defp unavailable?(file),
    do: file.status == "trashed" or not is_nil(file.trashed_at) or file.system_managed == true

  defp cast_file_uuid(raw) do
    case Ecto.UUID.cast(raw) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:attachment_forbidden, raw}}
    end
  end

  # The first entry for a file wins: the same file named twice is one row.
  defp dedupe(items) do
    {kept, _seen} =
      Enum.reduce(items, {[], MapSet.new()}, fn item, {acc, seen} ->
        if MapSet.member?(seen, item.key),
          do: {acc, seen},
          else: {[item | acc], MapSet.put(seen, item.key)}
      end)

    Enum.reverse(kept)
  end

  defp check_count(items) when length(items) > @max_files,
    do: {:error, {:too_many_attachments, @max_files}}

  defp check_count(_items), do: :ok

  # Only what gets stored now is measured: kept and forwarded rows were
  # measured when they were stored.
  defp check_sizes(items) do
    max = max_upload_bytes()

    case Enum.find(items, &(&1.mode == :snapshot and &1.size_bytes > max)) do
      nil -> :ok
      item -> {:error, {:attachment_too_large, item.filename}}
    end
  end

  defp check_size(filename, size) do
    if size > max_upload_bytes(), do: {:error, {:attachment_too_large, filename}}, else: :ok
  end

  defp collect(list, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case fun.(entry) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp normalize_flags_map(flags) when is_map(flags) do
    Map.new(flags, fn {uuid, value} -> {to_string(uuid), value} end)
  end

  defp normalize_flags_map(_), do: %{}

  defp normalize_flags(flags) when is_map(flags),
    do: Map.new(flags, fn {k, v} -> {to_string(k), v} end)

  defp normalize_flags(_), do: %{}

  # ── policy ──────────────────────────────────────────────────────────────────

  @doc false
  # Asks the host's attachment_policy about `items` going to `recipients`
  # (`%{mailbox: Mailbox}` maps, as resolved by Messages). Nothing to ask
  # when there are no attachments or no policy.
  @spec check_policy(Scope.t(), [map()], [map()]) :: :ok | {:error, term()}
  def check_policy(_scope, _recipients, []), do: :ok

  def check_policy(scope, recipients, items) do
    case Application.get_env(:phoenix_kit_inbox, :attachment_policy) do
      nil -> :ok
      {mod, fun} when is_atom(mod) and is_atom(fun) -> ask(mod, fun, scope, recipients, items)
      other -> {:error, {:attachment_refused, {:invalid_policy, other}}}
    end
  end

  defp ask(mod, fun, scope, recipients, items) do
    case apply(mod, fun, [scope, recipient_users(recipients), Enum.map(items, &to_row/1)]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:attachment_refused, reason}}
      other -> {:error, {:attachment_refused, {:unexpected, other}}}
    end
  rescue
    e ->
      Logger.warning("[Inbox] attachment_policy raised, refusing: #{Exception.message(e)}")
      {:error, {:attachment_refused, :policy_failed}}
  catch
    kind, reason ->
      Logger.warning("[Inbox] attachment_policy failed (#{kind}), refusing: #{inspect(reason)}")
      {:error, {:attachment_refused, :policy_failed}}
  end

  # Everyone the message reaches: the owner of each personal mailbox, and
  # the owner and every grantee of each shared one.
  defp recipient_users(recipients) do
    mailboxes = Enum.map(recipients, & &1.mailbox)

    owners =
      mailboxes
      |> Enum.map(& &1.owner_uuid)
      |> Enum.reject(&is_nil/1)

    shared = for %Mailbox{kind: "shared", uuid: uuid} <- mailboxes, do: uuid

    grantees =
      from(g in MailboxGrant, where: g.mailbox_uuid in ^shared, select: g.user_uuid)
      |> repo().all()

    uuids = Enum.uniq(owners ++ grantees)

    from(u in User, where: u.uuid in ^uuids, order_by: u.uuid)
    |> repo().all()
  end

  defp to_row(item) do
    %Attachment{
      file_uuid: item.file_uuid,
      source_file_uuid: item.source_file_uuid,
      filename: item.filename,
      content_type: item.content_type,
      size_bytes: item.size_bytes,
      flags: item.flags
    }
  end

  # ── snapshots ───────────────────────────────────────────────────────────────

  @doc false
  # Stores every planned snapshot in the Inbox library, outside any
  # transaction. Returns the items with their `file_uuid` and the uuids it
  # created (to delete if the send then fails); on failure deletes what it
  # made and returns the error.
  @spec store_snapshots([map()], binary()) :: {:ok, [map()], [binary()]} | {:error, term()}
  def store_snapshots(items, user_uuid) do
    if Enum.any?(items, &(&1.mode == :snapshot)) do
      with {:ok, library} <- ensure_library() do
        do_store_snapshots(items, user_uuid, to_string(library.uuid))
      end
    else
      {:ok, items, []}
    end
  end

  defp do_store_snapshots(items, user_uuid, library_uuid) do
    items
    |> Enum.reduce_while({:ok, [], []}, fn
      %{mode: :snapshot} = item, {:ok, acc, created} ->
        case snapshot(item, user_uuid, library_uuid) do
          {:ok, file} ->
            uuid = to_string(file.uuid)
            {:cont, {:ok, [%{item | file_uuid: uuid} | acc], [uuid | created]}}

          {:error, reason} ->
            {:halt, {:error, reason, created}}
        end

      item, {:ok, acc, created} ->
        {:cont, {:ok, [item | acc], created}}
    end)
    |> case do
      {:ok, items, created} ->
        {:ok, Enum.reverse(items), created}

      {:error, reason, created} ->
        discard_snapshots(created)
        {:error, reason}
    end
  end

  defp snapshot(%{source: {:file, file}} = item, user_uuid, library_uuid) do
    case Storage.retrieve_file(file.uuid) do
      {:ok, temp, _file} ->
        result = store_snapshot(temp, item.filename, item.content_type, user_uuid, library_uuid)
        File.rm(temp)
        result

      {:error, reason} ->
        Logger.warning("[Inbox] could not read #{file.uuid} to attach it: #{inspect(reason)}")
        {:error, {:attachment_unavailable, to_string(file.uuid)}}
    end
  end

  defp snapshot(%{source: {:path, path}} = item, user_uuid, library_uuid),
    do: store_snapshot(path, item.filename, item.content_type, user_uuid, library_uuid)

  defp snapshot(%{source: {:binary, binary}} = item, user_uuid, library_uuid) do
    temp = Path.join(System.tmp_dir!(), "phoenix_kit_inbox_#{UUIDv7.generate()}")

    try do
      File.write!(temp, binary)
      store_snapshot(temp, item.filename, item.content_type, user_uuid, library_uuid)
    after
      File.rm(temp)
    end
  end

  # `dedup: false`: without it Storage hands back the uploader's existing
  # file of the same bytes, in whatever library it is — no snapshot at all.
  defp store_snapshot(path, filename, content_type, user_uuid, library_uuid) do
    ext = filename |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    mime = content_type || MIME.from_path(filename)

    path
    |> Storage.store_file_in_buckets(
      Storage.determine_file_type(mime, filename),
      user_uuid,
      Auth.calculate_file_hash(path),
      ext,
      filename,
      library_uuid: library_uuid,
      dedup: false,
      mime_type: mime
    )
    |> case do
      {:ok, %{library_uuid: stored} = file} ->
        if to_string(stored) == library_uuid,
          do: {:ok, file},
          else: {:error, {:attachment_store_failed, :wrong_library}}

      {:error, reason} ->
        {:error, {:attachment_store_failed, reason}}

      other ->
        {:error, {:attachment_store_failed, other}}
    end
  rescue
    e -> {:error, {:attachment_store_failed, Exception.message(e)}}
  end

  @doc false
  # Deletes snapshots a failed send made. Nothing names them yet.
  @spec discard_snapshots([binary()]) :: :ok
  def discard_snapshots(file_uuids), do: release(file_uuids)

  # ── rows ────────────────────────────────────────────────────────────────────

  @doc false
  # Inside the message transaction: makes the message's rows exactly
  # `items`, in order — kept rows stay (repositioned), dropped ones go, new
  # ones are inserted. Returns the file uuids of the rows dropped.
  @spec write_rows(Ecto.Repo.t(), binary(), [map()]) :: {:ok, [binary()]} | {:error, term()}
  def write_rows(repo, message_uuid, items) do
    kept = for %{mode: :keep, row: row} <- items, do: row.uuid

    dropped =
      from(a in Attachment, where: a.message_uuid == ^message_uuid and a.uuid not in ^kept)
      |> repo.all()

    _ = repo.delete_all(from(a in Attachment, where: a.uuid in ^Enum.map(dropped, & &1.uuid)))

    items
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, position}, :ok ->
      case write_row(repo, message_uuid, item, position) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> {:ok, Enum.map(dropped, &to_string(&1.file_uuid))}
      error -> error
    end
  end

  defp write_row(repo, _message_uuid, %{mode: :keep, row: row}, position) do
    row |> Ecto.Changeset.change(position: position) |> repo.update()
  end

  defp write_row(repo, message_uuid, item, position) do
    %Attachment{}
    |> Attachment.changeset(%{
      message_uuid: message_uuid,
      file_uuid: item.file_uuid,
      source_file_uuid: item.source_file_uuid,
      filename: item.filename,
      content_type: item.content_type,
      size_bytes: item.size_bytes,
      position: position
    })
    # Server-set only, never cast from anything a form could reach.
    |> Ecto.Changeset.put_change(:flags, item.flags || %{})
    |> repo.insert()
  end

  @doc false
  # Deletes each of `file_uuids` that is an Inbox-library file no attachment
  # row names any more. Best-effort, after the transaction.
  @spec release([binary()]) :: :ok
  def release([]), do: :ok

  def release(file_uuids) do
    library = library_uuid()
    file_uuids = Enum.uniq(file_uuids)

    named =
      from(a in Attachment, where: a.file_uuid in ^file_uuids, select: a.file_uuid)
      |> repo().all()
      |> MapSet.new(&to_string/1)

    for uuid <- file_uuids, not MapSet.member?(named, uuid), do: delete_snapshot(uuid, library)

    :ok
  end

  # Only ever a file of the Inbox library.
  defp delete_snapshot(uuid, library) do
    with %Storage.File{} = file <- Storage.get_file(uuid),
         true <- in_library?(file, library),
         {:error, reason} <- Storage.delete_file_completely(file) do
      Logger.warning("[Inbox] could not delete snapshot #{uuid}: #{inspect(reason)}")
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # The browser's (or host's) name, reduced to a base name without control
  # characters, fit for the 255-character column with its extension kept.
  defp clean_filename(name) do
    name =
      name
      |> to_string()
      |> String.replace(~r/[\x00-\x1F\x7F]/u, "")
      |> String.split(["/", "\\"])
      |> List.last()
      |> String.trim()

    if name in ["", ".", ".."], do: "attachment", else: bound_filename(name)
  end

  defp bound_filename(name) do
    if String.length(name) <= @max_filename do
      name
    else
      ext = Path.extname(name)
      keep = max(@max_filename - String.length(ext), 1)
      String.slice(Path.rootname(name), 0, keep) <> String.slice(ext, 0, @max_filename - keep)
    end
  end
end
