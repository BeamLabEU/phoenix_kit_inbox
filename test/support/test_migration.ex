defmodule PhoenixKitInbox.Test.Migration do
  @moduledoc """
  Wraps this module's versioned migration coordinator so `Ecto.Migrator` can
  run it against the test database.

  In production a host runs `mix phoenix_kit.update`, which generates a
  migration whose `up/0` calls `PhoenixKitInbox.Migrations.up/1`. This module
  is that generated migration, checked in for the test suite — so tests
  exercise exactly the DDL a real install gets, rather than a hand-maintained
  copy that could drift.
  """

  use Ecto.Migration

  def up, do: PhoenixKitInbox.Migrations.up()

  def down, do: PhoenixKitInbox.Migrations.down()
end
