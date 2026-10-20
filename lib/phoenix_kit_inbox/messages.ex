defmodule PhoenixKitInbox.Messages do
  @moduledoc """
  Composing, sending, listing, and filing messages.

  ## The send path

  `send_message/3` is one `Ecto.Multi`, so a message is never half-delivered:

    1. resolve every recipient string to a mailbox (unknown ones fail the whole
       send — silently dropping a recipient is worse than refusing)
    2. insert or update the message with `status: "sent"` and a `sent_at` stamp
    3. fan out one `Delivery` per recipient into their `"inbox"`, plus the
       sender's own copy into `"sent"`

  Notifications are fired *after* the transaction commits, by
  `PhoenixKitInbox.Notify` — a notification for a message that got rolled back
  would be a lie, and an outbound-email failure must never roll back a
  successfully delivered internal message.

  ## Reads

  Every list query is scoped to a single mailbox and folder, hitting the
  `(mailbox_uuid, folder, inserted_at)` index from V01. Nothing here reads
  across mailboxes — that's the whole point of the per-mailbox delivery row.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Notify
  alias PhoenixKitInbox.Schemas.Delivery
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Schemas.Message

  @default_limit 50
  @recipient_roles ~w(to cc bcc)
  # Where a draft keeps what was typed into To/Cc/Bcc — text, unresolved.
  @draft_recipients_key "draft_recipients"

  @typedoc """
  A message as the UI consumes it: the delivery row (folder/seen/starred state
  for *this* mailbox) plus the message it points at.
  """
  @type listed :: %{delivery: Delivery.t(), message: Message.t()}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── reads ───────────────────────────────────────────────────────────────────

  @doc """
  Lists one folder of one mailbox, newest first.

  ## Options

    * `:limit` — default #{@default_limit}
    * `:offset` — default 0
    * `:unseen_only` — only rows with no `seen_at`
    * `:search` — case-insensitive match on subject or body
  """
  @spec list_folder(binary(), String.t(), keyword()) :: [listed()]
  def list_folder(mailbox_uuid, folder, opts \\ [])

  def list_folder(mailbox_uuid, folder, opts) when is_binary(mailbox_uuid) do
    mailbox_uuid
    |> folder_query(folder, opts)
    |> limit(^Keyword.get(opts, :limit, @default_limit))
    |> offset(^Keyword.get(opts, :offset, 0))
    |> repo().all()
    |> Enum.map(fn {delivery, message} -> %{delivery: delivery, message: message} end)
  end

  def list_folder(_, _, _), do: []

  @doc "Row count for a folder, for pagination and the sidebar totals."
  @spec count_folder(binary(), String.t(), keyword()) :: non_neg_integer()
  def count_folder(mailbox_uuid, folder, opts \\ [])

  def count_folder(mailbox_uuid, folder, opts) when is_binary(mailbox_uuid) do
    mailbox_uuid
    |> folder_query(folder, opts)
    |> exclude(:order_by)
    |> exclude(:select)
    |> select([d], count(d.uuid))
    |> repo().one()
    |> Kernel.||(0)
  end

  def count_folder(_, _, _), do: 0

  defp folder_query(mailbox_uuid, folder, opts) do
    from(d in Delivery,
      join: m in Message,
      on: m.uuid == d.message_uuid,
      where: d.mailbox_uuid == ^mailbox_uuid,
      where: d.folder == ^folder,
      where: d.status == "active",
      order_by: [desc: d.inserted_at, desc: d.uuid],
      select: {d, m}
    )
    |> maybe_unseen_only(Keyword.get(opts, :unseen_only, false))
    |> maybe_search(Keyword.get(opts, :search))
  end

  defp maybe_unseen_only(query, true), do: where(query, [d], is_nil(d.seen_at))
  defp maybe_unseen_only(query, _), do: query

  defp maybe_search(query, term) when is_binary(term) do
    case String.trim(term) do
      "" ->
        query

      trimmed ->
        pattern = "%#{trimmed}%"
        where(query, [_d, m], ilike(m.subject, ^pattern) or ilike(m.body, ^pattern))
    end
  end

  defp maybe_search(query, _), do: query

  @doc """
  Fetches one message *as seen by one mailbox*.

  Scoped to the delivery on purpose: passing a message uuid a mailbox was never
  sent is a `{:error, :message_not_found}`, not a read of someone else's mail.
  """
  @spec fetch_for_mailbox(binary(), binary()) :: {:ok, listed()} | {:error, :message_not_found}
  def fetch_for_mailbox(mailbox_uuid, message_uuid)
      when is_binary(mailbox_uuid) and is_binary(message_uuid) do
    query =
      from(d in Delivery,
        join: m in Message,
        on: m.uuid == d.message_uuid,
        where: d.mailbox_uuid == ^mailbox_uuid,
        where: d.message_uuid == ^message_uuid,
        where: d.status == "active",
        limit: 1,
        select: {d, m}
      )

    case repo().one(query) do
      nil -> {:error, :message_not_found}
      {delivery, message} -> {:ok, %{delivery: delivery, message: message}}
    end
  end

  def fetch_for_mailbox(_, _), do: {:error, :message_not_found}

  @doc "Every message in a thread, oldest first — the conversation view."
  @spec list_thread(binary()) :: [Message.t()]
  def list_thread(thread_uuid) when is_binary(thread_uuid) do
    from(m in Message,
      where: m.thread_uuid == ^thread_uuid,
      where: m.status == "sent",
      order_by: [asc: m.inserted_at]
    )
    |> repo().all()
  end

  @doc """
  The recipient mailboxes of a message, with their roles — every row, `bcc`
  included. For showing a message to someone, use `list_recipients/2`.
  """
  @spec list_recipients(binary()) :: [%{role: String.t(), mailbox: Mailbox.t()}]
  def list_recipients(message_uuid) when is_binary(message_uuid) do
    from(d in Delivery,
      join: mb in Mailbox,
      on: mb.uuid == d.mailbox_uuid,
      where: d.message_uuid == ^message_uuid,
      where: d.role != "from",
      order_by: [asc: d.role, asc: mb.name],
      select: {d.role, mb}
    )
    |> repo().all()
    |> Enum.map(fn {role, mailbox} -> %{role: role, mailbox: mailbox} end)
  end

  def list_recipients(_), do: []

  @doc """
  The recipients of a message as the mailbox `viewer_mailbox_uuid` may see
  them — the To/Cc chips in the reading pane.

  The sending mailbox sees everyone. Any other reader sees To and Cc, and a
  Bcc row only if it is their own: a blind copy stays blind to the other
  recipients, including the other Bcc ones.
  """
  @spec list_recipients(binary(), binary()) :: [%{role: String.t(), mailbox: Mailbox.t()}]
  def list_recipients(message_uuid, viewer_mailbox_uuid)
      when is_binary(message_uuid) and is_binary(viewer_mailbox_uuid) do
    sender? =
      from(m in Message,
        where: m.uuid == ^message_uuid and m.sender_mailbox_uuid == ^viewer_mailbox_uuid
      )
      |> repo().exists?()

    message_uuid
    |> list_recipients()
    |> Enum.filter(fn %{role: role, mailbox: mailbox} ->
      sender? or role != "bcc" or mailbox.uuid == viewer_mailbox_uuid
    end)
  end

  def list_recipients(_, _), do: []

  # ── drafts ──────────────────────────────────────────────────────────────────

  @doc "Changeset for the compose form."
  @spec change_message(Message.t(), map()) :: Ecto.Changeset.t()
  def change_message(%Message{} = message, attrs \\ %{}) do
    Message.changeset(message, normalize_attrs(attrs))
  end

  @doc """
  Saves a draft owned by `mailbox`, creating it on first save and updating it
  on subsequent ones. The draft gets exactly one delivery — into the author's
  own `"drafts"` folder.

  Recipients are *not* resolved here. A half-typed address is a normal state
  for a draft; validation happens at send. What was typed into `"to"`, `"cc"`
  and `"bcc"` is kept as text (`draft_recipients/1` reads it back) so a
  reopened draft still has its recipients.

  Like sending, saving needs `"write"` on the mailbox
  (`{:error, :mailbox_access_denied}`).
  """
  @spec save_draft(Mailbox.t(), binary(), map()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t() | atom()}
  def save_draft(%Mailbox{} = mailbox, sender_user_uuid, attrs) do
    with :ok <- Mailboxes.authorize(mailbox, sender_user_uuid, "write") do
      do_save_draft(mailbox, sender_user_uuid, normalize_attrs(attrs))
    end
  end

  defp do_save_draft(mailbox, sender_user_uuid, attrs) do
    existing = draft_from_attrs(mailbox, attrs)

    base = existing || %Message{}

    metadata =
      attrs
      |> caller_metadata(base)
      |> Map.put(@draft_recipients_key, typed_recipients(attrs))

    changeset =
      Message.changeset(base, %{
        "thread_uuid" => base.thread_uuid || Map.get(attrs, "thread_uuid"),
        "parent_uuid" => Map.get(attrs, "parent_uuid", base.parent_uuid),
        "sender_mailbox_uuid" => mailbox.uuid,
        "sender_user_uuid" => sender_user_uuid,
        "subject" => Map.get(attrs, "subject"),
        "body" => Map.get(attrs, "body"),
        "body_format" => Map.get(attrs, "body_format", "text"),
        "status" => "draft",
        "metadata" => metadata
      })

    Multi.new()
    |> Multi.run(:message, fn repo, _ ->
      if existing,
        do: repo.update(changeset),
        else: repo.insert(ensure_thread_uuid(changeset))
    end)
    |> Multi.run(:thread, &backfill_thread_uuid/2)
    |> Multi.run(:delivery, fn repo, %{thread: message} ->
      upsert_delivery(repo, message.uuid, mailbox.uuid, "from", "drafts")
    end)
    |> repo().transaction()
    |> case do
      {:ok, %{thread: message}} -> {:ok, message}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  The recipients typed into a draft when it was last saved, as
  `%{"to" => text, "cc" => text, "bcc" => text}` — blank strings when none.
  """
  @spec draft_recipients(Message.t()) :: %{String.t() => String.t()}
  def draft_recipients(%Message{metadata: %{@draft_recipients_key => saved}})
      when is_map(saved) do
    Map.new(@recipient_roles, &{&1, Map.get(saved, &1) || ""})
  end

  def draft_recipients(%Message{}), do: Map.new(@recipient_roles, &{&1, ""})

  defp typed_recipients(attrs) do
    Map.new(@recipient_roles, fn role ->
      {role, attrs |> Map.get(role) |> recipient_text()}
    end)
  end

  # The caller's "metadata" when it is a map, else what the message had.
  defp caller_metadata(attrs, base) do
    case Map.get(attrs, "metadata") do
      metadata when is_map(metadata) -> metadata
      _ -> base.metadata || %{}
    end
  end

  defp recipient_text(list) when is_list(list), do: Enum.map_join(list, ", ", &to_string/1)

  defp recipient_text(text) when is_binary(text), do: text
  defp recipient_text(_), do: ""

  defp draft_from_attrs(mailbox, attrs) do
    case Map.get(attrs, "uuid") do
      uuid when is_binary(uuid) and uuid != "" ->
        repo().get_by(Message, uuid: uuid, sender_mailbox_uuid: mailbox.uuid, status: "draft")

      _ ->
        nil
    end
  end

  @doc "Discards a draft and its delivery row. Only the author's own drafts."
  @spec delete_draft(Mailbox.t(), binary()) :: :ok | {:error, :message_not_found}
  def delete_draft(%Mailbox{} = mailbox, message_uuid) when is_binary(message_uuid) do
    case repo().get_by(Message,
           uuid: message_uuid,
           sender_mailbox_uuid: mailbox.uuid,
           status: "draft"
         ) do
      nil ->
        {:error, :message_not_found}

      message ->
        # Deliveries cascade via the FK's on_delete: :delete_all.
        repo().delete(message)
        :ok
    end
  end

  # ── sending ─────────────────────────────────────────────────────────────────

  @doc """
  Sends a message from `mailbox`, as the scope's user (`send_message/4`) or as
  `sender_user_uuid` (the original three-argument form).

  Both forms check that the sender holds at least `"write"` on `mailbox`
  (`{:error, :mailbox_access_denied}`) — the context is the boundary, not the
  compose form. The scope form also requires the `"inbox"` permission
  (`{:error, :forbidden}`). Recipients are internal only: a term that names no
  member or shared mailbox is an unknown recipient. `opts` is reserved for
  server-side options and currently unused.

  `attrs` keys:

    * `"to"` / `"cc"` / `"bcc"` — comma-separated recipient strings, or lists.
      Each entry is a `@username`, an email, or a shared mailbox's slug, name
      or address (see `Mailboxes.fetch_mailbox_by_recipient/1`).
    * `"subject"`, `"body"`, `"body_format"`
    * `"uuid"` — promotes an existing draft instead of creating a new message
    * `"parent_uuid"` — set when replying; the thread is inherited from it
    * `"metadata"` — a map stored on the message. Its `"sender"` and
      `"recipients"` keys are always written by the send itself: a snapshot of
      the sender (user uuid, name, email, mailbox name) and of each recipient
      (role, mailbox uuid, mailbox name) at send time, so who wrote to whom
      stays readable after an account is deleted. The recipient snapshot
      includes `bcc` rows — show it to the sender only.

  Returns `{:error, {:unknown_recipients, ["typo@example.com"]}}` when an
  address doesn't resolve — the whole send is refused so the sender finds out
  immediately rather than discovering a missing recipient later — and
  `{:error, {:ambiguous_recipients, ["@alice"]}}` when one names two people.
  """
  @spec send_message(Scope.t() | Mailbox.t(), Mailbox.t() | binary() | nil, map(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def send_message(sender, mailbox_or_user, attrs, opts \\ [])

  def send_message(%Scope{} = scope, %Mailbox{} = mailbox, attrs, _opts) when is_map(attrs) do
    with {:ok, user_uuid} <- scope_user_uuid(scope),
         :ok <- authorize_inbox(scope) do
      deliver(mailbox, user_uuid, attrs)
    end
  end

  def send_message(%Mailbox{} = mailbox, sender_user_uuid, attrs, _opts) when is_map(attrs) do
    deliver(mailbox, sender_user_uuid, attrs)
  end

  defp deliver(mailbox, sender_user_uuid, attrs) do
    attrs = normalize_attrs(attrs)

    with :ok <- Mailboxes.authorize(mailbox, sender_user_uuid, "write"),
         {:ok, recipients} <- resolve_recipients(attrs),
         :ok <- ensure_any_recipient(recipients),
         {:ok, message} <- do_send(mailbox, sender_user_uuid, attrs, recipients) do
      # Post-commit, deliberately: see the moduledoc.
      Notify.message_sent(message, mailbox, recipients)
      {:ok, message}
    end
  end

  defp scope_user_uuid(%Scope{user: %{uuid: uuid}}) when is_binary(uuid), do: {:ok, uuid}
  defp scope_user_uuid(_), do: {:error, :forbidden}

  defp authorize_inbox(scope) do
    if Scope.can?(scope, "inbox"), do: :ok, else: {:error, :forbidden}
  end

  defp do_send(mailbox, sender_user_uuid, attrs, recipients) do
    existing = draft_from_attrs(mailbox, attrs)
    base = existing || %Message{}
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    parent_uuid = Map.get(attrs, "parent_uuid", base.parent_uuid)

    changeset =
      Message.sent_changeset(base, %{
        "thread_uuid" => base.thread_uuid || thread_uuid_for(parent_uuid),
        "parent_uuid" => parent_uuid,
        "sender_mailbox_uuid" => mailbox.uuid,
        "sender_user_uuid" => sender_user_uuid,
        "subject" => Map.get(attrs, "subject"),
        "body" => Map.get(attrs, "body"),
        "body_format" => Map.get(attrs, "body_format", "text"),
        "sent_at" => now,
        "metadata" =>
          attrs
          |> caller_metadata(base)
          |> Map.delete(@draft_recipients_key)
          |> Map.merge(send_record(mailbox, sender_user_uuid, recipients))
      })

    Multi.new()
    |> Multi.run(:message, fn repo, _ ->
      if existing,
        do: repo.update(changeset),
        else: repo.insert(ensure_thread_uuid(changeset))
    end)
    |> Multi.run(:thread, &backfill_thread_uuid/2)
    |> Multi.run(:sender_copy, fn repo, %{thread: message} ->
      # Moves the draft's own delivery row from "drafts" to "sent" when
      # promoting a draft, or creates it outright for a fresh send.
      upsert_delivery(repo, message.uuid, mailbox.uuid, "from", "sent")
    end)
    |> Multi.run(:deliveries, fn repo, %{thread: message} ->
      fan_out(repo, message, recipients)
    end)
    |> repo().transaction()
    |> case do
      {:ok, %{thread: message}} -> {:ok, message}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # Server-written, so a caller's "sender" key can't impersonate anyone.
  defp send_record(mailbox, sender_user_uuid, recipients) do
    user = if is_binary(sender_user_uuid), do: repo().get(User, sender_user_uuid)

    %{
      "sender" => %{
        "user_uuid" => sender_user_uuid,
        "name" => user && Mailboxes.user_display_name(user),
        "email" => user && user.email,
        "mailbox" => mailbox.name
      },
      "recipients" =>
        Enum.map(recipients, fn %{role: role, mailbox: recipient} ->
          %{"role" => role, "mailbox_uuid" => recipient.uuid, "name" => recipient.name}
        end)
    }
  end

  defp fan_out(repo, message, recipients) do
    Enum.reduce_while(recipients, {:ok, []}, fn %{role: role, mailbox: mailbox}, {:ok, acc} ->
      case upsert_delivery(repo, message.uuid, mailbox.uuid, role, "inbox") do
        {:ok, delivery} -> {:cont, {:ok, [delivery | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A reply belongs to its parent's thread; a new message starts its own, which
  # `backfill_thread_uuid/2` stamps once the uuid exists.
  defp thread_uuid_for(nil), do: nil

  defp thread_uuid_for(parent_uuid) do
    case repo().get(Message, parent_uuid) do
      nil -> nil
      parent -> parent.thread_uuid
    end
  end

  # The root of a thread is its own thread — but `thread_uuid` is NOT NULL and
  # the uuid doesn't exist until after insert, so it's written back here.
  # `phoenix_kit_inbox_messages.thread_uuid` is NOT NULL, so a root message
  # cannot be inserted with a nil thread and stamped afterwards -- the INSERT
  # fails before `backfill_thread_uuid/2` can run, which is why no message
  # could be created at all.
  #
  # A root message IS its own thread, so mint the uuid up front and set both
  # columns in the same INSERT. `put_change/3` rather than `cast/3` because
  # `:uuid` is the autogenerated primary key and is deliberately not castable.
  # Replies already inherit their parent's thread and are left alone, as are
  # updates to an already-threaded row.
  defp ensure_thread_uuid(%Ecto.Changeset{data: %Message{thread_uuid: nil}} = changeset) do
    case Ecto.Changeset.get_field(changeset, :thread_uuid) do
      nil ->
        uuid = Ecto.Changeset.get_field(changeset, :uuid) || UUIDv7.generate()

        changeset
        |> Ecto.Changeset.put_change(:uuid, uuid)
        |> Ecto.Changeset.put_change(:thread_uuid, uuid)

      _ ->
        changeset
    end
  end

  defp ensure_thread_uuid(changeset), do: changeset

  defp backfill_thread_uuid(repo, %{message: %Message{thread_uuid: nil} = message}) do
    message
    |> Ecto.Changeset.change(thread_uuid: message.uuid)
    |> repo.update()
  end

  defp backfill_thread_uuid(_repo, %{message: message}), do: {:ok, message}

  defp upsert_delivery(repo, message_uuid, mailbox_uuid, role, folder) do
    case repo.get_by(Delivery, message_uuid: message_uuid, mailbox_uuid: mailbox_uuid, role: role) do
      nil ->
        %Delivery{}
        |> Delivery.changeset(%{
          message_uuid: message_uuid,
          mailbox_uuid: mailbox_uuid,
          role: role,
          folder: folder,
          # The sender's own copy is read by definition.
          seen_at: if(role == "from", do: DateTime.utc_now() |> DateTime.truncate(:second))
        })
        |> repo.insert()

      delivery ->
        delivery
        |> Delivery.changeset(%{folder: folder, status: "active"})
        |> repo.update()
    end
  end

  defp resolve_recipients(attrs) do
    parsed =
      for role <- ~w(to cc bcc),
          entry <- parse_recipient_list(Map.get(attrs, role)),
          do: {role, entry}

    {resolved, unknown, ambiguous} =
      Enum.reduce(parsed, {[], [], []}, fn {role, entry}, {ok, unknown, ambiguous} ->
        case Mailboxes.fetch_mailbox_by_recipient(entry) do
          {:ok, mailbox} -> {[%{role: role, mailbox: mailbox} | ok], unknown, ambiguous}
          {:error, :ambiguous_recipient} -> {ok, unknown, [entry | ambiguous]}
          {:error, _} -> {ok, [entry | unknown], ambiguous}
        end
      end)

    case {unknown, ambiguous} do
      {[], []} -> {:ok, resolved |> Enum.reverse() |> dedupe_recipients()}
      {[], ambiguous} -> {:error, {:ambiguous_recipients, Enum.reverse(ambiguous)}}
      {unknown, _} -> {:error, {:unknown_recipients, Enum.reverse(unknown)}}
    end
  end

  # A mailbox listed in both To and Cc gets one copy, keeping the stronger role
  # — otherwise the unique index on (message, mailbox, role) would let the same
  # person appear twice in the thread.
  defp dedupe_recipients(recipients) do
    recipients
    |> Enum.group_by(& &1.mailbox.uuid)
    |> Enum.map(fn {_uuid, group} ->
      Enum.min_by(group, fn %{role: role} -> Enum.find_index(~w(to cc bcc), &(&1 == role)) end)
    end)
    |> Enum.sort_by(& &1.mailbox.name)
  end

  defp parse_recipient_list(nil), do: []

  defp parse_recipient_list(value) when is_binary(value) do
    value
    |> String.split(~r/[,;]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_recipient_list(value) when is_list(value) do
    value |> Enum.flat_map(&parse_recipient_list/1)
  end

  defp parse_recipient_list(_), do: []

  defp ensure_any_recipient([]), do: {:error, :no_recipients}
  defp ensure_any_recipient(_), do: :ok

  # ── per-mailbox state ───────────────────────────────────────────────────────

  @doc "Marks a delivery seen. Idempotent — an already-seen row keeps its original stamp."
  @spec mark_seen(binary(), binary()) :: {:ok, Delivery.t()} | {:error, :message_not_found}
  def mark_seen(mailbox_uuid, message_uuid) do
    update_delivery(mailbox_uuid, message_uuid, fn
      %Delivery{seen_at: nil} = delivery ->
        %{seen_at: DateTime.utc_now() |> DateTime.truncate(:second)}
        |> then(&Delivery.changeset(delivery, &1))
        |> repo().update()

      delivery ->
        {:ok, delivery}
    end)
  end

  @doc "Marks a delivery unseen."
  @spec mark_unseen(binary(), binary()) :: {:ok, Delivery.t()} | {:error, :message_not_found}
  def mark_unseen(mailbox_uuid, message_uuid) do
    update_delivery(mailbox_uuid, message_uuid, fn delivery ->
      delivery
      |> Ecto.Changeset.change(seen_at: nil)
      |> repo().update()
    end)
  end

  @doc "Flips the star on a delivery."
  @spec toggle_star(binary(), binary()) :: {:ok, Delivery.t()} | {:error, :message_not_found}
  def toggle_star(mailbox_uuid, message_uuid) do
    update_delivery(mailbox_uuid, message_uuid, fn delivery ->
      delivery
      |> Delivery.changeset(%{starred: !delivery.starred})
      |> repo().update()
    end)
  end

  @doc """
  Moves a delivery to another folder — the one operation behind Archive, Spam,
  Trash, and Restore in the UI.
  """
  @spec move_to_folder(binary(), binary(), String.t()) ::
          {:ok, Delivery.t()} | {:error, :message_not_found | Ecto.Changeset.t()}
  def move_to_folder(mailbox_uuid, message_uuid, folder) do
    update_delivery(mailbox_uuid, message_uuid, fn delivery ->
      delivery
      |> Delivery.changeset(%{folder: folder})
      |> repo().update()
    end)
  end

  @doc """
  Permanently removes a mailbox's copy of a message. The message itself and
  other mailboxes' copies are untouched — deleting your copy of a group thread
  doesn't delete anyone else's.
  """
  @spec purge(binary(), binary()) :: :ok | {:error, :message_not_found}
  def purge(mailbox_uuid, message_uuid) do
    case update_delivery(mailbox_uuid, message_uuid, fn delivery ->
           delivery
           |> Delivery.changeset(%{status: "deleted"})
           |> repo().update()
         end) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp update_delivery(mailbox_uuid, message_uuid, fun)
       when is_binary(mailbox_uuid) and is_binary(message_uuid) do
    query =
      from(d in Delivery,
        where: d.mailbox_uuid == ^mailbox_uuid,
        where: d.message_uuid == ^message_uuid,
        where: d.status == "active",
        limit: 1
      )

    case repo().one(query) do
      nil -> {:error, :message_not_found}
      delivery -> fun.(delivery)
    end
  end

  defp update_delivery(_, _, _), do: {:error, :message_not_found}

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
