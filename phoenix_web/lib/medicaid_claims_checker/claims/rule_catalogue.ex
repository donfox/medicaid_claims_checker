defmodule MedicaidClaimsChecker.Claims.RuleCatalogue do
  @moduledoc """
  Ecto schema for the `rule_catalogue` table.

  The Rule Catalogue is the central registry of every rule known to the system.
  Each entry describes one rule but does NOT store its logic — logic lives
  either in the Haskell engine (Default Rules) or in the `business_rules`
  table (BA Rules), joined by matching `name`.

  ## Entry types

  | type           | logic location         | editable | removable |
  |----------------|------------------------|----------|-----------|
  | "Default Rule" | Haskell engine (fixed) | false    | false     |
  | "BA Rule"      | `business_rules` table | true     | true      |
  | "ML Model"     | external ML service    | false    | false     |
  """

  use Ecto.Schema
  import Ecto.Changeset

  # All permitted values for `entry_type` and `status`.
  @valid_types ["Default Rule", "BA Rule", "ML Model"]
  @valid_statuses ["Active", "Inactive"]

  schema "rule_catalogue" do
    # Human-readable identifier; must be unique across all rule types.
    field :name, :string

    # Plain-English summary shown in the UI rule list.
    field :description, :string

    # Determines where the rule logic lives; see module doc.
    field :entry_type, :string

    # Only "Active" rules are sent to the evaluation engine.
    field :status, :string, default: "Active"

    # Whether the rule's DSL text can be edited in the UI (BA Rules only).
    field :editable, :boolean, default: false

    # Whether the rule can be deleted from the UI (BA Rules only).
    field :removable, :boolean, default: false

    # Marked true when this rule overlaps significantly with another rule.
    field :redundant, :boolean, default: false

    # True when the rule requires a live DB query (e.g. duplicate detection).
    field :db_access, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates and casts attributes for creating or updating a catalogue entry.
  `name` and `entry_type` are required; `name` must be unique.
  """
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :name,
      :description,
      :entry_type,
      :status,
      :editable,
      :removable,
      :redundant,
      :db_access
    ])
    |> validate_required([:name, :entry_type])
    |> validate_length(:name, min: 2, max: 120)
    |> validate_inclusion(:entry_type, @valid_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:name)
  end

  # Accessors used by UI dropdowns and validation elsewhere.
  def valid_types, do: @valid_types
  def valid_statuses, do: @valid_statuses
end
