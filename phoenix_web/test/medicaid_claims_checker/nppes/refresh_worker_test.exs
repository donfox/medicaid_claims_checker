defmodule MedicaidClaimsChecker.Nppes.RefreshWorkerTest do
  use MedicaidClaimsChecker.DataCase, async: true

  import ExUnit.CaptureLog

  alias MedicaidClaimsChecker.Nppes.{RefreshConfig, RefreshWorker}
  alias MedicaidClaimsChecker.Repo

  defp set_config(attrs),
    do: RefreshConfig.get_or_create() |> RefreshConfig.changeset(attrs) |> Repo.update!()

  test "a refresh still marked running at start-up was cut off and is recorded as failed" do
    set_config(%{last_status: "running", last_error: nil})

    log = capture_log(fn -> RefreshWorker.recover_interrupted() end)

    config = RefreshConfig.get_or_create()
    assert config.last_status == "failed"
    assert config.last_error =~ "The app stopped during this refresh"
    assert log =~ "the last refresh did not finish"
  end

  test "any other status is left as it is" do
    set_config(%{last_status: "completed"})
    RefreshWorker.recover_interrupted()
    assert RefreshConfig.get_or_create().last_status == "completed"
  end

  test "after a failed refresh the next try is in 6 hours, not a whole interval" do
    set_config(%{interval_seconds: 2_592_000, last_status: "running"})
    ref = make_ref()

    state = %{
      refreshing: true,
      task_ref: ref,
      task_pid: nil,
      timer_ref: nil,
      started_at: nil,
      tmp_dir: nil,
      previous_status: nil
    }

    {{:noreply, new_state}, _log} =
      with_log(fn -> RefreshWorker.handle_info({ref, {:error, "CMS unreachable"}}, state) end)

    remaining_ms = Process.read_timer(new_state.timer_ref)
    Process.cancel_timer(new_state.timer_ref)

    assert_in_delta remaining_ms, 6 * 3600 * 1000, 5_000
    assert RefreshConfig.get_or_create().last_status == "failed"
  end
end
