# Writes mock_data/nppes_extract.json: the NPPES registry rows for every NPI
# the mock data uses, copied from the dev database. The use-case tests load
# them into the (empty) test database, so claims are checked against the same
# provider records as in the running app.
#
# Run again after re-importing NPPES or adding a provider to the mock data:
#
#   cd phoenix_web && mix run --no-start ../mock_data/export_nppes_extract.exs
#
# An NPI the registry doesn't know (a deliberately unissued or malformed one)
# is simply absent from the extract, as it is from the registry.

alias MedicaidClaimsChecker.Repo
import Ecto.Query

Application.put_env(:medicaid_claims_checker, Repo, Keyword.put(Application.get_env(:medicaid_claims_checker, Repo), :pool_size, 2))
{:ok, _} = Application.ensure_all_started([:postgrex, :ecto_sql])
{:ok, _} = Repo.start_link()

root = Path.dirname(__ENV__.file)

# Every 10-digit number in the mock data, including inside zips.
contents = fn path ->
  data = File.read!(path)

  if String.ends_with?(path, ".zip") do
    case :zip.unzip(data, [:memory]) do
      {:ok, entries} -> Enum.map(entries, &elem(&1, 1))
      _ -> []
    end
  else
    [data]
  end
end

npis =
  Path.wildcard(Path.join(root, "**/*.{json,x12,edi,zip}"))
  |> Enum.reject(&(Path.basename(&1) in ["manifest.json", "nppes_extract.json"]))
  |> Enum.flat_map(contents)
  |> Enum.flat_map(&Regex.scan(~r/(?<![0-9])[0-9]{10}(?![0-9])/, &1))
  |> List.flatten()
  |> Enum.uniq()

fields = ~w(npi entity_type provider_name credential taxonomy state enumeration_date
            deactivation_date reactivation_date last_update_date dropped_on)a

rows =
  from(p in "nppes_providers", where: p.npi in ^npis, order_by: p.npi, select: map(p, ^fields))
  |> Repo.all()
  |> Enum.map(fn row -> Map.new(row, fn {k, v} -> {k, if(match?(%Date{}, v), do: Date.to_iso8601(v), else: v)} end) end)

out = Path.join(root, "nppes_extract.json")
File.write!(out, Jason.encode!(%{"about" => "NPPES rows for the NPIs in mock_data, from the dev database. Written by export_nppes_extract.exs.", "providers" => rows}, pretty: true) <> "\n")
IO.puts("#{length(rows)} providers (of #{length(npis)} 10-digit numbers in the mock data) written to #{out}")
