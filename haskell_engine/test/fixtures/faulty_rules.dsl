-- Faulty DSL Rules for Testing
-- Each rule has a specific fault and should FAIL to parse
-- Test each rule individually

-- FAULT 1: Missing description
RULE no_description
WHEN claim.amount > 1000
THEN FLAG_FRAUD "Test"
END

-- FAULT 2: Missing WHEN keyword
RULE missing_when
DESCRIPTION "No WHEN keyword"
claim.amount > 1000
THEN FLAG_FRAUD "Test"
END

-- FAULT 3: Missing THEN keyword
RULE missing_then
DESCRIPTION "No THEN keyword"
WHEN claim.amount > 1000
FLAG_FRAUD "Test"
END

-- FAULT 4: Missing terminator
RULE no_terminator
DESCRIPTION "Missing END"
WHEN claim.amount > 1000
THEN FLAG_FRAUD "Test"

-- FAULT 5: Invalid operator <>
RULE bad_operator
DESCRIPTION "Uses invalid operator"
WHEN claim.amount <> 1000
THEN FLAG_FRAUD "Test"
END

-- FAULT 6: Unclosed string (this will break parsing from here)
-- RULE unclosed_string
-- DESCRIPTION "Has unclosed string
-- WHEN claim.amount > 1000
-- THEN FLAG_FRAUD "Test"
-- END

-- FAULT 7: Invalid action keyword
RULE bad_action
DESCRIPTION "Uses invalid action"
WHEN claim.amount > 1000
THEN ALERT "Test"
END

-- FAULT 8: Function call syntax (unsupported)
RULE function_style
DESCRIPTION "Tries to use function syntax"
WHEN claim.has_diagnosis("J06")
THEN FLAG_FRAUD "Test"
END

-- FAULT 9: Missing value after operator
RULE missing_value
DESCRIPTION "Comparison without value"
WHEN claim.amount >
THEN FLAG_FRAUD "Test"
END

-- FAULT 10: Unbalanced parentheses
RULE unbalanced_parens
DESCRIPTION "Mismatched parentheses"
WHEN (claim.amount > 1000 AND provider.state = "CA"
THEN FLAG_FRAUD "Test"
END
