defmodule MedicaidClaimsCheckerWeb.UseCases.PRulesPageTest do
  @moduledoc "P1–P4: entering rules on the Rules page."
  use MedicaidClaimsCheckerWeb.UseCaseCase

  import Ecto.Query

  alias MedicaidClaimsChecker.{MockData, Repo}
  alias MedicaidClaimsChecker.Claims.BusinessRule

  # P2's claims, evaluated against redundancy_levels.dsl.
  manifest_tests(~w(P2))

  # The rules in a .dsl file: {name, text, level}, where level is the N of a
  # "-- Level N" comment just above the rule (nil if none).
  defp rules_in(rel) do
    rel
    |> MockData.read!()
    |> String.split("\n")
    |> Enum.reduce({[], nil, nil}, fn line, {rules, level, current} ->
      cond do
        current ->
          current = current <> "\n" <> line

          if String.trim(line) == "END" or String.ends_with?(String.trim(line), ";"),
            do: {[finish(current, level) | rules], nil, nil},
            else: {rules, level, current}

        String.starts_with?(line, "RULE ") ->
          {rules, level, line}

        match = Regex.run(~r/^-- Level (\d)/, line) ->
          {rules, String.to_integer(Enum.at(match, 1)), nil}

        String.trim(line) == "" ->
          {rules, nil, nil}

        true ->
          {rules, level, nil}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp finish(text, level) do
    [_, name] = Regex.run(~r/^RULE\s+(\w+)/, text)
    {name, text, level}
  end

  # Types a rule into the form and saves it; on a redundancy warning, returns
  # the warning's lines and presses Save Anyway.
  defp save_rule(view, name, text) do
    params = %{"catalog" => %{"name" => name, "text" => text}}
    view |> form("#catalog-rule-form", params) |> render_change()
    view |> form("#catalog-rule-form", params) |> render_submit()

    if has_element?(view, "#redundancy-warning") do
      lines =
        view
        |> element("#redundancy-warning")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("li")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))

      view |> element("#save-anyway") |> render_click()
      lines
    else
      []
    end
  end

  defp saved(name), do: Repo.one(from(r in BusinessRule, where: r.name == ^name))

  @tag use_case: "P1"
  test "P1 every rule in examples.dsl parses and saves as an active rule", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/rules")
    rules = rules_in("P_rules_page/P1_feature_examples/examples.dsl")
    assert length(rules) == 10

    for {name, text, _} <- rules do
      params = %{"catalog" => %{"name" => name, "text" => text}}
      view |> form("#catalog-rule-form", params) |> render_change()
      assert has_element?(view, "#rule-syntax-ok"), "#{name}: syntax not accepted"

      save_rule(view, name, text)
      refute has_element?(view, "#catalog-error"), "#{name}: could not be saved"
      assert %{active: true} = saved(name), "#{name}: not saved as an active rule"
    end
  end

  @level_label %{
    1 => "Exact Duplicate",
    2 => "Redundant Rule",
    3 => "Action Conflict",
    4 => "Partial Overlap"
  }

  @tag use_case: "P2"
  test "P2 redundancy_levels.dsl: each rule marked Level N gets a Level N warning", %{conn: conn} do
    # Only this file's rules: the seeded ones would add warnings of their own.
    Repo.update_all(BusinessRule, set: [active: false])
    {:ok, view, _html} = live(conn, ~p"/rules")
    rules = rules_in("P_rules_page/P2_redundancy_levels/redundancy_levels.dsl")
    assert Enum.count(rules, &elem(&1, 2)) >= 15

    # Collect every mismatch, so one run lists them all.
    problems =
      Enum.flat_map(rules, fn {name, text, level} ->
        warnings = save_rule(view, name, text)
        label = level && @level_label[level]

        cond do
          !match?(%{active: true}, saved(name)) ->
            ["#{name}: not saved as an active rule"]

          level && !Enum.any?(warnings, &String.starts_with?(&1, label <> " with ")) ->
            ["#{name}: expected a #{label} (Level #{level}) warning, got #{inspect(warnings)}"]

          true ->
            []
        end
      end)

    assert problems == [], Enum.join(problems, "\n\n")
  end

  @tag use_case: "P3"
  test "P3 a rule with a syntax error is shown as an issue and not saved", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/rules")
    [{name, text, _}] = rules_in("P_rules_page/P3_syntax_error/missing_then.dsl")
    params = %{"catalog" => %{"name" => name, "text" => text}}

    view |> form("#catalog-rule-form", params) |> render_change()
    assert has_element?(view, "#rule-syntax-error")

    view |> form("#catalog-rule-form", params) |> render_submit()
    assert has_element?(view, "#catalog-error", "Could not save rule")
    assert saved(name) == nil
  end

  @tag use_case: "P4"
  test "P4 a rule using an unknown field is saved as an inactive draft with a suggestion", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/rules")
    [{name, text, _}] = rules_in("P_rules_page/P4_unknown_field/old_field_name.dsl")

    save_rule(view, name, text)
    assert %{active: false} = saved(name)
    assert render(view) =~ "subscriber.subscriber_id -&gt; subscriber.member_id"
  end
end
