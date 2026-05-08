defmodule MedicaidClaimsChecker.X12.Codes.PlaceOfService do
  @moduledoc """
  Place of Service Code Lookups

  Maps place of service codes to descriptions.
  Identifies the physical location where healthcare service was provided.
  """

  @doc """
  Get description for place of service code.
  """
  def lookup(code) do
    case code do
      "01" -> "Pharmacy"
      "02" -> "Telehealth Provided Other than in Patient's Home"
      "10" -> "Telehealth Provided in Patient's Home"
      "11" -> "Office"
      "12" -> "Home"
      "21" -> "Inpatient Hospital"
      "22" -> "On Campus-Outpatient Hospital"
      "23" -> "Emergency Room - Hospital"
      "24" -> "Ambulatory Surgical Center"
      "31" -> "Skilled Nursing Facility"
      "32" -> "Nursing Facility"
      "33" -> "Custodial Care Facility"
      "34" -> "Hospice"
      "41" -> "Ambulance - Land"
      "42" -> "Ambulance - Air or Water"
      "49" -> "Independent Clinic"
      "50" -> "Federally Qualified Health Center"
      "51" -> "Inpatient Psychiatric Facility"
      "52" -> "Psychiatric Facility-Partial Hospitalization"
      "53" -> "Community Mental Health Center"
      "54" -> "Intermediate Care Facility/Individuals with Intellectual Disabilities"
      "55" -> "Residential Substance Abuse Treatment Facility"
      "56" -> "Psychiatric Residential Treatment Center"
      "57" -> "Non-residential Substance Abuse Treatment Facility"
      "60" -> "Mass Immunization Center"
      "61" -> "Comprehensive Inpatient Rehabilitation Facility"
      "62" -> "Comprehensive Outpatient Rehabilitation Facility"
      "65" -> "End-Stage Renal Disease Treatment Facility"
      "71" -> "Public Health Clinic"
      "72" -> "Rural Health Clinic"
      "81" -> "Independent Laboratory"
      "99" -> "Other Place of Service"
      _ -> code
    end
  end
end
