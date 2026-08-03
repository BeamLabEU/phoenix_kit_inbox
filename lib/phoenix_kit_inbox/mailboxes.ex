defmodule PhoenixKitInbox.Mailboxes do
  @moduledoc """
  Mailbox lifecycle and access control.

  Two ownership models share one table (see
  `PhoenixKitInbox.Schemas.Mailbox`):

    * every user gets exactly one **personal** mailbox, created lazily on first
      visit by `ensure_user_mailbox/1`
    * **shared** mailboxes (`support`, `sales`, …) are created by an admin and
      reached through grants

  Access is a two-level check, matching how `phoenix_kit_calendar` gates other
  people's calendars: the module-level `"inbox"` permission decides whether a
  user can open Inbox at all, and a grant decides which mailboxes they see once
  inside. Ownership always implies `"admin"` access — the owner never needs a
  grant to their own mailbox.

  Every function here takes and returns plain data; the LiveViews own no
  queries of their own.
  """

  import Ecto.Query

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitInbox.Schemas.Delivery
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Schemas.MailboxGrant

  @type access :: String.t()

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── reads ───────────────────────────────────────────────────────────────────

  @doc """
  Fetches a mailbox by uuid.

  Returns `{:error, :mailbox_not_found}` rather than nil so callers can pipe
  through `with` and let `PhoenixKitInbox.Errors` render the reason.
  """
  @spec fetch_mailbox(binary()) :: {:ok, Mailbox.t()} | {:error, :mailbox_not_found}
  def fetch_mailbox(uuid) when is_binary(uuid) do
    case repo().get(Mailbox, uuid) do
      nil -> {:error, :mailbox_not_found}
      mailbox -> {:ok, mailbox}
    end
  end

  def fetch_mailbox(_), do: {:error, :mailbox_not_found}

  @doc "Fetches a mailbox by its unique slug."
  @spec fetch_mailbox_by_slug(String.t()) :: {:ok, Mailbox.t()} | {:error, :mailbox_not_found}
  def fetch_mailbox_by_slug(slug) when is_binary(slug) do
    case repo().get_by(Mailbox, slug: slug) do
      nil -> {:error, :mailbox_not_found}
      mailbox -> {:ok, mailbox}
    end
  end

  @doc """
  Every mailbox `user_uuid` may open, personal first then shared, each
  alphabetical. Archived and deleted mailboxes are excluded.

  This is the sidebar query — one round trip, no N+1 over grants.
  """
  @spec list_accessible_mailboxes(binary()) :: [Mailbox.t()]
  def list_accessible_mailboxes(user_uuid) when is_binary(user_uuid) do
    granted =
      from(g in MailboxGrant, where: g.user_uuid == ^user_uuid, select: g.mailbox_uuid)

    from(m in Mailbox,
      where: m.status == "active",
      where: m.owner_uuid == ^user_uuid or m.uuid in subquery(granted),
      order_by: [asc: fragment("case when ? = 'user' then 0 else 1 end", m.kind), asc: m.name]
    )
    |> repo().all()
  end

  def list_accessible_mailboxes(_), do: []

  @doc "All shared mailboxes, for the admin management page."
  @spec list_shared_mailboxes() :: [Mailbox.t()]
  def list_shared_mailboxes do
    from(m in Mailbox, where: m.kind == "shared", order_by: [asc: m.name])
    |> repo().all()
  end

  @doc """
  Resolves a mailbox for an address or slug, for the compose recipient picker.

  Accepts either form because users type both: `"support"` (the slug of a
  shared mailbox) and `"alice@example.com"` (a personal mailbox's address).
  """
  @spec fetch_mailbox_by_recipient(String.t()) ::
          {:ok, Mailbox.t()} | {:error, :recipient_not_found}
  def fetch_mailbox_by_recipient(term) when is_binary(term) do
    normalized = term |> String.trim() |> String.downcase()

    query =
      from(m in Mailbox,
        where: m.status == "active",
        where: m.address == ^normalized or m.slug == ^normalized,
        limit: 1
      )

    case repo().one(query) do
      nil -> {:error, :recipient_not_found}
      mailbox -> {:ok, mailbox}
    end
  end

  def fetch_mailbox_by_recipient(_), do: {:error, :recipient_not_found}

  @doc """
  Suggests mailboxes matching a partial name/slug/address, for recipient
  autocomplete. Capped — this runs on every keystroke.
  """
  @spec search_mailboxes(binary(), String.t(), keyword()) :: [Mailbox.t()]
  def search_mailboxes(user_uuid, term, opts \\ [])

  def search_mailboxes(user_uuid, term, opts) when is_binary(user_uuid) and is_binary(term) do
    limit = Keyword.get(opts, :limit, 10)
    pattern = "%#{term |> String.trim() |> String.downcase()}%"

    from(m in Mailbox,
      where: m.status == "active",
      where: m.owner_uuid != ^user_uuid or m.kind == "shared",
      where: ilike(m.name, ^pattern) or ilike(m.slug, ^pattern) or ilike(m.address, ^pattern),
      order_by: [asc: m.name],
      limit: ^limit
    )
    |> repo().all()
  end

  def search_mailboxes(_, _, _), do: []

  # ── personal mailboxes ──────────────────────────────────────────────────────

  @doc """
  Returns the user's personal mailbox, creating it on first call.

  Lazy creation rather than a hook on user signup: it keeps Inbox from needing
  to reach into core's registration flow, and it means the module works
  correctly for users who already existed before it was installed.

  The `unique_index ... where kind = 'user'` in V01 makes the race safe — two
  concurrent mounts can both miss the read, and the loser of the insert falls
  back to reading the winner's row.
  """
  @spec ensure_user_mailbox(User.t() | map()) ::
          {:ok, Mailbox.t()} | {:error, Ecto.Changeset.t() | :invalid_user}
  def ensure_user_mailbox(%{uuid: uuid} = user) when is_binary(uuid) do
    case repo().get_by(Mailbox, owner_uuid: uuid, kind: "user") do
      nil -> create_user_mailbox(user)
      mailbox -> {:ok, mailbox}
    end
  end

  def ensure_user_mailbox(_), do: {:error, :invalid_user}

  defp create_user_mailbox(%{uuid: uuid} = user) do
    attrs = %{
      name: user_display_name(user),
      slug: personal_slug(uuid),
      address: Map.get(user, :email),
      kind: "user",
      owner_uuid: uuid
    }

    %Mailbox{}
    |> Mailbox.changeset(attrs)
    |> repo().insert()
    |> case do
      {:ok, mailbox} ->
        {:ok, mailbox}

      # Lost the insert race — the other process created it, so read it back.
      {:error, changeset} ->
        case repo().get_by(Mailbox, owner_uuid: uuid, kind: "user") do
          nil -> {:error, changeset}
          mailbox -> {:ok, mailbox}
        end
    end
  end

  # Personal slugs are derived from the uuid, not the email: emails change, and
  # a slug collision between two users named "alice" would be a hard failure at
  # signup rather than a cosmetic one.
  defp personal_slug(uuid), do: "u-" <> String.replace(uuid, "-", "")

  @doc """
  Best-effort display name for a user — full name, else username, else the
  local part of their email, else a short uuid.
  """
  @spec user_display_name(map()) :: String.t()
  def user_display_name(user) do
    full_name =
      [Map.get(user, :first_name), Map.get(user, :last_name)]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join(" ")

    cond do
      full_name != "" -> full_name
      is_binary(Map.get(user, :username)) and user.username != "" -> user.username
      is_binary(Map.get(user, :email)) -> user.email |> String.split("@") |> hd()
      true -> "User " <> String.slice(to_string(Map.get(user, :uuid)), 0, 8)
    end
  end

  # ── shared mailboxes ────────────────────────────────────────────────────────

  @doc """
  Creates a shared mailbox owned by `owner_uuid`.

  `attrs` needs at least `:name`; `:slug` is derived from the name when absent.
  """
  @spec create_shared_mailbox(binary(), map()) ::
          {:ok, Mailbox.t()} | {:error, Ecto.Changeset.t()}
  def create_shared_mailbox(owner_uuid, attrs) when is_binary(owner_uuid) do
    attrs =
      attrs
      |> normalize_attrs()
      |> Map.put("kind", "shared")
      |> Map.put("owner_uuid", owner_uuid)
      |> put_default_slug()

    %Mailbox{}
    |> Mailbox.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates a mailbox's name/address/settings."
  @spec update_mailbox(Mailbox.t(), map()) :: {:ok, Mailbox.t()} | {:error, Ecto.Changeset.t()}
  def update_mailbox(%Mailbox{} = mailbox, attrs) do
    mailbox
    |> Mailbox.changeset(normalize_attrs(attrs))
    |> repo().update()
  end

  @doc """
  Archives a mailbox — the soft-delete form used across this workspace (a
  sentinel on the existing `status` column, never a `deleted_at` timestamp).

  Personal mailboxes cannot be archived: a user always has somewhere for mail
  to land.
  """
  @spec archive_mailbox(Mailbox.t()) ::
          {:ok, Mailbox.t()} | {:error, Ecto.Changeset.t() | :cannot_archive_personal_mailbox}
  def archive_mailbox(%Mailbox{kind: "user"}), do: {:error, :cannot_archive_personal_mailbox}

  def archive_mailbox(%Mailbox{} = mailbox) do
    mailbox
    |> Mailbox.changeset(%{"status" => "archived"})
    |> repo().update()
  end

  @doc "Reverses `archive_mailbox/1`."
  @spec restore_mailbox(Mailbox.t()) :: {:ok, Mailbox.t()} | {:error, Ecto.Changeset.t()}
  def restore_mailbox(%Mailbox{} = mailbox) do
    mailbox
    |> Mailbox.changeset(%{"status" => "active"})
    |> repo().update()
  end

  @doc "Changeset for mailbox forms."
  @spec change_mailbox(Mailbox.t(), map()) :: Ecto.Changeset.t()
  def change_mailbox(%Mailbox{} = mailbox, attrs \\ %{}) do
    Mailbox.changeset(mailbox, normalize_attrs(attrs))
  end

  # ── grants ──────────────────────────────────────────────────────────────────

  @doc "All grants on a mailbox, for the mailbox admin page."
  @spec list_grants(binary()) :: [MailboxGrant.t()]
  def list_grants(mailbox_uuid) when is_binary(mailbox_uuid) do
    from(g in MailboxGrant,
      where: g.mailbox_uuid == ^mailbox_uuid,
      order_by: [asc: g.inserted_at]
    )
    |> repo().all()
  end

  @doc """
  Grants (or re-grants) `user_uuid` access to a mailbox.

  Upsert semantics: re-granting an existing user simply changes their level,
  which is what "set access to write" means in the UI.
  """
  @spec grant_access(binary(), binary(), access(), keyword()) ::
          {:ok, MailboxGrant.t()} | {:error, Ecto.Changeset.t()}
  def grant_access(mailbox_uuid, user_uuid, access, opts \\ []) do
    granted_by = Keyword.get(opts, :granted_by_uuid)

    attrs = %{
      mailbox_uuid: mailbox_uuid,
      user_uuid: user_uuid,
      access: access,
      granted_by_uuid: granted_by
    }

    existing = repo().get_by(MailboxGrant, mailbox_uuid: mailbox_uuid, user_uuid: user_uuid)

    (existing || %MailboxGrant{})
    |> MailboxGrant.changeset(attrs)
    |> then(&if existing, do: repo().update(&1), else: repo().insert(&1))
  end

  @doc "Removes a user's grant on a mailbox. Idempotent."
  @spec revoke_access(binary(), binary()) :: :ok
  def revoke_access(mailbox_uuid, user_uuid) do
    from(g in MailboxGrant, where: g.mailbox_uuid == ^mailbox_uuid and g.user_uuid == ^user_uuid)
    |> repo().delete_all()

    :ok
  end

  @doc """
  The access level `user_uuid` holds on `mailbox`, or `nil` for none.

  Ownership short-circuits to `"admin"` — the owner is never listed in their
  own grants table.
  """
  @spec access_level(Mailbox.t(), binary()) :: access() | nil
  def access_level(%Mailbox{owner_uuid: owner}, user_uuid) when owner == user_uuid, do: "admin"

  def access_level(%Mailbox{uuid: mailbox_uuid}, user_uuid) when is_binary(user_uuid) do
    from(g in MailboxGrant,
      where: g.mailbox_uuid == ^mailbox_uuid and g.user_uuid == ^user_uuid,
      select: g.access
    )
    |> repo().one()
  end

  def access_level(_, _), do: nil

  @doc """
  Whether `user_uuid` holds at least `required` access on `mailbox`.

      authorize(mailbox, user_uuid, "write")
  """
  @spec authorize(Mailbox.t(), binary(), access()) :: :ok | {:error, :mailbox_access_denied}
  def authorize(%Mailbox{} = mailbox, user_uuid, required) do
    if MailboxGrant.covers?(access_level(mailbox, user_uuid), required) do
      :ok
    else
      {:error, :mailbox_access_denied}
    end
  end

  # ── counts ──────────────────────────────────────────────────────────────────

  @doc """
  Unseen message count per folder for a mailbox, as `%{folder => count}`.

  Folders with nothing unseen are absent from the map — callers use
  `Map.get(counts, folder, 0)`.
  """
  @spec unseen_counts(binary()) :: %{String.t() => non_neg_integer()}
  def unseen_counts(mailbox_uuid) when is_binary(mailbox_uuid) do
    from(d in Delivery,
      where: d.mailbox_uuid == ^mailbox_uuid,
      where: d.status == "active",
      where: is_nil(d.seen_at),
      group_by: d.folder,
      select: {d.folder, count(d.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  def unseen_counts(_), do: %{}

  # ── helpers ─────────────────────────────────────────────────────────────────

  # Forms hand us string keys, tests and internal callers hand us atoms.
  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp put_default_slug(%{"slug" => slug} = attrs) when is_binary(slug) and slug != "", do: attrs

  defp put_default_slug(%{"name" => name} = attrs) when is_binary(name) do
    Map.put(attrs, "slug", name)
  end

  defp put_default_slug(attrs), do: attrs
end
