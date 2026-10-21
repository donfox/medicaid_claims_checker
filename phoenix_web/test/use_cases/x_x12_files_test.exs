defmodule MedicaidClaimsCheckerWeb.UseCases.XX12FilesTest do
  @moduledoc "X1–X7: uploading .x12 files."
  use MedicaidClaimsCheckerWeb.UseCaseCase

  manifest_tests(~w(X1 X2 X3 X4 X5 X6 X7))
end
