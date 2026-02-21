# JSON Claims Integrity

This folder contains focused reference docs for the JSON Claims Integrity project.

## Start Here

- Architecture and API overview: `ARCHITECTURE.md`
- DSL authoring reference and examples: `SYNTAX_GUIDE.md`
- Current database model and expansion notes: `DATABASE_ERD.md`

## ML Integration Docs

- Contract/specification: `ML_DSL_POLICY_CONTRACT.md`
- Implementation status checklist: `ML_DSL_IMPLEMENTATION_CHECKLIST.md`
- Reuse/import plan from X12 POC: `ML_IMPORT_PLAN_FROM_X12_POC.md`

## Quick Runtime Notes

- Backend: Haskell service on port 8080
- Frontend: Phoenix LiveView on port 4000
- Start both from repo root:

```bash
./start.sh --force-kill-ports
```

## License

Proprietary — All rights reserved.

No permission is granted to use, copy, modify, or distribute this software without prior written consent from the copyright owner.

See the repository root `LICENSE` file for full terms.
