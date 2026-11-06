defmodule MedicaidClaimsChecker.Nppes.LatestFile do
  @moduledoc """
  Finds the newest monthly NPPES file on CMS's download page.

  CMS publishes one full replacement file a month, named like
  `NPPES_Data_Dissemination_November_2026_V2.zip`, and removes the old ones
  from https://download.cms.gov/nppes/NPI_Files.html. A saved URL for a
  monthly file therefore stops working within weeks. Before each refresh,
  `resolve/2` replaces such a URL with the newest one listed. Any other URL
  (a mirror, a weekly update file, a local test server) is used as entered.
  """

  require Logger

  @index_url "https://download.cms.gov/nppes/NPI_Files.html"
  @base_url "https://download.cms.gov/nppes/"

  @months ~w(January February March April May June July August September October November December)

  # A monthly file anywhere in an href, e.g. "./NPPES_Data_Dissemination_November_2026_V2.zip".
  @monthly_file ~r/NPPES_Data_Dissemination_(#{Enum.join(@months, "|")})_(\d{4})(_V2)?\.zip/

  # A saved URL that is one of CMS's monthly files and so should follow the newest month.
  @cms_monthly_url ~r|\Ahttps://download\.cms\.gov/nppes/NPPES_Data_Dissemination_[A-Za-z]+_\d{4}(_V2)?\.zip\z|

  def index_url, do: @index_url

  @doc "True when `url` is empty or is one of CMS's monthly files."
  def follows_latest?(url) when url in [nil, ""], do: true

  def follows_latest?(url) when is_binary(url),
    do: Regex.match?(@cms_monthly_url, String.trim(url))

  @doc """
  Returns the URL to download: the newest CMS monthly file when `saved_url`
  follows the latest month, otherwise `saved_url` unchanged.

  If the download page cannot be read or lists no monthly file, returns
  `saved_url` and logs why, so the refresh still tries the saved URL.

  Options: `:fetch` — `fn url -> {:ok, html} | {:error, reason} end`
  (default reads the page over HTTP).
  """
  def resolve(saved_url, opts \\ []) do
    if follows_latest?(saved_url) do
      fetch = Keyword.get(opts, :fetch, &fetch_page/1)

      with {:ok, html} <- fetch.(@index_url),
           {:ok, latest} <- latest_from_html(html) do
        latest
      else
        {:error, reason} ->
          Logger.warning(
            "NPPES: could not find the newest monthly file (#{reason}); using the saved URL"
          )

          saved_url
      end
    else
      saved_url
    end
  end

  @doc """
  Picks the newest monthly file linked from the download page's HTML.
  Prefers the V2 file when a month has both. Returns an absolute URL.
  """
  def latest_from_html(html) when is_binary(html) do
    @monthly_file
    |> Regex.scan(html)
    |> Enum.map(fn [file, month, year | v2] ->
      {{String.to_integer(year), month_number(month), v2 == ["_V2"]}, file}
    end)
    |> Enum.max_by(fn {key, _file} -> key end, fn -> nil end)
    |> case do
      nil -> {:error, "no monthly file listed on #{@index_url}"}
      {_key, file} -> {:ok, @base_url <> file}
    end
  end

  defp month_number(name), do: Enum.find_index(@months, &(&1 == name)) + 1

  defp fetch_page(url) do
    case Req.get(url, receive_timeout: 30_000, retry: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "download page returned HTTP #{status}"}
      {:error, reason} -> {:error, "download page unreachable: #{inspect(reason)}"}
    end
  end
end
