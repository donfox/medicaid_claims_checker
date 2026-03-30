defmodule MedicaidClaimsCheckerWeb.FetchConfigJSON do
  alias MedicaidClaimsChecker.Ingestion.{FetchSource, FetchSchedule}

  def index(%{sources: sources}) do
    %{
      fetch_sources: Enum.map(sources, &source_json/1),
      generated_at: DateTime.utc_now()
    }
  end

  defp source_json(%FetchSource{} = source) do
    %{
      id: source.id,
      name: source.name,
      uri: source.uri,
      source_type: source.source_type,
      credentials: source.credentials,
      schedules: Enum.map(source.fetch_schedules, &schedule_json/1)
    }
  end

  defp schedule_json(%FetchSchedule{} = schedule) do
    %{
      id: schedule.id,
      cron_expression: schedule.cron_expression,
      interval_seconds: schedule.interval_seconds
    }
  end
end
