alias X12FraudWeb.Repo
alias X12FraudWeb.Claims.BusinessRule

now = DateTime.utc_now() |> DateTime.truncate(:second)

rules = [
  %{
    name: "HighValueReview",
    rule_text:
      """
      RULE high_value_review
      DESCRIPTION \"Flag high-value claims for manual review\"
      WHEN 2300.CLM.claim_amount > 50000
      THEN REQUIRE_REVIEW \"Exceeds high-value threshold\"
      END
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "WeekendOfficeVisit",
    rule_text:
      """
      RULE weekend_office_visit
      DESCRIPTION \"Office visit on weekend with elevated amount\"
      WHEN 2400.SV1.place_of_service = \"11\"
           AND 2400.DTP.service_day_of_week = \"SAT\"
           AND 2300.CLM.claim_amount > 500
      THEN REQUIRE_REVIEW \"Weekend office visit requires verification\"
      END
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "InpatientMismatch",
    rule_text:
      """
      RULE inpatient_mismatch
      DESCRIPTION \"Outpatient place of service with inpatient billing\"
      WHEN 2400.SV1.place_of_service = \"22\"
           AND 2300.CLM.facility_type = \"Inpatient\"
           AND 2300.CLM.claim_amount > 10000
      THEN REJECT \"Inpatient/outpatient mismatch detected\"
      END
      """
      |> String.trim(),
    active: false,
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  BusinessRule,
  rules,
  on_conflict: {:replace, [:rule_text, :active, :updated_at]},
  conflict_target: [:name]
)
