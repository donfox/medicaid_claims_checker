defmodule MedicaidClaimsChecker.Claims.EngineClient do
  @moduledoc """
  HTTP calls to the Haskell rule engine.

  The engine URL comes from `RULE_ENGINE_URL` (default `http://localhost:8080`).
  When the engine runs on another host it serves HTTPS; if its certificate is
  self-signed or from an internal CA, point `RULE_ENGINE_CA_CERT` at the CA
  file so the connection is verified against it.
  """

  @doc """
  POSTs a JSON `body` (already encoded) to the engine `path`.

  Options: `:connect_timeout` and `:receive_timeout` in milliseconds.
  Returns whatever `Req.post/2` returns; the response body is left undecoded.
  """
  def post(path, body, opts) do
    Req.post(url() <> path,
      body: body,
      headers: headers(),
      decode_body: false,
      connect_options: connect_options(Keyword.fetch!(opts, :connect_timeout)),
      receive_timeout: Keyword.fetch!(opts, :receive_timeout)
    )
  end

  defp url do
    Application.get_env(:medicaid_claims_checker, :rule_engine_url, "http://localhost:8080")
  end

  defp headers do
    secret = Application.get_env(:medicaid_claims_checker, :rule_engine_secret, "")
    [{"Content-Type", "application/json"}, {"Authorization", "Bearer #{secret}"}]
  end

  @doc """
  Checks an engine URL before the app starts.

  Plain `http://` is allowed only for a loopback host (`localhost`,
  `127.0.0.1`, `::1`), so claim data and the shared secret never cross a
  network unencrypted. This matches the engine, which will not listen on a
  network address without TLS. Returns `:ok` or `{:error, message}`.
  """
  def check_url(url) when is_binary(url) do
    uri = URI.parse(url)

    case %{
      uri
      | scheme: uri.scheme && String.downcase(uri.scheme),
        host: uri.host && String.downcase(uri.host)
    } do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        :ok

      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1", "::1"] ->
        :ok

      %URI{scheme: "http", host: host} when is_binary(host) and host != "" ->
        {:error,
         "RULE_ENGINE_URL=#{url} uses plain http:// to a host that is not loopback; " <>
           "serve the engine over TLS and use https://"}

      _ ->
        {:error, "RULE_ENGINE_URL=#{url} is not an http:// or https:// URL"}
    end
  end

  @doc false
  def connect_options(timeout) do
    case Application.get_env(:medicaid_claims_checker, :rule_engine_ca_cert) do
      nil -> [timeout: timeout]
      ca_file -> [timeout: timeout, transport_opts: [cacertfile: ca_file]]
    end
  end
end
