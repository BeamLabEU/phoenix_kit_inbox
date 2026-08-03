defmodule PhoenixKitInbox.Migrations.V01 do
  @moduledoc """
  V01 — the four Inbox tables.

  Immutable once shipped. A schema change is V02, never an edit here: hosts
  that already ran V01 will never run it again, so an edit only ever applies
  to fresh installs and silently splits the world in two.

  Prefix-safe per core's rules (`phoenix_kit/AGENTS.md`, "Prefix-safe
  migrations"): index names stay **bare** on `CREATE`, `uuid_generate_v7()` is
  schema-qualified through `Helpers.uuid_v7_call/1`, and every FK targets the
  same `prefix`.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @doc false
  def up(%{prefix: prefix} = _opts) do
    Helpers.ensure_uuid_v7_function(prefix)

    create_mailboxes(prefix)
    create_mailbox_grants(prefix)
    create_messages(prefix)
    create_deliveries(prefix)
  end

  @doc false
  def down(%{prefix: prefix} = _opts) do
    # Reverse creation order — deliveries reference messages and mailboxes.
    drop_if_exists(table(:phoenix_kit_inbox_deliveries, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_inbox_messages, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_inbox_mailbox_grants, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_inbox_mailboxes, prefix: prefix))
  end

  # ── mailboxes ───────────────────────────────────────────────────────────────

  defp create_mailboxes(prefix) do
    create_if_not_exists table(:phoenix_kit_inbox_mailboxes,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid,
        primary_key: true,
        null: false,
        default: fragment(Helpers.uuid_v7_call(prefix))
      )

      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:address, :string)
      add(:kind, :string, null: false, default: "user")
      add(:status, :string, null: false, default: "active")

      add(
        :owner_uuid,
        references(:phoenix_kit_users,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(:settings, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(unique_index(:phoenix_kit_inbox_mailboxes, [:slug], prefix: prefix))

    # One personal mailbox per user. Shared mailboxes are excluded from the
    # constraint — a user may create any number of those.
    create_if_not_exists(
      unique_index(:phoenix_kit_inbox_mailboxes, [:owner_uuid],
        name: :phoenix_kit_inbox_mailboxes_user_owner_index,
        where: "kind = 'user'",
        prefix: prefix
      )
    )

    create_if_not_exists(index(:phoenix_kit_inbox_mailboxes, [:kind, :status], prefix: prefix))
  end

  # ── grants ──────────────────────────────────────────────────────────────────

  defp create_mailbox_grants(prefix) do
    create_if_not_exists table(:phoenix_kit_inbox_mailbox_grants,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid,
        primary_key: true,
        null: false,
        default: fragment(Helpers.uuid_v7_call(prefix))
      )

      add(
        :mailbox_uuid,
        references(:phoenix_kit_inbox_mailboxes,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :user_uuid,
        references(:phoenix_kit_users,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(:access, :string, null: false, default: "read")

      add(
        :granted_by_uuid,
        references(:phoenix_kit_users,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(
      unique_index(:phoenix_kit_inbox_mailbox_grants, [:mailbox_uuid, :user_uuid],
        name: :phoenix_kit_inbox_mailbox_grants_mailbox_user_index,
        prefix: prefix
      )
    )

    # "Which mailboxes can this user open?" — the query the sidebar runs on
    # every mount.
    create_if_not_exists(index(:phoenix_kit_inbox_mailbox_grants, [:user_uuid], prefix: prefix))
  end

  # ── messages ────────────────────────────────────────────────────────────────

  defp create_messages(prefix) do
    create_if_not_exists table(:phoenix_kit_inbox_messages,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid,
        primary_key: true,
        null: false,
        default: fragment(Helpers.uuid_v7_call(prefix))
      )

      # Not a FK: the root message of a thread carries its own uuid here, and a
      # self-referencing FK would have to be added after insert. The value is
      # always written by PhoenixKitInbox.Messages, never by a user.
      add(:thread_uuid, :uuid, null: false)

      add(
        :parent_uuid,
        references(:phoenix_kit_inbox_messages,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add(
        :sender_mailbox_uuid,
        references(:phoenix_kit_inbox_mailboxes,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :sender_user_uuid,
        references(:phoenix_kit_users,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add(:subject, :string, size: 500)
      add(:body, :text)
      add(:body_format, :string, null: false, default: "text")
      add(:status, :string, null: false, default: "draft")
      add(:sent_at, :utc_datetime)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_inbox_messages, [:thread_uuid], prefix: prefix))

    create_if_not_exists(
      index(:phoenix_kit_inbox_messages, [:sender_mailbox_uuid, :status], prefix: prefix)
    )
  end

  # ── deliveries ──────────────────────────────────────────────────────────────

  defp create_deliveries(prefix) do
    create_if_not_exists table(:phoenix_kit_inbox_deliveries,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid,
        primary_key: true,
        null: false,
        default: fragment(Helpers.uuid_v7_call(prefix))
      )

      add(
        :message_uuid,
        references(:phoenix_kit_inbox_messages,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :mailbox_uuid,
        references(:phoenix_kit_inbox_mailboxes,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(:role, :string, null: false, default: "to")
      add(:folder, :string, null: false, default: "inbox")
      add(:seen_at, :utc_datetime)
      add(:starred, :boolean, null: false, default: false)
      add(:status, :string, null: false, default: "active")

      timestamps(type: :utc_datetime)
    end

    # The folder listing query: mailbox + folder, newest first.
    create_if_not_exists(
      index(:phoenix_kit_inbox_deliveries, [:mailbox_uuid, :folder, :inserted_at], prefix: prefix)
    )

    # Unseen counts for the sidebar badges.
    create_if_not_exists(
      index(:phoenix_kit_inbox_deliveries, [:mailbox_uuid, :seen_at],
        where: "seen_at IS NULL",
        name: :phoenix_kit_inbox_deliveries_unseen_index,
        prefix: prefix
      )
    )

    create_if_not_exists(index(:phoenix_kit_inbox_deliveries, [:message_uuid], prefix: prefix))

    # A mailbox gets at most one copy per message per role — makes the send
    # fan-out idempotent under retry.
    create_if_not_exists(
      unique_index(:phoenix_kit_inbox_deliveries, [:message_uuid, :mailbox_uuid, :role],
        name: :phoenix_kit_inbox_deliveries_message_mailbox_role_index,
        prefix: prefix
      )
    )
  end
end
