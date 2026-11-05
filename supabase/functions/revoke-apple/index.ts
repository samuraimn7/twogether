// Twogether — revoke the caller's Sign in with Apple tokens before account deletion.
// Apple requires apps offering Sign in with Apple to revoke the user's tokens when
// they delete their account: https://developer.apple.com/documentation/sign_in_with_apple/revoke_tokens
//
// Deploy:  supabase functions deploy revoke-apple --project-ref kpzeahhwldycfgaxlvsx
// Secrets: supabase secrets set --project-ref kpzeahhwldycfgaxlvsx \
//            APPLE_TEAM_ID=... APPLE_KEY_ID=... APPLE_CLIENT_ID=<Services ID> \
//            APPLE_PRIVATE_KEY="$(cat AuthKey_XXXX.p8)"
// (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are provided automatically.)
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { importPKCS8, SignJWT } from "npm:jose@5.9.6";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// Apple's client_secret: a short-lived ES256 JWT signed with the Sign in with Apple key.
async function clientSecret(): Promise<string> {
  const key = await importPKCS8(Deno.env.get("APPLE_PRIVATE_KEY")!.replace(/\\n/g, "\n"), "ES256");
  const now = Math.floor(Date.now() / 1000);
  return await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: Deno.env.get("APPLE_KEY_ID")! })
    .setIssuer(Deno.env.get("APPLE_TEAM_ID")!)
    .setSubject(Deno.env.get("APPLE_CLIENT_ID")!)
    .setAudience("https://appleid.apple.com")
    .setIssuedAt(now)
    .setExpirationTime(now + 300)
    .sign(key);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user) return json({ error: "not_signed_in" }, 401);

  const { data: row } = await admin.from("apple_tokens").select("refresh_token").eq("user_id", user.id).maybeSingle();
  if (!row) return json({ revoked: false, reason: "no_token" });

  const res = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: Deno.env.get("APPLE_CLIENT_ID")!,
      client_secret: await clientSecret(),
      token: row.refresh_token,
      token_type_hint: "refresh_token",
    }),
  });
  if (!res.ok) return json({ revoked: false, reason: "apple_" + res.status, detail: await res.text() }, 502);

  await admin.from("apple_tokens").delete().eq("user_id", user.id);
  return json({ revoked: true });
});
