defmodule WCoreWeb.UserSessionHTML do
  use WCoreWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:w_core, WCore.Mailer)[:adapter] == Swoosh.Adapters.Local
  end

  defp smtp_mail_adapter? do
    Application.get_env(:w_core, WCore.Mailer)[:adapter] == Swoosh.Adapters.SMTP
  end

  defp mailpit_url do
    host = Application.get_env(:w_core, WCoreWeb.Endpoint)[:url][:host] || "localhost"
    "http://#{host}:8025"
  end
end
