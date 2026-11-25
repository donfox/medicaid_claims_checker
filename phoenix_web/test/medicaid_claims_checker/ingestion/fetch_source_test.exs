defmodule MedicaidClaimsChecker.Ingestion.FetchSourceTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Ingestion.FetchSource

  defp changeset(uri) do
    FetchSource.changeset(%FetchSource{}, %{name: "s", uri: uri, source_type: "sftp"})
  end

  test "a password in the URI is refused" do
    cs = changeset("sftp://fetcher:s3cret@sftp.example.com/inbox")
    refute cs.valid?
    assert {"must not contain a password; enter it in the Password field", _} = cs.errors[:uri]

    refute changeset("sftp://fetcher:@sftp.example.com/inbox").valid?
  end

  test "a user name alone, or no user, is accepted" do
    assert changeset("sftp://fetcher@sftp.example.com/inbox").valid?
    assert changeset("sftp://sftp.example.com:2222/inbox").valid?
    assert changeset("/var/claims/inbox/").valid?
  end
end
