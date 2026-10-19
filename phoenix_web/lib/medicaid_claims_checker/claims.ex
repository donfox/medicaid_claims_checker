defmodule MedicaidClaimsChecker.Claims do
  @moduledoc """
  Context for claims processing: batches, EDI files, business rules, the rule
  catalogue, and NPPES provider validation.

  Batches group EDI files for a single ingestion run. Files progress through
  processing statuses: `translated → evaluated | syntax_error`. Evaluation
  stores the engine's report in `evaluation_report` alongside the claim in
  `json_output`; HighRisk/CriticalRisk reports are counted as flagged for
  review. The engine recommends; it never marks a claim fraudulent.

  Business rules (BA Rules) store DSL text sent to the Haskell engine.
  The rule catalogue is the registry of all rule names and types (Default,
  BA, ML). NPPES lookup validates provider NPIs against the local registry.
  """
  import Ecto.Query
  alias MedicaidClaimsChecker.Repo

  alias MedicaidClaimsChecker.Claims.{
    Batch,
    EdiFile,
    BusinessRule,
    RuleCatalogue,
    NppesProvider,
    SubmittedFile,
    Fingerprint
  }

  require Logger

  # --- Batch operations ---

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

  @doc """
  Returns one page of batches, newest first, plus the total number of
  batches matching the filters (for paging).

  Options:
    * `:inserted_after` - only batches inserted after this `DateTime`
      (used to hide batches the user cleared from their display)
    * `:from` / `:to` - inclusive `DateTime` bounds on `inserted_at`
    * `:page` (default 1) and `:per_page` (default 20)

  Read-only; nothing is deleted or hidden at the database level.
  """
  def list_batches_page(opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, 20)
    query = filter_batches(opts)

    batches =
      query
      |> order_by(desc: :inserted_at, desc: :id)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {batches, Repo.aggregate(query, :count)}
  end

  @doc "Counts batches matching the same filters as `list_batches_page/1`."
  def count_batches(opts \\ []), do: opts |> filter_batches() |> Repo.aggregate(:count)

  defp filter_batches(opts) do
    Enum.reduce(opts, Batch, fn
      {:inserted_after, %DateTime{} = t}, q -> where(q, [b], b.inserted_at > ^t)
      {:from, %DateTime{} = t}, q -> where(q, [b], b.inserted_at >= ^t)
      {:to, %DateTime{} = t}, q -> where(q, [b], b.inserted_at <= ^t)
      _, q -> q
    end)
  end

  # --- Batch ingest ---

  # Ingests run one at a time under this Postgres advisory lock, so two
  # submissions of the same file or claim can't both pass the duplicate check.
  @ingest_lock_key 7_301_844_221

  @doc """
  Ingests a translated batch, refusing anything that was already submitted.

  Expects a map with:
    - "batch_id"  => unique string identifier
    - "source"    => origin description (e.g. "sftp://claims.example.com/daily")
    - "claims"    => list of %{"filename" => string, "claim" => map}, each
      optionally with "source_file" => %{"filename" => string, "sha256" => hex}
      naming the submitted file it came from (see `Claims.Fingerprint.file/1`)

  A claim is refused as a duplicate when its source file was submitted
  before, when the same claim (ignoring the X12 envelope) is in an earlier
  batch, or when it repeats an earlier claim in this submission. Each refusal
  is stored in `batch.duplicates` and names the earlier submission; the other
  claims are evaluated as usual. When every claim is a duplicate the batch is
  recorded as "failed" with no claims, so the refusal still shows in history.

  Returns {:ok, %{batch: batch, edi_files: [...], duplicates: [...]}} or
  {:error, reason}.
  """
  def ingest_batch(%{"batch_id" => batch_id, "claims" => claims} = params)
      when is_list(claims) do
    source = Map.get(params, "source", "manual_upload")
    batch_name = Map.get(params, "batch_name") || default_batch_name(source)

    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1)", [@ingest_lock_key])

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

        {accepted, duplicates, known_files} = split_duplicates(claims)

        edi_files =
          Enum.map(accepted, fn {%{"filename" => filename, "claim" => claim_json}, fingerprint} ->
            file_attrs = %{
              filename: filename,
              file_path: "ingest://#{batch_id}/#{filename}",
              json_output: claim_json,
              claim_fingerprint: fingerprint,
              status: "translated",
              processed_at: DateTime.utc_now(),
              batch_id: batch.id
            }

            case %EdiFile{} |> EdiFile.changeset(file_attrs) |> Repo.insert() do
              {:ok, f} -> f
              {:error, changeset} -> Repo.rollback({:edi_file, filename, changeset})
            end
          end)

        record_submitted_files(claims, known_files, batch)

        batch =
          if duplicates == [] do
            batch
          else
            refused_attrs =
              if edi_files == [],
                do: %{status: "failed", completed_at: DateTime.utc_now()},
                else: %{}

            batch
            |> Batch.changeset(Map.merge(refused_attrs, %{file_count: length(edi_files), duplicates: duplicates}))
            |> Repo.update!()
          end

        %{batch: batch, edi_files: edi_files, duplicates: duplicates}
      end)

    case result do
      {:ok, %{batch: batch, edi_files: [], duplicates: duplicates}} ->
        Logger.warning("Batch #{batch.batch_id} not evaluated — #{duplicates_notice(duplicates)}")

        Phoenix.PubSub.broadcast(
          MedicaidClaimsChecker.PubSub,
          MedicaidClaimsChecker.Claims.Evaluator.topic(),
          {:batch_failed, %{batch_id: batch.batch_id, reason: duplicates_notice(duplicates)}}
        )

        result

      {:ok, %{batch: batch, duplicates: duplicates}} ->
        if duplicates != [] do
          Logger.warning("Batch #{batch.batch_id}: #{duplicates_notice(duplicates)}")
        end

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

  # --- Duplicate submissions ---

  # Splits ingest entries into {accepted, duplicates, known_files}: accepted
  # is [{entry, claim_fingerprint}], duplicates are the refusal records stored
  # on the batch, and known_files maps already-submitted file hashes to their
  # earlier submission. A refused file is listed once, however many claims it
  # holds.
  defp split_duplicates(claims) do
    entries = Enum.map(claims, &{&1, Fingerprint.claim(&1["claim"])})
    known_files = previous_files(entries)
    known_claims = previous_claims(entries)

    {accepted, duplicates, _seen, _refused_files} =
      Enum.reduce(entries, {[], [], %{}, MapSet.new()}, fn {entry, fingerprint}, {acc, dups, seen, refused_files} ->
        file_sha = get_in(entry, ["source_file", "sha256"])

        cond do
          Map.has_key?(known_files, file_sha) ->
            if MapSet.member?(refused_files, file_sha) do
              {acc, dups, seen, refused_files}
            else
              dup = file_duplicate(entry["source_file"], known_files[file_sha])
              {acc, [dup | dups], seen, MapSet.put(refused_files, file_sha)}
            end

          Map.has_key?(known_claims, fingerprint) ->
            {acc, [claim_duplicate(entry, known_claims[fingerprint]) | dups], seen, refused_files}

          Map.has_key?(seen, fingerprint) ->
            {acc, [claim_duplicate(entry, %{filename: seen[fingerprint], batch: nil}) | dups], seen, refused_files}

          true ->
            {[{entry, fingerprint} | acc], dups, Map.put(seen, fingerprint, entry["filename"]), refused_files}
        end
      end)

    {Enum.reverse(accepted), Enum.reverse(duplicates), known_files}
  end

  defp previous_files(entries) do
    shas = entries |> Enum.map(fn {e, _} -> get_in(e, ["source_file", "sha256"]) end) |> Enum.reject(&is_nil/1)

    SubmittedFile
    |> join(:inner, [s], b in assoc(s, :batch))
    |> where([s], s.sha256 in ^shas)
    |> select([s, b], {s.sha256, %{filename: s.filename, batch: b}})
    |> Repo.all()
    |> Map.new()
  end

  # The earliest stored copy of each claim fingerprint.
  defp previous_claims(entries) do
    fingerprints = Enum.map(entries, fn {_, fp} -> fp end)

    EdiFile
    |> join(:inner, [f], b in assoc(f, :batch))
    |> where([f], f.claim_fingerprint in ^fingerprints)
    |> order_by([f], desc: f.inserted_at, desc: f.id)
    |> select([f, b], {f.claim_fingerprint, %{filename: f.filename, batch: b}})
    |> Repo.all()
    |> Map.new()
  end

  defp record_submitted_files(claims, known_files, batch) do
    claims
    |> Enum.map(& &1["source_file"])
    |> Enum.reject(&(is_nil(&1) or Map.has_key?(known_files, &1["sha256"])))
    |> Enum.uniq_by(& &1["sha256"])
    |> Enum.each(fn %{"filename" => filename, "sha256" => sha} ->
      %SubmittedFile{}
      |> SubmittedFile.changeset(%{sha256: sha, filename: filename, batch_id: batch.id})
      |> Repo.insert!()
    end)
  end

  defp file_duplicate(source_file, previous) do
    Map.merge(%{"kind" => "file", "filename" => source_file["filename"]}, previous_fields(previous))
  end

  defp claim_duplicate(entry, previous) do
    Map.merge(
      %{"kind" => "claim", "filename" => entry["filename"], "claim_id" => entry["claim"]["claim_id"]},
      previous_fields(previous)
    )
  end

  # previous.batch is nil when the earlier copy is in the same submission.
  defp previous_fields(%{filename: filename, batch: nil}),
    do: %{"previous_filename" => filename, "previous_batch_id" => nil}

  defp previous_fields(%{filename: filename, batch: batch}) do
    %{
      "previous_filename" => filename,
      "previous_batch_id" => batch.batch_id,
      "previous_batch_name" => batch.batch_name,
      "previous_submitted_at" => DateTime.to_iso8601(batch.inserted_at)
    }
  end

  @doc "One-line description of a refused duplicate, naming the earlier submission."
  def describe_duplicate(%{"kind" => "file", "filename" => filename} = dup),
    do: "#{filename} was already submitted #{earlier_submission(dup)}"

  def describe_duplicate(%{"previous_batch_id" => nil} = dup),
    do: "#{claim_label(dup)} appears twice in this submission (first as #{dup["previous_filename"]})"

  def describe_duplicate(dup),
    do: "#{claim_label(dup)} was already submitted #{earlier_submission(dup)} as #{dup["previous_filename"]}"

  @doc "Summary of a batch's refused duplicates for upload messages and logs."
  def duplicates_notice([]), do: ""

  def duplicates_notice(duplicates) do
    shown = duplicates |> Enum.take(3) |> Enum.map_join(" | ", &describe_duplicate/1)
    more = length(duplicates) - 3
    more_text = if more > 0, do: " (and #{more} more)", else: ""
    "Refused as already submitted: #{shown}#{more_text}"
  end

  defp claim_label(%{"claim_id" => id, "filename" => filename}) when is_binary(id) and id != "",
    do: "claim #{id} (#{filename})"

  defp claim_label(%{"filename" => filename}), do: "claim in #{filename}"

  defp earlier_submission(dup) do
    when_text =
      case DateTime.from_iso8601(dup["previous_submitted_at"] || "") do
        {:ok, dt, _} -> " on " <> (dt |> DateTime.shift_zone!("America/New_York") |> Calendar.strftime("%b %d, %Y %I:%M %p %Z"))
        _ -> ""
      end

    "in \"#{dup["previous_batch_name"] || dup["previous_batch_id"]}\"#{when_text}"
  end

  # --- EDI File operations ---

  def update_edi_file_evaluation(%EdiFile{} = edi_file, attrs) do
    edi_file
    |> EdiFile.changeset(attrs)
    |> Repo.update()
  end

  def list_files_for_batch(batch_id) do
    EdiFile
    |> where([f], f.batch_id == ^batch_id)
    |> order_by(asc: :inserted_at, asc: :id)
    |> Repo.all()
  end

  def list_errors_for_batch(batch_id) do
    EdiFile
    |> where([f], f.batch_id == ^batch_id and f.status == "syntax_error")
    |> order_by(asc: :inserted_at, asc: :id)
    |> Repo.all()
  end

  @flag_for_review_risks ["HighRisk", "CriticalRisk"]

  @doc "Returns true when an evaluation report warrants analyst review."
  def flagged_for_review?(%{"overallRisk" => risk}), do: risk in @flag_for_review_risks
  def flagged_for_review?(_report), do: false

  @doc """
  Returns a map of status counts for all edi_files in a batch, plus
  `flagged_for_review`: evaluated files whose report is HighRisk or CriticalRisk.
  """
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
      evaluated: Map.get(counts, "evaluated", 0),
      syntax_error: Map.get(counts, "syntax_error", 0),
      flagged_for_review: count_flagged_for_review(batch_id)
    }
  end

  defp count_flagged_for_review(batch_id) do
    EdiFile
    |> where([f], f.batch_id == ^batch_id)
    |> where(
      [f],
      fragment("?->>'overallRisk'", f.evaluation_report) in @flag_for_review_risks
    )
    |> Repo.aggregate(:count)
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

  def toggle_catalogue_status(%RuleCatalogue{status: "Retired"}), do: {:error, :retired}

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

  @doc """
  Checks one NPI against the NPPES registry on each service date (a `Date`
  or a list of them). On every date the NPI must already have been issued,
  be active (not deactivated, or reactivated), and still be listed by CMS.
  Returns `:ok` or `{:reject, reason}` for the earliest failing date.
  """
  def validate_provider_npi(npi_string, service_dates) do
    case lookup_npi(npi_string) do
      {:error, :not_found} ->
        {:reject, "NPI #{npi_string} not found in NPPES registry"}

      {:ok, provider} ->
        service_dates
        |> List.wrap()
        |> Enum.sort(Date)
        |> Enum.find_value(:ok, &provider_problem(provider, npi_string, &1))
    end
  end

  defp provider_problem(provider, npi, date) do
    cond do
      not NppesProvider.issued_by?(provider, date) ->
        {:reject, "Provider NPI #{npi} was not issued until #{provider.enumeration_date}, service rendered on #{date}"}

      not NppesProvider.active_on_date?(provider, date) ->
        {:reject, "Provider NPI #{npi} was deactivated on #{provider.deactivation_date}, service rendered on #{date}"}

      not NppesProvider.listed_on?(provider, date) ->
        {:reject,
         "Provider NPI #{npi} has not been in the NPPES file since #{provider.dropped_on}, service rendered on #{date}"}

      true ->
        nil
    end
  end

  @doc """
  Validates all NPIs on a claim against the NPPES registry.

  Checks the provider (`provider.npi`), the rendering provider
  (`rendering_provider.npi`, or `claim.rendering_provider.npi` in the X12
  schema) and the billing provider (`billing_provider.npi`) on every service
  date on the claim, so a line rendered after a deactivation is caught even
  when earlier lines are fine. Dates are judged as of the service, not today:
  claims often arrive months later. Returns `:ok` if every NPI passes on
  every date, `{:reject, reason}` on the first failure.

  Returns `:ok` when no NPIs are present (NPI presence is enforced elsewhere).
  """
  def validate_claim_providers(claim_json) do
    npis =
      [
        ["provider", "npi"],
        ["rendering_provider", "npi"],
        ["claim", "rendering_provider", "npi"],
        ["billing_provider", "npi"]
      ]
      |> Enum.map(&get_in(claim_json, &1))
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq()

    case extract_service_dates(claim_json) do
      [] ->
        {:reject, "No service date found on claim — cannot validate provider NPI"}

      dates ->
        Enum.reduce_while(npis, :ok, fn npi, :ok ->
          case validate_provider_npi(npi, dates) do
            :ok -> {:cont, :ok}
            {:reject, reason} -> {:halt, {:reject, reason}}
          end
        end)
    end
  end

  defp extract_service_dates(claim_json) do
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

    Enum.uniq(dates)
  end

  # Parses ISO 8601 (2026-03-10) or compact (20260310) date strings
  defp parse_date(<<y::binary-size(4), "-", m::binary-size(2), "-", d::binary-size(2)>>) do
    Date.from_iso8601("#{y}-#{m}-#{d}")
  end

  defp parse_date(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>) do
    Date.from_iso8601("#{y}-#{m}-#{d}")
  end

  defp parse_date(_), do: :error

  @doc """
  Returns catalogue entries whose names are similar to `name` (Jaro distance > 0.85),
  excluding exact case-insensitive matches (which are conflicts, not near-duplicates).
  """
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
