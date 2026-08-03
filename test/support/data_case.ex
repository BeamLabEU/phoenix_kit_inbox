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
