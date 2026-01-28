defmodule X12FraudWebWeb.ErrorJSONTest do
  use X12FraudWebWeb.ConnCase, async: true

  test "renders 404" do
    assert X12FraudWebWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert X12FraudWebWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
