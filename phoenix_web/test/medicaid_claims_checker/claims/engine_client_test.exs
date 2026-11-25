defmodule MedicaidClaimsChecker.Claims.EngineClientTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Claims.EngineClient

  describe "check_url/1" do
    test "allows plain http to a loopback host" do
      assert EngineClient.check_url("http://localhost:8080") == :ok
      assert EngineClient.check_url("http://127.0.0.1:8092") == :ok
      assert EngineClient.check_url("http://[::1]:8080") == :ok
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
  end
end
