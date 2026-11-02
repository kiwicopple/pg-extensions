-- Fixed IDs for the scenarios in research/plan.md §5 and §6.
-- UUID-shaped so they work with text- and uuid-typed implementations.
-- The 4th group says what kind of thing it is.

-- users (0001)
\set alice  '00000000-0000-0000-0001-000000000001'
\set bob    '00000000-0000-0000-0001-000000000002'
\set carol  '00000000-0000-0000-0001-000000000003'
\set dave   '00000000-0000-0000-0001-000000000004'
\set erin   '00000000-0000-0000-0001-000000000005'

-- orgs / scopes (0002)
\set acme   '00000000-0000-0000-0002-000000000001'
\set globex '00000000-0000-0000-0002-000000000002'

-- documents (0003)
\set acme_plan    '00000000-0000-0000-0003-000000000001'
\set acme_readme  '00000000-0000-0000-0003-000000000002'
\set globex_notes '00000000-0000-0000-0003-000000000003'

-- teams (0004)
\set eng      '00000000-0000-0000-0004-000000000001'
\set platform '00000000-0000-0000-0004-000000000002'
