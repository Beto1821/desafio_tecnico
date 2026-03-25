defmodule WCore.Repo.Migrations.CreateTelemetryTables do
  use Ecto.Migration

  def change do
    # Tabela de registro estático dos sensores
    create table(:nodes) do
      add :machine_identifier, :string, null: false
      add :location, :string, null: false

      timestamps()
    end

    create unique_index(:nodes, [:machine_identifier])

    # Tabela de estado consolidado (1 linha por sensor)
    create table(:node_metrics) do
      add :node_id, references(:nodes, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "unknown"
      add :total_events_processed, :integer, null: false, default: 0
      add :last_payload, :map # SQLite armazena como JSON automaticamente
      add :last_seen_at, :naive_datetime, null: false

      timestamps()
    end

    create unique_index(:node_metrics, [:node_id])
    create index(:node_metrics, [:status])
  end
end