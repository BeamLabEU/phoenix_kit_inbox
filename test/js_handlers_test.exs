defmodule PhoenixKitInbox.JsHandlersTest do
  @moduledoc """
  Runs the tests of `priv/static/assets/phoenix_kit_inbox.js`
  (`test/js/*.cjs`, `node --test`) as part of `mix test`. The file is
  hand-written and ships as it is. Skipped where node is not installed.
  """
  use ExUnit.Case, async: true

  @node System.find_executable("node")
  @root Path.expand("..", __DIR__)
  @tests Path.wildcard(Path.join(@root, "test/js/*.cjs"))

  @tag skip: if(@node, do: false, else: "node is not installed")
  test "the JS tests pass" do
    refute Enum.empty?(@tests), "no test/js/*.cjs files found"

    {output, status} =
      System.cmd(@node, ["--test" | @tests], cd: @root, stderr_to_stdout: true)

    assert status == 0, output
  end

  test "js_sources/0 declares the bundle, and the file ships in priv/" do
    assert [%{app: :phoenix_kit_inbox, file: file, global: "PhoenixKitInboxHooks"}] =
             PhoenixKitInbox.js_sources()

    source = File.read!(Path.join([@root, "priv", file]))
    assert source =~ "window.PhoenixKitInboxHooks"
  end
end
