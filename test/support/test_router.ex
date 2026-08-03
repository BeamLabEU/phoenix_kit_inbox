defmodule PhoenixKitInbox.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitInbox.Paths` so `live/2` calls in tests
  work with exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  `phoenix_kit_settings` table is unavailable, and admin paths always
  get the default locale ("en") prefix — so our base becomes
  `/en/admin/inbox`.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitInbox.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/en/admin/inbox", PhoenixKitInbox.Web do
    pipe_through(:browser)

    live_session :inbox_test,
      layout: {PhoenixKitInbox.Test.Layouts, :app},
      on_mount: {PhoenixKitInbox.Test.Hooks, :assign_scope} do
      live("/", InboxLive, :index)
      live("/compose", ComposeLive, :new)
      live("/mailboxes", MailboxesLive, :index)
    end
  end
end
