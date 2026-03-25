defmodule WCore.Repo do
  use Ecto.Repo,
    otp_app: :w_core,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    # Configurações para Alta Performance em SQLite
    config = Keyword.merge(config, [
      journal_mode: :wal,
      cache_size: -64_000, # 64MB de cache
      temp_store: :memory,
      pool_size: 5 # SQLite lida melhor com pools pequenos
    ])
    {:ok, config}
  end
end