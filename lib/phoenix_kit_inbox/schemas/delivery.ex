defmodule PhoenixKitInbox.Schemas.Delivery do
  @moduledoc """
  One mailbox's copy of a message — the row the mailbox UI actually lists.

  Every folder view is a query over this table (`mailbox_uuid` + `folder`,
  ordered by `inserted_at`), which is why the migration puts a compound index
  there. All per-recipient state lives here rather than on the message:

    * `folder` — which of the six fixed folders the copy sits in
    * `role` — `"from"` for the sender's own copy, `"to"`/`"cc"`/`"bcc"` for
      recipients. Drives the recipient chips in the reading pane.
    * `seen_at` — nil means unseen (the bold rows and the "Unseen" filter)
    * `starred` — the star toggle in the list
    * `status` — `"deleted"` is the hard-delete tombstone; ordinary deleting
      moves the row to the `"trash"` folder instead

  ## Folders

  Fixed set, matching the reference webmail: inbox, sent, drafts, spam, trash,
  archive. Deliberately a column and not a table for 0.1.0 — user-defined
  folders/labels would be a `phoenix_kit_inbox_labels` table plus a join, and
  that is a v2 migration, not a v1 guess.

  Tables are created by `PhoenixKitInbox.Migrations`, never by this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @folders ~w(inbox sent drafts spam trash archive)
  @roles ~w(from to cc bcc)
  @statuses ~w(active deleted)

  @type t :: %__MODULE__{}

  schema "phoenix_kit_inbox_deliveries" do
    field(:message_uuid, UUIDv7)
    field(:mailbox_uuid, UUIDv7)
    field(:role, :string, default: "to")
    field(:folder, :string, default: "inbox")
    field(:seen_at, :utc_datetime)
    field(:starred, :boolean, default: false)
    field(:status, :string, default: "active")

    timestamps(type: :utc_datetime)
  end

  @doc "The six fixed folders, in sidebar order."
  @spec folders() :: [String.t()]
  def folders, do: @folders

  @doc "Valid recipient roles."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc "Valid values for the `status` column."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc false
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:message_uuid, :mailbox_uuid, :role, :folder, :seen_at, :starred, :status])
    |> validate_required([:message_uuid, :mailbox_uuid, :role, :folder])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:folder, @folders)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:message_uuid, :mailbox_uuid, :role],
      name: :phoenix_kit_inbox_deliveries_message_mailbox_role_index
    )
  end
end
