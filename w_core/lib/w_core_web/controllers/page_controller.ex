defmodule WCoreWeb.PageController do
  use WCoreWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
