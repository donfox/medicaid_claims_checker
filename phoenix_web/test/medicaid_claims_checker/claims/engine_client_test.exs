defmodule MedicaidClaimsChecker.Claims.EngineClientTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Claims.EngineClient

  describe "check_url/1" do
    test "allows plain http to a loopback host" do
      assert EngineClient.check_url("http://localhost:8080") == :ok
      assert EngineClient.check_url("http://127.0.0.1:8092") == :ok
      assert EngineClient.check_url("http://[::1]:8080") == :ok
      assert EngineClient.check_url("HTTP://LocalHost:8080") == :ok
    end

    test "allows https to any host" do
      assert EngineClient.check_url("https://engine.internal:8443") == :ok
      assert EngineClient.check_url("https://localhost:8080") == :ok
    end

    test "refuses plain http to a host that is not loopback" do
      assert {:error, message} = EngineClient.check_url("http://engine.internal:8080")
      assert message =~ "https://"
      assert {:error, _} = EngineClient.check_url("http://10.0.0.5:8080")
      assert {:error, _} = EngineClient.check_url("http://0.0.0.0:8080")
    end

    test "refuses a URL that is not http or https" do
      assert {:error, _} = EngineClient.check_url("engine:8080")
      assert {:error, _} = EngineClient.check_url("ftp://engine.internal")
      assert {:error, _} = EngineClient.check_url("https://")
    end

    test "allows a trailing slash" do
      assert EngineClient.check_url("https://engine.internal:8443/") == :ok
      assert EngineClient.check_url("http://localhost:8080/") == :ok
    end

    test "refuses a username or password without repeating it" do
      assert {:error, message} =
               EngineClient.check_url("https://admin:hunter2@engine.internal:8443")

      assert message =~ "username or password"
      refute message =~ "hunter2"
      refute message =~ "admin"
      assert message =~ "engine.internal"
    end

    test "refuses a path, query or fragment" do
      for url <- [
            "https://engine.internal:8443/api",
            "https://engine.internal:8443/?next=https://elsewhere.example",
            "https://engine.internal:8443#x",
            "http://localhost:8080/proxy/elsewhere"
          ] do
        assert {:error, message} = EngineClient.check_url(url)
        assert message =~ "path, query or fragment"
      end
    end
  end

  describe "describe_target/2" do
    test "names the host and port and says whether a CA is pinned" do
      line = EngineClient.describe_target("https://engine.internal/", nil)
      assert line =~ "https://engine.internal:443"
      assert line =~ "RULE_ENGINE_CA_CERT unset"

      assert EngineClient.describe_target("https://engine.internal:8443", "/etc/engine-ca.pem") =~
               "engine.internal:8443 (TLS, certificate must be signed by the CA in /etc/engine-ca.pem)"

      assert EngineClient.describe_target("http://[::1]:8080", nil) =~
               "http://[::1]:8080 (plain HTTP, loopback only)"

      assert EngineClient.describe_target("HTTP://LocalHost:8080", nil) =~ "(plain HTTP, loopback only)"
    end
  end
end
