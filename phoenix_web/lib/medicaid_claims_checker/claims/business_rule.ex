defmodule MedicaidClaimsChecker.Claims.BusinessRule do
  @moduledoc """
  Ecto schema for the `business_rules` table.

  Stores the DSL text of every rule written in the DSL: all BA Rules and
  most Default Rules. Each row pairs with a matching `rule_catalogue` entry
  via the `name` field — the catalogue holds metadata (type, status flags)
  while this table holds the executable rule logic.

  ## Lifecycle

  1. Default Rules are seeded by `priv/repo/seeds.exs` and can't be edited
     in the UI. A BA Rule is authored in the UI as free-form DSL text.
  2. On save, `changeset/2` validates and persists the text here.
  3. At evaluation time `Evaluator` sends the active rules' `rule_text`
     (Default and BA alike) to the Haskell engine's `POST /api/batch-evaluate`,
     which parses and runs them on every request.

  Catalogue entries with no row here: the ML Models (no scoring service
  exists yet), and two Default Rules whose logic isn't DSL —
  `NPPESProviderLookup`, done in Elixir (`Claims.validate_claim_providers/1`),
  and the Not connected ones (`DuplicateClaims` and six that need data not
  loaded yet), listed but not implemented.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "business_rules" do
    # Must match the corresponding `rule_catalogue.name` exactly.
    field :name, :string

    # Raw DSL text sent to the Haskell engine for parsing and evaluation.
    field :rule_text, :string

    # When false the rule is skipped during evaluation (soft disable).
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates and casts attributes for creating or updating a BA rule.

  Enforces:
  - `name` and `rule_text` are required
  - `name` is 3–120 characters and unique
  - `rule_text` is at least 10 characters (guards against empty saves)
  """
  def changeset(business_rule, attrs) do
    business_rule
    |> cast(attrs, [:name, :rule_text, :active])
    |> validate_required([:name, :rule_text])
    |> validate_length(:name, min: 3, max: 120)
    |> validate_length(:rule_text, min: 10)
    |> unique_constraint(:name)
  end
end
