defmodule X12FraudWeb.Claims.BusinessRule do
  @moduledoc """
  Ecto schema for the `business_rules` table.

  Stores the DSL rule text for Business Analyst (BA) rules. Each row pairs
  with a matching `rule_catalogue` entry via the `name` field — the catalogue
  holds metadata (type, status flags) while this table holds the executable
  rule logic.

  ## Lifecycle

  1. A BA Rule is authored in the UI as free-form DSL text.
  2. On save, `changeset/2` validates and persists the text here.
  3. At evaluation time the Haskell engine receives the `rule_text` via
     `POST /api/compile-rules` (parse + cache) or `POST /api/evaluate`
     (parse + run inline).

  Default Rules and ML Models do NOT have rows in this table — their
  logic lives in the Haskell engine or an external ML service respectively.
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
