defmodule WCoreWeb.PageController do
  use WCoreWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_scope] do
      redirect(conn, to: ~p"/telemetry")
    else
      redirect(conn, to: ~p"/users/log-in")
    end
  end
end
