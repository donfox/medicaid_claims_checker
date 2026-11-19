defmodule MedicaidClaimsChecker.Ingestion.FetchScheduleTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Ingestion.FetchSchedule

  defp errors(attrs) do
    %FetchSchedule{}
    |> FetchSchedule.changeset(Map.put(attrs, :fetch_source_id, 1))
    |> Map.fetch!(:errors)
    |> Keyword.keys()
  end

  test "a cron expression is checked by the scheduler's own parser" do
    assert errors(%{cron_expression: "0 */6 * * *"}) == []
    assert errors(%{cron_expression: "99 * * * *"}) == [:cron_expression]
    assert errors(%{cron_expression: "a b c d e"}) == [:cron_expression]
    assert errors(%{cron_expression: "* * *"}) == [:cron_expression]
  end

  test "only intervals a schedule can run exactly are accepted" do
    for ok <- [60, 300, 900, 1800, 3600, 7200, 21_600, 43_200, 86_400] do
      assert errors(%{interval_seconds: ok}) == [], "#{ok} should be accepted"
    end

    for bad <- [30, 90, 2000, 2400, 5400, 18_000, 172_800] do
      assert errors(%{interval_seconds: bad}) == [:interval_seconds], "#{bad} should be refused"
    end
  end

  test "interval_cron gives the cron expression for an interval" do
    assert FetchSchedule.interval_cron(300) == {:ok, "*/5 * * * *"}
    assert FetchSchedule.interval_cron(3600) == {:ok, "0 * * * *"}
    assert FetchSchedule.interval_cron(21_600) == {:ok, "0 */6 * * *"}
    assert FetchSchedule.interval_cron(86_400) == {:ok, "0 0 * * *"}
    assert FetchSchedule.interval_cron(5400) == :error
  end
end
