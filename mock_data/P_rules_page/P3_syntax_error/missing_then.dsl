-- P3: a rule with a syntax error. The Rules page must show "Rule syntax
-- issue" and refuse to save it. The THEN keyword is missing.
RULE missing_then_keyword
DESCRIPTION "Flag claims over $50,000"
WHEN financial.claim_amount > 50000
FLAG_FRAUD "Claim exceeds $50,000"
END
