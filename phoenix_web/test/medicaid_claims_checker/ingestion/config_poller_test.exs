defmodule MedicaidClaimsChecker.Ingestion.ConfigPollerTest do
  # Async so the sandbox is not in shared mode (where every process would use
  # this test's connection). Tests in one module still run one at a time, so
  # the named poller never clashes; it only edits fetch_ Scheduler jobs, which
  # no other test creates.
  use MedicaidClaimsChecker.DataCase, async: true

  import ExUnit.CaptureLog

  alias MedicaidClaimsChecker.Ingestion.ConfigPoller
  alias MedicaidClaimsChecker.Repo

  # Started with plain start_link (not start_supervised, which would share
  # this test's sandbox), so the poller has no database access until allowed,
  # as at application boot. Linked: a crash would fail the test.
  defp start_poller do
    {:ok, pid} = ConfigPoller.start_link([])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  test "a poll that cannot reach the database is logged and the poller keeps running" do
    log =
      capture_log(fn ->
        pid = start_poller()
        send(pid, :poll)
        assert %{last_config: nil} = :sys.get_state(pid)
        assert Process.alive?(pid)
      end)

    assert log =~ "Ingestion config poll failed, keeping current jobs"
  end

  test "once the database is reachable the next poll reads the config" do
    {pid, _log} = with_log(&start_poller/0)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

    send(pid, :poll)
    assert %{last_config: []} = :sys.get_state(pid)
  end
end
