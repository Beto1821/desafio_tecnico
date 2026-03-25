defmodule WCore.Telemetry.NodeMetric do
  use Ecto.Schema
  import Ecto.Changeset

  schema "node_metrics" do
    field :status, :string, default: "unknown"
    field :total_events_processed, :integer, default: 0
    field :last_payload, :map
    field :last_seen_at, :naive_datetime
    
    belongs_to :node, WCore.Telemetry.Node

    timestamps()
  end

  def changeset(metric, attrs) do
    metric
    |> cast(attrs, [:status, :total_events_processed, :last_payload, :last_seen_at, :node_id])
    |> validate_required([:status, :last_seen_at, :node_id])
    |> unique_constraint(:node_id)
  end
end