class_name SupabaseConfigDefaults
extends RefCounted

## Baked-in Supabase connection defaults.
##
## These ship inside every export (unlike a loose .cfg at the project root, which
## Godot's exporter does not reliably pack). SupabaseClient reads its config
## solely from these constants, so desktop and Android/APK builds always have a
## working config from the same single source of truth.
##
## SECURITY: only the PUBLISHABLE (client-safe) key belongs here. It is designed
## to ship in clients; security is enforced by Row Level Security on the server.
## NEVER put the secret / service_role key in this file — it would be extractable
## from the APK and bypass all RLS.

const URL := "https://arplaivmwrgodfohieao.supabase.co"
const ANON_KEY := "sb_publishable_NDlLdq1Sxh--TMyRROCwxw_krrGMrW7"
