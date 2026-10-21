defmodule MedicaidClaimsCheckerWeb.UseCases.NNppesTest do
  @moduledoc """
  N1–N11: the NPPES provider check, against the registry rows in
  mock_data/nppes_extract.json.
  """
  use MedicaidClaimsCheckerWeb.UseCaseCase

  manifest_tests(~w(N2 N3 N4 N5 N6 N7 N8 N9 N10 N11))

  # N1: an active provider passes. Every clean claim has one.
  manifest_tests_as("N1", [
    "R_business_rules/R1_clean_claim/office_visit.json",
    "X_x12_files/X1_837p_professional/clean_office_visit.x12"
  ])
end
