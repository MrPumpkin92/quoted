// delete-account: permanently deletes the calling user (App Store 5.1.1(v)).
//
// The app calls `functions.invoke("delete-account")`, which sends the user's
// access token as `Authorization: Bearer <jwt>`. verify_jwt = true in
// config.toml makes the platform reject requests without a valid JWT first;
// this handler then resolves the token to a user with Auth (getUser), because
// the platform check also lets API keys through. The user is deleted with the
// admin API, and the foreign-key cascades in the core schema remove every row
// they own (profiles, quotes, friendships, blocks, shares). Reports are kept
// for moderation with the user's id set to null (on delete set null), and
// events never carry a user id (docs/system-design.md section 3).
//
// The secret key comes only from the function environment, never the app.
import { createClient, isAuthApiError } from '@supabase/supabase-js'

function json(status: number, body: Record<string, unknown>, headers: HeadersInit = {}): Response {
  return Response.json(body, { status, headers })
}

// Current runtime: SUPABASE_SECRET_KEYS is a JSON dictionary of named secret
// keys. SUPABASE_SECRET_KEY is the single-key fallback, and
// SUPABASE_SERVICE_ROLE_KEY is the legacy service_role JWT.
function readSecretKey(): string | undefined {
  const named = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (named) {
    try {
      const keys = JSON.parse(named) as Record<string, unknown>
      if (typeof keys.default === 'string' && keys.default.length > 0) return keys.default
    } catch {
      console.error('delete-account: SUPABASE_SECRET_KEYS is not valid JSON')
    }
  }
  return Deno.env.get('SUPABASE_SECRET_KEY') || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || undefined
}

function bearerToken(req: Request): string | undefined {
  const match = /^Bearer\s+(\S+)$/i.exec(req.headers.get('Authorization') ?? '')
  const token = match?.[1]
  // Publishable and secret keys are not user tokens.
  if (!token || token.startsWith('sb_')) return undefined
  return token
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== 'POST') {
    return json(405, { error: 'method_not_allowed' }, { Allow: 'POST' })
  }

  const jwt = bearerToken(req)
  if (!jwt) {
    return json(401, { error: 'unauthorized' })
  }

  const url = Deno.env.get('SUPABASE_URL')
  const secretKey = readSecretKey()
  if (!url || !secretKey) {
    console.error('delete-account: SUPABASE_URL or the secret key is missing from the function env')
    return json(500, { error: 'server_misconfigured' })
  }

  const admin = createClient(url, secretKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  })

  const { data: userData, error: userError } = await admin.auth.getUser(jwt)
  if (userError || !userData.user) {
    // Auth answered 4xx: the token is invalid, expired or its user is gone.
    if (!userError || (isAuthApiError(userError) && userError.status < 500)) {
      return json(401, { error: 'unauthorized' })
    }
    // Network or upstream failure talking to Auth.
    console.error('delete-account: getUser failed', userError.name, userError.message)
    return json(500, { error: 'auth_unavailable' })
  }

  const { error: deleteError } = await admin.auth.admin.deleteUser(userData.user.id)
  if (deleteError) {
    console.error('delete-account: deleteUser failed', deleteError.name, deleteError.message)
    return json(500, { error: 'delete_failed' })
  }

  return json(200, { deleted: true })
})
