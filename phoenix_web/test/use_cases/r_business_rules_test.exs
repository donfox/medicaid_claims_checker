defmodule MedicaidClaimsCheckerWeb.UseCases.RBusinessRulesTest do
  @moduledoc "R1–R11: what the seeded business rules match, through a real upload."
  use MedicaidClaimsCheckerWeb.UseCaseCase

  manifest_tests(~w(R1 R2 R3 R4 R5 R6 R7 R9 R10 R11))

  # R8: provider tenure comes only from JSON claims (X12 has no credentialing date).
  manifest_tests_as("R8", [
    "R_business_rules/R2_each_rule_alone/NewProviderLargeSubmission.json",
    "R_business_rules/R2_each_rule_alone/TaxonomyMismatchNewProvider.json"
  ])
end
