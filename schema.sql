-- Scholarship Monitoring System: schema, RLS, RPCs, seed. Run in Supabase SQL editor.
create table programs (
  id serial primary key, name text unique not null,
  max_gwa numeric(3,2) not null, min_units int not null,
  max_failed int not null, max_incomplete int not null, max_dropped int not null,
  deadline timestamptz not null);

create table profiles (
  id uuid primary key default gen_random_uuid(),
  auth_id uuid unique,                       -- links to auth.users once an account exists
  student_id text unique, full_name text not null,
  role text not null check (role in ('scholar','staff')));

create table assignments (
  id bigserial primary key,
  profile_id uuid unique not null references profiles(id),
  program_id int not null references programs(id),
  award_status text not null default 'Active');

create table submissions (
  id bigserial primary key,
  profile_id uuid not null references profiles(id),
  academic_year text not null, semester int not null check (semester between 1 and 3),
  gwa numeric(3,2) not null check (gwa between 1 and 5),
  units int not null check (units >= 0), failed int not null check (failed >= 0),
  incomplete int not null check (incomplete >= 0), dropped int not null check (dropped >= 0),
  evidence_ref text not null check (length(trim(evidence_ref)) > 0),
  submitted_at timestamptz not null default now(),
  verification_status text not null default 'Pending verification'
    check (verification_status in ('Pending verification','Verified','Returned')),
  return_reason text,
  compliance_result text not null default 'Not evaluated'
    check (compliance_result in ('Not evaluated','Compliant','With Deficiency')),
  deficiencies text[] not null default '{}',
  renewal_decision text not null default 'Undecided'
    check (renewal_decision in ('Undecided','Approved','Held')),
  unique (profile_id, academic_year, semester));

create table history (
  id bigserial primary key, submission_id bigint not null references submissions(id),
  actor_id uuid references profiles(id), action text not null, detail text, note text,
  created_at timestamptz not null default now());

-- helpers
create function my_profile() returns uuid language sql stable security definer set search_path=public
  as $$ select id from profiles where auth_id = auth.uid() $$;
create function is_staff() returns boolean language sql stable security definer set search_path=public
  as $$ select exists(select 1 from profiles where auth_id = auth.uid() and role = 'staff') $$;

-- row level security: reads only; every write goes through the RPCs below
alter table programs enable row level security;
alter table profiles enable row level security;
alter table assignments enable row level security;
alter table submissions enable row level security;
alter table history enable row level security;
create policy p_prog on programs for select to authenticated using (true);
create policy p_prof on profiles for select to authenticated using (is_staff() or id = my_profile());
create policy p_asg on assignments for select to authenticated using (is_staff() or profile_id = my_profile());
create policy p_sub on submissions for select to authenticated using (is_staff() or profile_id = my_profile());
create policy p_his on history for select to authenticated
  using (is_staff() or exists(select 1 from submissions s where s.id = submission_id and s.profile_id = my_profile()));

-- RPCs (security definer, role checked inside)
create function log_h(sid bigint, act text, det text, nt text) returns void language sql security definer set search_path=public
  as $$ insert into history(submission_id, actor_id, action, detail, note) values (sid, my_profile(), act, det, nt) $$;

create function register_scholar(p_student text, p_name text, p_program int) returns void
language plpgsql security definer set search_path=public as $$
declare pid uuid; begin
  if not is_staff() then raise exception 'Staff only'; end if;
  if coalesce(trim(p_student),'')='' or coalesce(trim(p_name),'')='' then raise exception 'Student ID and name are required'; end if;
  insert into profiles(student_id, full_name, role) values (trim(p_student), trim(p_name), 'scholar') returning id into pid;
  insert into assignments(profile_id, program_id) values (pid, p_program);
end $$;

create function submit_grades(p_year text, p_sem int, p_gwa numeric, p_units int, p_failed int,
  p_inc int, p_drop int, p_evidence text) returns void
language plpgsql security definer set search_path=public as $$
declare pid uuid := my_profile(); ex submissions; sid bigint; begin
  if pid is null or is_staff() then raise exception 'Only scholars can submit'; end if;
  if not exists(select 1 from assignments where profile_id = pid) then raise exception 'You are not assigned to a program'; end if;
  if p_gwa is null or p_gwa < 1 or p_gwa > 5 then raise exception 'GWA must be between 1.00 and 5.00'; end if;
  if p_units < 0 or p_failed < 0 or p_inc < 0 or p_drop < 0 then raise exception 'Units and counts must not be negative'; end if;
  if coalesce(trim(p_evidence),'')='' then raise exception 'Grade-document reference is required'; end if;
  select * into ex from submissions where profile_id = pid and academic_year = p_year and semester = p_sem;
  if found and ex.verification_status <> 'Returned' then
    raise exception 'A submission for % semester % already exists', p_year, p_sem; end if;
  if found then
    update submissions set gwa=p_gwa, units=p_units, failed=p_failed, incomplete=p_inc, dropped=p_drop,
      evidence_ref=p_evidence, submitted_at=now(), verification_status='Pending verification', return_reason=null,
      compliance_result='Not evaluated', deficiencies='{}', renewal_decision='Undecided' where id = ex.id;
    perform log_h(ex.id, 'Resubmitted', 'Corrected after return', null);
  else
    insert into submissions(profile_id, academic_year, semester, gwa, units, failed, incomplete, dropped, evidence_ref)
      values (pid, p_year, p_sem, p_gwa, p_units, p_failed, p_inc, p_drop, p_evidence) returning id into sid;
    perform log_h(sid, 'Submitted', 'Pending verification', null);
  end if;
end $$;

create function verify_submission(p_id bigint, p_status text, p_reason text) returns void
language plpgsql security definer set search_path=public as $$ begin
  if not is_staff() then raise exception 'Staff only'; end if;
  if p_status not in ('Verified','Returned') then raise exception 'Invalid status'; end if;
  if p_status = 'Returned' and coalesce(trim(p_reason),'')='' then raise exception 'A reason is required to return evidence'; end if;
  update submissions set verification_status = p_status, return_reason = case when p_status='Returned' then p_reason end,
    compliance_result='Not evaluated', deficiencies='{}', renewal_decision='Undecided' where id = p_id;
  perform log_h(p_id, 'Verification: '||p_status, null, p_reason);
end $$;

create function evaluate_submission(p_id bigint) returns void
language plpgsql security definer set search_path=public as $$
declare s submissions; g programs; d text[] := '{}'; begin
  if not is_staff() then raise exception 'Staff only'; end if;
  select * into s from submissions where id = p_id;
  if s.verification_status <> 'Verified' or coalesce(trim(s.evidence_ref),'')='' then
    raise exception 'Only verified submissions with evidence can be evaluated'; end if;
  select p.* into g from programs p join assignments a on a.program_id = p.id where a.profile_id = s.profile_id;
  if s.gwa > g.max_gwa then d := d || format('GWA %s is above the maximum %s', s.gwa, g.max_gwa); end if;
  if s.units < g.min_units then d := d || format('Enrolled units %s are below the minimum %s', s.units, g.min_units); end if;
  if s.failed > g.max_failed then d := d || format('Failed subjects %s exceed the allowed %s', s.failed, g.max_failed); end if;
  if s.incomplete > g.max_incomplete then d := d || format('Incomplete grades %s exceed the allowed %s', s.incomplete, g.max_incomplete); end if;
  if s.dropped > g.max_dropped then d := d || format('Dropped subjects %s exceed the allowed %s', s.dropped, g.max_dropped); end if;
  if s.submitted_at > g.deadline then d := d || 'Submitted after the deadline'; end if;
  update submissions set compliance_result = case when cardinality(d)=0 then 'Compliant' else 'With Deficiency' end,
    deficiencies = d, renewal_decision = 'Undecided' where id = p_id;
  perform log_h(p_id, 'Evaluation', case when cardinality(d)=0 then 'Compliant' else 'With Deficiency: '||array_to_string(d,'; ') end, null);
end $$;

create function decide_renewal(p_id bigint, p_decision text, p_note text) returns void
language plpgsql security definer set search_path=public as $$
declare s submissions; begin
  if not is_staff() then raise exception 'Staff only'; end if;
  if p_decision not in ('Approved','Held') then raise exception 'Invalid decision'; end if;
  select * into s from submissions where id = p_id;
  if s.verification_status <> 'Verified' or s.compliance_result = 'Not evaluated' then
    raise exception 'Verify and evaluate the submission first'; end if;
  if p_decision = 'Approved' and s.compliance_result <> 'Compliant' then
    raise exception 'Cannot approve a record with deficiency'; end if;
  update submissions set renewal_decision = p_decision where id = p_id;
  perform log_h(p_id, 'Renewal: '||p_decision, null, p_note);
end $$;

revoke all on function log_h(bigint,text,text,text) from public, anon, authenticated;
grant execute on function register_scholar, submit_grades, verify_submission, evaluate_submission, decide_renewal to authenticated;

-- seed: policies (Asia/Manila = +08)
insert into programs(name,max_gwa,min_units,max_failed,max_incomplete,max_dropped,deadline) values
 ('Excellence Scholar',2.00,18,0,0,0,'2026-11-06 17:00+08'),
 ('Access Scholar',2.50,15,0,0,1,'2026-11-06 17:00+08');

-- seed: six synthetic scholars B01..B06 and one staff profile
insert into profiles(student_id, full_name, role) values
 ('B01','Scholar B01','scholar'),('B02','Scholar B02','scholar'),('B03','Scholar B03','scholar'),
 ('B04','Scholar B04','scholar'),('B05','Scholar B05','scholar'),('B06','Scholar B06','scholar'),
 ('STAFF01','Staff Test','staff');
insert into assignments(profile_id, program_id)
 select p.id, case when p.student_id in ('B01','B02','B05') then 1 else 2 end from profiles p where p.role='scholar';
insert into submissions(profile_id, academic_year, semester, gwa, units, failed, incomplete, dropped, evidence_ref, submitted_at, verification_status)
 select p.id,'2026-2027',1,v.gwa,v.units,v.f,v.i,v.d,'GRADES-'||v.sid||'.pdf',v.ts::timestamptz,v.vs
 from (values
  ('B01',2.00,18,0,0,0,'2026-11-06 17:00:00+08','Verified'),
  ('B02',2.01,18,0,0,0,'2026-11-05 17:00:00+08','Verified'),
  ('B03',2.50,15,0,0,1,'2026-11-05 17:00:00+08','Verified'),
  ('B04',2.50,14,0,1,0,'2026-11-05 17:00:00+08','Verified'),
  ('B05',1.75,18,1,0,0,'2026-11-06 17:01:00+08','Verified'),
  ('B06',2.25,15,0,0,0,'2026-11-05 17:00:00+08','Pending verification')
 ) as v(sid,gwa,units,f,i,d,ts,vs) join profiles p on p.student_id = v.sid;

-- link your two Auth test users (create them in Authentication > Users first):
-- update profiles set auth_id = '<scholar auth uuid>' where student_id = 'B01';
-- update profiles set auth_id = '<staff auth uuid>'   where student_id = 'STAFF01';
