# Scholarship Monitoring and Academic Compliance System (Section B)

Stack: HTML/CSS/JS (single file `index.html`) + Supabase (Postgres, Auth, row-level security).

## Setup
1. Create a Supabase project. In **Authentication > Users**, add two synthetic accounts (one scholar, one staff).
2. In the SQL editor, run `schema.sql` (tables, access policies, functions, policies, seed B01 to B06).
3. Copy each account's Auth UUID and run the two commented `update profiles ...` lines at the end of `schema.sql`
   (scholar account -> `B01`, staff account -> `STAFF01`). To test other scholars, relink `auth_id` to another `B0x`.
4. In `index.html`, set `SUPABASE_URL` and `SUPABASE_ANON_KEY` (anon key only; no service-role key anywhere).
5. Run locally: `python3 -m http.server 8000`, open http://localhost:8000. Test-account passwords go to the instructor privately.

## How the rules are enforced
- Tables allow **select only** through RLS: scholars read their own rows, staff read all. All writes go through
  `security definer` functions that check role, validation, duplicates, the verification gate and renewal authority.
- Policy thresholds and the deadline are read from the `programs` row of the scholar's assignment; the evaluation code has no hard-coded limits.
- Submission status, compliance result and award status (`assignments.award_status`) are separate fields.
- Every verification, evaluation, renewal and resubmission is logged in `history` with actor and timestamp.

## Expected results for the seed data (derive, then compare with actual)
| ID | Expected compliance | Reasons |
|---|---|---|
| B01 | Compliant | GWA 2.00 and deadline 17:00 are inclusive |
| B02 | With Deficiency | GWA 2.01 above 2.00 |
| B03 | Compliant | 1 dropped allowed for Access Scholar |
| B04 | With Deficiency | Units 14 below 15; 1 incomplete grade |
| B05 | With Deficiency | 1 failed subject; submitted 1 minute late |
| B06 | Blocked | Pending verification: evaluation and renewal blocked |

## Test results (fill in "Actual" and "Evidence" while testing)
| Test | Input or action | Expected | Actual | Pass/Fail | Evidence |
|---|---|---|---|---|---|
| TC01 | Evaluate B01 | Compliant | | | |
| TC02 | Evaluate B02 | With Deficiency, GWA reason | | | |
| TC03 | Evaluate B03 | Compliant | | | |
| TC04 | Evaluate B04 | Units and incomplete reasons | | | |
| TC05 | Evaluate B05 | Failed subject and late reasons | | | |
| TC06 | Evaluate and Approve B06 | Both blocked until verified and evaluated | | | |
| TC07 | Duplicate semester; GWA 0.50; negative count | Rejected with clear message | | | |
| TC08 | As scholar: read another record; call `verify_submission` | Denied by database | | | |
| TC09 | Return, correct, resubmit, refresh | Pending verification; history kept | | | |
| TC10 | Approve a compliant record; hold a deficient one; scholar tries to decide | Staff succeed; scholar denied | | | |

TC08 tip: in the browser console, signed in as the scholar, run
`db.from('submissions').select('*')` (only own row returned) and `db.rpc('verify_submission',{p_id:2,p_status:'Verified',p_reason:null})` (error: Staff only).

## Known defects and limits
- Not yet run against a live project: fill in this list honestly after testing.
- New scholars registered by staff have no login until an Auth user is created and `auth_id` is linked.
- Policy editing UI, appeals, exceptions, payments and Registrar integration are out of scope.
