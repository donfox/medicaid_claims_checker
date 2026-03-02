defmodule X12FraudWeb.Claims do
  @moduledoc """
  Context for batch processing of X12 EDI files.
  """
  import Ecto.Query
  alias X12FraudWeb.Repo
  alias X12FraudWeb.Claims.{Batch, EdiFile, BusinessRule, RuleCatalogue}

  # --- Batch operations ---

  def create_batch(attrs) do
    %Batch{}
    |> Batch.changeset(attrs)
    |> Repo.insert()
  end

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

  # --- EDI File operations ---

  def create_edi_file(attrs) do
    %EdiFile{}
    |> EdiFile.changeset(attrs)
    |> Repo.insert()
  end

  def get_edi_file!(id), do: Repo.get!(EdiFile, id)

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
end
