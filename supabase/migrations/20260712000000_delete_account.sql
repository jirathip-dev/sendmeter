-- In-app account deletion (App Store guideline 5.1.1(v)).
-- Security definer so the function owner (postgres) may delete from
-- auth.users; every public table references auth.users on delete cascade,
-- so this removes all of the caller's data in one shot.

create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
