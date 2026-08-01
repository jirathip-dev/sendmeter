-- Issue #229: the automatic-logout investigation is complete. Keep the
-- bounded on-device diagnostic ring, but remove its remote evidence store and
-- minimize retained account-linked diagnostic data.
drop table public.auth_events;
