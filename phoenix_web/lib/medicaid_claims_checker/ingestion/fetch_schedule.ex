defmodule MedicaidClaimsChecker.Ingestion.FetchSchedule do
  use Ecto.Schema
  import Ecto.Changeset

  schema "fetch_schedules" do
    field :cron_expression, :string
    field :interval_seconds, :integer
    field :enabled, :boolean, default: true

    belongs_to :fetch_source, MedicaidClaimsChecker.Ingestion.FetchSource

    timestamps(type: :utc_datetime)
  end

  def changeset(fetch_schedule, attrs) do
    fetch_schedule
    |> cast(attrs, [:fetch_source_id, :cron_expression, :interval_seconds, :enabled])
    |> validate_required([:fetch_source_id])
    |> validate_schedule_present()
    |> validate_number(:interval_seconds, greater_than_or_equal_to: 60)
    |> foreign_key_constraint(:fetch_source_id)
  end

  defp validate_schedule_present(changeset) do
    cron = get_field(changeset, :cron_expression)
    interval = get_field(changeset, :interval_seconds)

    cond do
      is_nil(cron) and is_nil(interval) ->
        add_error(changeset, :cron_expression, "either cron expression or interval is required")

      not is_nil(cron) and not is_nil(interval) ->
        add_error(changeset, :cron_expression, "provide either cron expression or interval, not both")

      true ->
        changeset
    end
  end
end
