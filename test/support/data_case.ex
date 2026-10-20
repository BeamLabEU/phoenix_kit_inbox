defmodule PhoenixKitInbox.DataCase do
  @moduledoc """
  Test case for tests requiring database access.

  Uses PhoenixKitInbox.Test.Repo with SQL Sandbox for isolation.
  Tests using this case are tagged `:integration` and will be
  automatically excluded when the database is unavailable.

  ## Usage

      defmodule MyModule.Integration.SomeTest do
        use PhoenixKitInbox.DataCase, async: true

        test "creates a record" do
          # Repo is available, transactions are isolated
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitInbox.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitInbox.ActivityLogAssertions
      import PhoenixKitInbox.DataCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitInbox.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end

  @doc """
  Inserts a real `phoenix_kit_users` row.

  Inbox's tables carry foreign keys to `phoenix_kit_users`, so a fabricated
  uuid fails on insert — every mailbox needs an owner that actually exists.
  Inserted through the schema (rather than raw SQL) so the row matches whatever
  core's current columns are.
  """
  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      email: "inbox-test-#{n}@example.com",
      username: "inbox_test_#{n}",
      first_name: "Test",
      last_name: "User #{n}",
      hashed_password: "$2b$12$notarealhashjustenoughtosatisfythecolumn",
      is_active: true
    }

    TestRepo.insert!(struct(PhoenixKit.Users.Auth.User, Map.merge(defaults, attrs)))
  end

  @doc """
  A real `PhoenixKit.Users.Auth.Scope` for `user` holding exactly
  `permissions` — what the context functions that take a scope check with
  `Scope.can?/2`. Pair with `enable_inbox!/0`: `can?/2` also requires the
  module to be enabled.
  """
  def scope_for(user, permissions \\ ["inbox"]) do
    %PhoenixKit.Users.Auth.Scope{
      user: user,
      authenticated?: true,
      cached_roles: [],
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc "Enables the module, which `Scope.can?/2` requires for every inbox key."
  def enable_inbox! do
    PhoenixKitInbox.enable_system()
    true = PhoenixKitInbox.enabled?()
    :ok
  end

  @doc """
  Inserts a shared mailbox owned by `owner` directly, bypassing the
  `inbox.manage_shared` check of `Mailboxes.create_shared_mailbox/2` — for
  tests about something else. Tests about creation go through the context.
  """
  def shared_mailbox_fixture(owner, attrs \\ %{}) do
    name = Map.get(attrs, :name, "Shared #{System.unique_integer([:positive])}")

    attrs =
      attrs
      |> Map.put(:name, name)
      |> Map.put_new(:slug, name)
      |> Map.merge(%{kind: "shared", owner_uuid: owner.uuid})

    %PhoenixKitInbox.Schemas.Mailbox{}
    |> PhoenixKitInbox.Schemas.Mailbox.changeset(attrs)
    |> TestRepo.insert!()
  end

  @doc """
  Translates changeset errors into a `%{field => [message]}` map. Used
  by tests that assert on changeset error messages.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
