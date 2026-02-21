defmodule X12FraudWeb.Claims.BusinessRule do
  use Ecto.Schema
  import Ecto.Changeset

  schema "business_rules" do
    field :name, :string
    field :rule_text, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(business_rule, attrs) do
    business_rule
    |> cast(attrs, [:name, :rule_text, :active])
    |> validate_required([:name, :rule_text])
    |> validate_length(:name, min: 3, max: 120)
    |> validate_length(:rule_text, min: 10)
    |> unique_constraint(:name)
  end
end
