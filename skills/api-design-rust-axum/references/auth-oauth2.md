# OAuth 2.0 / OIDC Resource-Server Auth

The common shape for an API is to be an **OAuth 2.0 resource server**: it does not log users in or issue tokens
(that is the authorization server / IdP's job). It receives a bearer **access token** (a JWT) on each request and
**validates** it — signature, expiry, issuer, audience — then authorizes by scope/claims. This reference covers that
validation path with `jsonwebtoken`. (If you also need to _initiate_ an OAuth flow — Authorization Code + PKCE — use
`oauth2`; that is a client concern, separate from protecting this API.)

## What "validate a token" means

For each request with `Authorization: Bearer <jwt>`:

1. Parse the JWT header to read its `kid` (key id).
2. Look up the matching public key from the IdP's **JWKS** (JSON Web Key Set).
3. Verify the **signature** with that key.
4. Verify the **claims**: `exp` (not expired), `nbf`/`iat` sanity, `iss` (the expected issuer), `aud` (this API's
   audience/identifier).
5. Optionally check `scope`/`roles` for the specific operation.

Never trust an unverified token; never accept `alg: none`; constrain the accepted algorithms to what your IdP issues
(usually `RS256`).

## Sourcing JWKS

The keys come from the IdP's JWKS endpoint (`<issuer>/.well-known/jwks.json`). Two strategies:

- **Fetch + cache + refresh** (typical production): fetch the JWKS at startup, cache decoding keys by `kid`, and
  refresh periodically or on an unknown-`kid` miss (keys rotate). Use an HTTP client (`reqwest`) on a background
  task; never fetch per-request.
- **Config-provided** (no outbound HTTP): supply the JWKS as inline JSON or a file via env. This keeps the binary
  free of a TLS/HTTP stack and makes tests trivial (mint a fixture key, feed its JWKS in). The example below uses
  this; swapping in a fetch-and-refresh source only changes where `JwkSet` comes from.

## The gate, cheap to clone, in `AppState`

```rust
// src/auth.rs
use std::collections::HashMap;
use std::sync::Arc;
use axum::http::{header, HeaderMap};
use jsonwebtoken::jwk::JwkSet;
use jsonwebtoken::{decode, decode_header, Algorithm, DecodingKey, Validation};
use serde_json::Value;

#[derive(Clone)]
pub struct Auth(Arc<Mode>);              // Arc → clone is cheap; lives in AppState
enum Mode { Disabled, Enabled(Box<Authenticator>) }

impl Auth {
    pub fn disabled() -> Self { Self(Arc::new(Mode::Disabled)) }
    pub fn enabled(a: Authenticator) -> Self { Self(Arc::new(Mode::Enabled(Box::new(a)))) }

    /// Ok(()) allows the request; Err(reason) → 401.
    pub fn check(&self, headers: &HeaderMap) -> Result<(), &'static str> {
        match &*self.0 {
            Mode::Disabled => Ok(()),
            Mode::Enabled(auth) => {
                let token = bearer(headers).ok_or("missing bearer token")?;
                auth.validate(token).map_err(|_| "invalid bearer token")
            }
        }
    }
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    let value = headers.get(header::AUTHORIZATION)?.to_str().ok()?;
    let (scheme, token) = value.split_once(' ')?;
    scheme.eq_ignore_ascii_case("bearer").then(|| token.trim())
}
```

## The validator: keys by `kid` + a configured `Validation`

```rust
pub struct Authenticator {
    keys: HashMap<String, DecodingKey>,  // by kid
    validation: Validation,
}

impl Authenticator {
    pub fn from_jwks(jwks: &JwkSet, issuer: Option<&str>, audience: Option<&str>)
        -> Result<Self, AuthError>
    {
        let mut keys = HashMap::new();
        for jwk in &jwks.keys {
            if let (Some(kid), Ok(key)) = (jwk.common.key_id.clone(), DecodingKey::from_jwk(jwk)) {
                keys.insert(kid, key);
            }
        }
        if keys.is_empty() { return Err(AuthError::NoKeys); }
        Ok(Self { keys, validation: build_validation(issuer, audience) })
    }

    pub fn validate(&self, token: &str) -> Result<(), AuthError> {
        let header = decode_header(token).map_err(|_| AuthError::Rejected)?;
        let kid = header.kid.ok_or(AuthError::Rejected)?;
        let key = self.keys.get(&kid).ok_or(AuthError::Rejected)?;   // unknown kid → reject
        // decode() verifies signature + exp/iss/aud per `validation`.
        decode::<Value>(token, key, &self.validation).map_err(|_| AuthError::Rejected)?;
        Ok(())
    }
}

fn build_validation(issuer: Option<&str>, audience: Option<&str>) -> Validation {
    // Constrain algorithms to the RSA family OIDC providers issue (RS256 default).
    let mut v = Validation::new(Algorithm::RS256);
    v.algorithms = vec![Algorithm::RS256, Algorithm::RS384, Algorithm::RS512];
    if let Some(iss) = issuer { v.set_issuer(&[iss]); }
    match audience {
        Some(aud) => v.set_audience(&[aud]),
        None => v.validate_aud = false,   // only if your contract truly has no audience
    }
    v
}
```

`jsonwebtoken`'s `Validation` checks `exp` (and `nbf`) automatically; `set_issuer`/`set_audience` add `iss`/`aud`
checks. Pin `validation.algorithms` — leaving it open invites algorithm-confusion attacks.

## Wiring the middleware gate

Apply the gate to the protected router only. The open set is **`/readyz`, `/livez`, `/openapi.json`**; the detailed
`/healthz` report is part of the protected router, so it needs a token when auth is on (see `routing-and-rpc.md` and
`observability-deployment.md`):

```rust
async fn require_auth(
    State(state): State<AppState>, request: Request, next: Next,
) -> Result<Response, AppError> {
    state.auth.check(request.headers()).map_err(AppError::unauthorized)?;
    Ok(next.run(request).await)
}
```

`AppError::Unauthorized` renders 401 **with** a `WWW-Authenticate: Bearer` header (see `errors.md`).

## Config + the toggle

Make auth env-driven and **off by default**, so the conformance harness and local runs need no IdP, while production
turns it on. Fail fast at boot if it's required but misconfigured.

```rust
pub struct AuthConfig {
    pub required: bool,
    pub jwks_json: Option<String>,   // inline JWKS (AUTH_JWKS)
    pub jwks_file: Option<String>,   // or a path (AUTH_JWKS_FILE)
    pub issuer: Option<String>,      // AUTH_ISSUER
    pub audience: Option<String>,    // AUTH_AUDIENCE
}

pub fn build_auth(config: AuthConfig) -> Result<Auth, AuthError> {
    if !config.required { return Ok(Auth::disabled()); }
    let raw = match (config.jwks_json, config.jwks_file) {
        (Some(json), _) => json,
        (None, Some(path)) => std::fs::read_to_string(path)?,
        (None, None) => return Err(AuthError::MissingJwks),
    };
    let jwks: JwkSet = serde_json::from_str(&raw).map_err(AuthError::JwksParse)?;
    Ok(Auth::enabled(Authenticator::from_jwks(
        &jwks, config.issuer.as_deref(), config.audience.as_deref(),
    )?))
}
```

## Scopes / fine-grained authorization

Validating the token answers "who"; authorization answers "may they do this". After `decode`, deserialize the
claims into a typed struct (instead of `Value`) and check the `scope` (space-delimited) or `roles`/`permissions`:

```rust
#[derive(serde::Deserialize)]
struct Claims { sub: String, #[serde(default)] scope: String /* "tasks:read tasks:write" */ }

fn has_scope(claims: &Claims, needed: &str) -> bool {
    claims.scope.split(' ').any(|s| s == needed)
}
```

Enforce per-operation scopes either in the handler (after extracting validated claims) or in a scope-aware layer; map
a scope failure to **403 forbidden** (distinct from 401 — the caller _is_ authenticated, just not permitted).

## Testing auth

Because the validator takes a `JwkSet`/keys directly, tests mint a token with a local key and feed the matching JWKS
— no network, fully deterministic. Cover: valid token → 200; missing token → 401; bad signature / wrong `kid` /
expired / wrong `aud` → 401; insufficient scope → 403; that the open probes (`/readyz`, `/livez`, `/openapi.json`)
are reachable with no token; and that the gated `/healthz` requires one when auth is on. See `testing.md`.
