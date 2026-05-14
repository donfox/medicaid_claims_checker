defmodule MedicaidClaimsChecker.Claims do
  @moduledoc """
  Context for batch processing of X12 EDI files.
  """
  import Ecto.Query
  alias MedicaidClaimsChecker.Repo

  alias MedicaidClaimsChecker.Claims.{
    Batch,
    EdiFile,
    BusinessRule,
    RuleCatalogue,
    NppesProvider
  }

  require Logger

  # --- Batch operations ---

  def create_batch(attrs) do
    %Batch{}
    |> Batch.changeset(attrs)
    |> Repo.insert()
  end

  def get_batch(id), do: Repo.get(Batch, id)
  def get_batch!(id), do: Repo.get!(Batch, id)

  def get_batch_by_batch_id(batch_id) do
    Repo.get_by(Batch, batch_id: batch_id)
  end

  def update_batch(%Batch{} = batch, attrs) do
    batch
    |> Batch.changeset(attrs)
    |> Repo.update()
  end

  def list_recent_batches(limit \\ 20) do
    Batch
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def clear_batch_history do
    Repo.delete_all(EdiFile)
    Repo.delete_all(Batch)
    :ok
  end

  # --- Batch ingest ---

  @doc """
  Ingests a translated batch.

  Expects a map with:
    - "batch_id"  => unique string identifier
    - "source"    => origin description (e.g. "sftp://claims.example.com/daily")
    - "claims"    => list of %{"filename" => string, "claim" => map}

  Creates a batch record and one edi_file per claim inside a transaction.
  Returns {:ok, %{batch: batch, edi_files: [edi_file, ...]}} or {:error, reason}.
  """
  def ingest_batch(%{"batch_id" => batch_id, "claims" => claims} = params)
      when is_list(claims) do
    source = Map.get(params, "source", "manual_upload")
    batch_name = Map.get(params, "batch_name") || default_batch_name(source)

    result =
      Repo.transaction(fn ->
        batch_attrs = %{
          batch_id: batch_id,
          batch_name: batch_name,
          source: source,
          file_count: length(claims),
          status: "pending",
          started_at: DateTime.utc_now()
        }

        batch =
          case %Batch{} |> Batch.changeset(batch_attrs) |> Repo.insert() do
            {:ok, b} -> b
            {:error, changeset} -> Repo.rollback({:batch, changeset})
          end

        edi_files =
          Enum.map(claims, fn %{"filename" => filename, "claim" => claim_json} ->
            file_attrs = %{
              filename: filename,
              file_path: "ingest://#{batch_id}/#{filename}",
              json_output: claim_json,
              status: "translated",
              processed_at: DateTime.utc_now(),
              batch_id: batch.id
            }

            case %EdiFile{} |> EdiFile.changeset(file_attrs) |> Repo.insert() do
              {:ok, f} -> f
              {:error, changeset} -> Repo.rollback({:edi_file, filename, changeset})
            end
          end)

        %{batch: batch, edi_files: edi_files}
      end)

    # After successful ingest, trigger auto-evaluation asynchronously
    case result do
      {:ok, %{batch: batch}} ->
        Logger.info("Batch #{batch.batch_id} ingested — launching auto-evaluation")

        unless Application.get_env(:medicaid_claims_checker, :skip_async_evaluation, false) do
          %{"batch_id" => batch.id}
          |> MedicaidClaimsChecker.Workers.BatchEvaluationWorker.new()
          |> Oban.insert!()
        end

        result

      _ ->
        result
    end
  end

  def ingest_batch(_), do: {:error, :invalid_payload}

  # --- EDI File operations ---

  def create_edi_file(attrs) do
    %EdiFile{}
    |> EdiFile.changeset(attrs)
    |> Repo.insert()
  end

  def get_edi_file!(id), do: Repo.get!(EdiFile, id)

  def update_edi_file_evaluation(%EdiFile{} = edi_file, attrs) do
    edi_file
    |> EdiFile.changeset(attrs)
    |> Repo.update()
  end

  def list_files_for_batch(batch_id) do
    EdiFile
    |> where([f], f.batch_id == ^batch_id)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  def list_errors_for_batch(batch_id) do
    EdiFile
    |> where([f], f.batch_id == ^batch_id and f.status in ["syntax_error", "fraudulent"])
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  def batch_summary(batch_id) do
    counts =
      EdiFile
      |> where([f], f.batch_id == ^batch_id)
      |> group_by([f], f.status)
      |> select([f], {f.status, count(f.id)})
      |> Repo.all()
      |> Map.new()

    %{
      total: Map.values(counts) |> Enum.sum(),
      pending: Map.get(counts, "pending", 0),
      translated: Map.get(counts, "translated", 0),
      syntax_error: Map.get(counts, "syntax_error", 0),
      fraudulent: Map.get(counts, "fraudulent", 0)
    }
  end

  def list_business_rules do
    BusinessRule
    |> order_by(asc: :name)
    |> Repo.all()
  end

  def list_active_business_rules do
    BusinessRule
    |> where([r], r.active == true)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  def create_business_rule(attrs) do
    %BusinessRule{}
    |> BusinessRule.changeset(attrs)
    |> Repo.insert()
  end

  def update_business_rule(%BusinessRule{} = business_rule, attrs) do
    business_rule
    |> BusinessRule.changeset(attrs)
    |> Repo.update()
  end

  def delete_business_rule(%BusinessRule{} = business_rule) do
    Repo.delete(business_rule)
  end

  def get_business_rule(id), do: Repo.get(BusinessRule, id)

  def get_business_rule_by_name(name), do: Repo.get_by(BusinessRule, name: name)

  def toggle_business_rule_active(%BusinessRule{} = business_rule) do
    update_business_rule(business_rule, %{active: !business_rule.active})
  end

  # --- Rule Catalogue operations ---

  def list_catalogue_entries do
    RuleCatalogue
    |> order_by([c], asc: c.entry_type, asc: c.name)
    |> Repo.all()
  end

  def get_catalogue_entry(id), do: Repo.get(RuleCatalogue, id)

  def get_catalogue_entry_by_name(name) do
    Repo.get_by(RuleCatalogue, name: name)
  end

  def create_catalogue_entry(attrs) do
    %RuleCatalogue{}
    |> RuleCatalogue.changeset(attrs)
    |> Repo.insert()
  end

  def update_catalogue_entry(%RuleCatalogue{} = entry, attrs) do
    entry
    |> RuleCatalogue.changeset(attrs)
    |> Repo.update()
  end

  def delete_catalogue_entry(%RuleCatalogue{} = entry) do
    Repo.delete(entry)
  end

  def toggle_catalogue_status(%RuleCatalogue{} = entry) do
    new_status = if entry.status == "Active", do: "Inactive", else: "Active"
    update_catalogue_entry(entry, %{status: new_status})
  end

  # --- NPPES Provider Lookup ---

  def lookup_npi(npi_string) do
    case Repo.get(NppesProvider, npi_string) do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  def validate_provider_npi(npi_string, service_date) do
    case lookup_npi(npi_string) do
      {:error, :not_found} ->
        {:reject, "NPI #{npi_string} not found in NPPES registry"}

      {:ok, provider} ->
        if NppesProvider.active_on_date?(provider, service_date) do
          :ok
        else
          {:reject,
           "Provider NPI #{npi_string} was deactivated on #{provider.deactivation_date}, " <>
             "service rendered on #{service_date}"}
        end
    end
  end

  def validate_claim_providers(claim_json) do
    provider_npi =
      get_in(claim_json, ["provider", "npi"]) ||
        get_in(claim_json, ["claim", "rendering_provider", "npi"])

    billing_npi = get_in(claim_json, ["billing_provider", "npi"])
    service_date = extract_earliest_service_date(claim_json)

    case service_date do
      nil ->
        {:reject, "No service date found on claim — cannot validate provider NPI"}

      date ->
        npis =
          [provider_npi, billing_npi]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        case npis do
          [] ->
            :ok

          npis ->
            Enum.reduce_while(npis, :ok, fn npi, :ok ->
              case validate_provider_npi(npi, date) do
                :ok -> {:cont, :ok}
                {:reject, reason} -> {:halt, {:reject, reason}}
              end
            end)
        end
    end
  end

  defp extract_earliest_service_date(claim_json) do
    # service_lines may be at top level or nested under "claim"
    service_lines =
      claim_json["service_lines"] ||
        get_in(claim_json, ["claim", "service_lines"]) ||
        []

    dates =
      service_lines
      |> Enum.flat_map(fn line ->
        [line["date_of_service"], line["service_date"]]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(fn str ->
        case parse_date(str) do
          {:ok, d} -> [d]
          _ -> []
        end
      end)

    case dates do
      [] -> nil
      dates -> Enum.min(dates, Date)
    end
  end

  # Parses ISO 8601 (2026-03-10) or compact (20260310) date strings
  defp parse_date(<<y::binary-size(4), "-", m::binary-size(2), "-", d::binary-size(2)>>) do
    Date.from_iso8601("#{y}-#{m}-#{d}")
  end

  defp parse_date(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>) do
    Date.from_iso8601("#{y}-#{m}-#{d}")
  end

  defp parse_date(_), do: :error

  # Returns catalogue entries whose names are similar to the given name (Jaro distance > 0.85),
  # excluding any exact case-insensitive match (which would be a conflict, not redundancy).
  def find_similar_catalogue_entries(name) do
    name_lower = String.downcase(String.trim(name))

    RuleCatalogue
    |> Repo.all()
    |> Enum.filter(fn entry ->
      entry_lower = String.downcase(entry.name)
      entry_lower != name_lower and String.jaro_distance(name_lower, entry_lower) > 0.85
    end)
  end

  defp default_batch_name(source) do
    timestamp = format_eastern_timestamp()

    case source do
      "ui_upload" -> "UI Upload - #{timestamp}"
      "manual_upload" -> "Manual Upload - #{timestamp}"
      other -> "#{other} - #{timestamp}"
    end
  end

  defp format_eastern_timestamp do
    DateTime.utc_now()
    |> DateTime.shift_zone!("America/New_York")
    |> Calendar.strftime("%b %d, %Y %I:%M %p %Z")
  end
end
