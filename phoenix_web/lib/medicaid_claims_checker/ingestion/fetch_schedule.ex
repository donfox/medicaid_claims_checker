defmodule MedicaidClaimsChecker.Ingestion.FetchSchedule do
  use Ecto.Schema
  import Ecto.Changeset

  schema "fetch_schedules" do
    field(:cron_expression, :string)
    field(:interval_seconds, :integer)
    field(:enabled, :boolean, default: true)

    belongs_to(:fetch_source, MedicaidClaimsChecker.Ingestion.FetchSource)

    timestamps(type: :utc_datetime)
  end

  def changeset(fetch_schedule, attrs) do
    fetch_schedule
    |> cast(attrs, [:fetch_source_id, :cron_expression, :interval_seconds, :enabled])
    |> validate_required([:fetch_source_id])
    |> validate_schedule_present()
    |> validate_cron_expression()
    |> validate_interval()
    |> foreign_key_constraint(:fetch_source_id)
  end

  # Checked with the parser the scheduler uses, so a schedule that saves is
  # one the scheduler can run.
  defp validate_cron_expression(changeset) do
    case get_field(changeset, :cron_expression) do
      nil ->
        changeset

      cron ->
        cond do
          length(String.split(cron)) != 5 ->
            add_error(
              changeset,
              :cron_expression,
              "must have exactly 5 fields (min hour day month weekday)"
            )

          match?({:error, _}, Crontab.CronExpression.Parser.parse(cron)) ->
            {:error, reason} = Crontab.CronExpression.Parser.parse(cron)
            add_error(changeset, :cron_expression, "is not valid: #{reason}")

          true ->
            changeset
        end
    end
  end

  @doc """
  The cron expression that runs every `seconds`, or `:error` when no cron
  expression can: the interval must be whole minutes that divide an hour
  (1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30 minutes) or whole hours that divide
  a day (1, 2, 3, 4, 6, 8, 12, 24 hours).
  """
  def interval_cron(seconds) when is_integer(seconds) and seconds > 0 and rem(seconds, 60) == 0 do
    minutes = div(seconds, 60)
    hours = div(minutes, 60)

    cond do
      minutes < 60 and rem(60, minutes) == 0 -> {:ok, "*/#{minutes} * * * *"}
      minutes == 60 -> {:ok, "0 * * * *"}
      rem(minutes, 60) == 0 and hours == 24 -> {:ok, "0 0 * * *"}
      rem(minutes, 60) == 0 and hours < 24 and rem(24, hours) == 0 -> {:ok, "0 */#{hours} * * *"}
      true -> :error
    end
  end

  def interval_cron(_seconds), do: :error

  defp validate_interval(changeset) do
    case get_field(changeset, :interval_seconds) do
      nil ->
        changeset

      seconds ->
        case interval_cron(seconds) do
          {:ok, _} ->
            changeset

          :error ->
            add_error(
              changeset,
              :interval_seconds,
              "must be minutes that divide an hour (60, 120, 300, 600, 900, 1800 seconds, ...) " <>
                "or hours that divide a day (3600, 7200, 21600, 43200, 86400 seconds, ...)"
            )
        end
    end
  end

  defp validate_schedule_present(changeset) do
    cron = get_field(changeset, :cron_expression)
    interval = get_field(changeset, :interval_seconds)

    cond do
      is_nil(cron) and is_nil(interval) ->
        add_error(changeset, :cron_expression, "either cron expression or interval is required")

      not is_nil(cron) and not is_nil(interval) ->
        add_error(
          changeset,
          :cron_expression,
          "provide either cron expression or interval, not both"
        )

      true ->
        changeset
    end
  end
end
