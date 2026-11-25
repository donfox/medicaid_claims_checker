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

  # A trailing "/" is allowed in RULE_ENGINE_URL; drop it so paths join cleanly.
  defp url do
    Application.get_env(:medicaid_claims_checker, :rule_engine_url, "http://localhost:8080")
    |> String.trim_trailing("/")
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
  network address without TLS.

  The URL must be only a scheme, host and optional port (a trailing `/` is
  allowed). A username or password, a path, a query string or a fragment is
  refused: none has a use here, and each suggests a mistaken or tampered
  value. Error messages never repeat the URL's username or password.

  This check cannot tell a wrong `https://` host from the right one. What
  stops claims going to a wrong host is `RULE_ENGINE_CA_CERT`: with it set,
  only certificates signed by that CA are accepted (see
  docs/CONFIGURATION.md). Returns `:ok` or `{:error, message}`.
  """
  def check_url(url) when is_binary(url) do
    uri = URI.parse(url)

    uri = %{
      uri
      | scheme: uri.scheme && String.downcase(uri.scheme),
        host: uri.host && String.downcase(uri.host)
    }

    shown = "RULE_ENGINE_URL=#{display(uri, url)}"

    cond do
      uri.scheme not in ["http", "https"] or not is_binary(uri.host) or uri.host == "" ->
        {:error, "#{shown} is not an http:// or https:// URL"}

      uri.userinfo != nil ->
        {:error, "#{shown} contains a username or password; the engine uses RULE_ENGINE_SECRET"}

      uri.path not in [nil, "", "/"] or uri.query != nil or uri.fragment != nil ->
        {:error,
         "#{shown} has a path, query or fragment; give only the scheme, host and port"}

      uri.scheme == "http" and uri.host not in ["localhost", "127.0.0.1", "::1"] ->
        {:error,
         "#{shown} uses plain http:// to a host that is not loopback; " <>
           "serve the engine over TLS and use https://"}

      true ->
        :ok
    end
  end

  # The URL as it may appear in a log or error: without a username or
  # password, which could be a secret.
  defp display(%URI{userinfo: nil}, url), do: url
  defp display(uri, _url), do: URI.to_string(%{uri | userinfo: "***"})

  @doc """
  One line describing where claims are sent, for the startup log: the
  engine's scheme, host and port, and whether its certificate must come
  from the CA in `RULE_ENGINE_CA_CERT`. The arguments default to the
  configured values.
  """
  def describe_target(
        url \\ url(),
        ca_file \\ Application.get_env(:medicaid_claims_checker, :rule_engine_ca_cert)
      ) do
    uri = URI.parse(url)
    uri = %{uri | scheme: uri.scheme && String.downcase(uri.scheme)}

    tls =
      case {uri.scheme, ca_file} do
        {"http", _} -> "plain HTTP, loopback only"
        {_, nil} -> "TLS, any publicly trusted certificate accepted (RULE_ENGINE_CA_CERT unset)"
        {_, ca_file} -> "TLS, certificate must be signed by the CA in #{ca_file}"
      end

    host = if String.contains?(uri.host || "", ":"), do: "[#{uri.host}]", else: uri.host
    "Rule engine: #{uri.scheme}://#{host}:#{uri.port} (#{tls})"
  end

  @doc false
  def connect_options(timeout) do
    case Application.get_env(:medicaid_claims_checker, :rule_engine_ca_cert) do
      nil -> [timeout: timeout]
      ca_file -> [timeout: timeout, transport_opts: [cacertfile: ca_file]]
    end
  end
end
