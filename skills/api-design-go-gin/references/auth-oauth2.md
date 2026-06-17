# OAuth 2.0 Resource-Server Authentication

The API is an OAuth 2.0 **resource server**: it does not log users in or issue tokens. It receives a bearer access token
(a JWT) issued by an external authorization server / OIDC provider, **verifies** it on every request, and authorizes the
call based on its claims. All the token-issuing flows (authorization code + PKCE, client credentials, etc.) happen
elsewhere; your job is verification + authorization.

## What "verify the token" means

For each protected request:

1. Extract the token from `Authorization: Bearer <jwt>`.
2. Verify the **signature** against the authorization server's public key, selected by the token's `kid` from the
   server's **JWKS** (`/.well-known/jwks.json`, discoverable via the OIDC document).
3. **Allow-list the algorithms** — accept only the asymmetric algs your provider uses (e.g. `RS256`, `ES256`). Never
   accept `none`, and never accept an HMAC alg where you expected RSA (the classic alg-confusion attack).
4. Validate the **standard claims**: `exp` (and require it), `nbf`, `iss` (must equal your provider), and `aud` (must
   include _this_ API — rejecting a token minted for a different service).
5. Authorize: check the required `scope` (or roles/permissions) for the route.

JWKS validation is stateless and fast — after the keys are cached there is no per-request network call — which is why
it's preferred over token introspection for high-throughput APIs. (Introspection, a call to the provider's
`/introspect` endpoint per request, is the alternative when tokens are opaque or must be revocable in real time; trade
latency for immediacy.)

## Middleware: JWKS + algorithm allow-list + claim checks

`keyfunc/v3` fetches the JWKS, caches it, and refreshes it on rotation, exposing a `jwt.Keyfunc` that picks the right key
by `kid`. Gate enforcement behind a config flag so dev and the test harness can run open:

```go
// Package auth provides the OAuth 2.0 resource-server bearer-token gate.
package auth

type Config struct {
    Required bool
    JWKSURL  string
    Issuer   string
    Audience string
}

// NewMiddleware builds the gate. Required=false → pass-through (scaffolding on,
// enforcement off). Required=true → validate every request's bearer JWT against
// the issuer's JWKS. The JWKS is fetched and kept refreshed at construction.
func NewMiddleware(ctx context.Context, cfg Config) (gin.HandlerFunc, error) {
    if !cfg.Required {
        return func(c *gin.Context) { c.Next() }, nil
    }
    if cfg.JWKSURL == "" {
        return nil, errors.New("auth: AUTH_REQUIRED=true but AUTH_JWKS_URL is empty")
    }

    kf, err := keyfunc.NewDefaultCtx(ctx, []string{cfg.JWKSURL}) // background refresh
    if err != nil {
        return nil, fmt.Errorf("auth: init JWKS: %w", err)
    }

    opts := []jwt.ParserOption{
        jwt.WithValidMethods([]string{"RS256", "RS384", "RS512", "ES256", "ES384"}),
        jwt.WithExpirationRequired(),
    }
    if cfg.Issuer != "" {
        opts = append(opts, jwt.WithIssuer(cfg.Issuer))
    }
    if cfg.Audience != "" {
        opts = append(opts, jwt.WithAudience(cfg.Audience))
    }

    return func(c *gin.Context) {
        raw, ok := bearerToken(c.GetHeader("Authorization"))
        if !ok {
            unauthorized(c, "missing bearer token")
            return
        }
        token, err := jwt.Parse(raw, kf.Keyfunc, opts...)
        if err != nil || !token.Valid {
            unauthorized(c, "invalid bearer token")
            return
        }
        // Stash claims for downstream scope checks / auditing.
        if claims, ok := token.Claims.(jwt.MapClaims); ok {
            c.Set("claims", claims)
        }
        c.Next()
    }, nil
}
```

Helpers:

```go
func bearerToken(header string) (string, bool) {
    const prefix = "Bearer "
    if len(header) > len(prefix) && strings.EqualFold(header[:len(prefix)], prefix) {
        return strings.TrimSpace(header[len(prefix):]), true
    }
    return "", false
}

func unauthorized(c *gin.Context, msg string) {
    c.Header("WWW-Authenticate", `Bearer realm="api"`) // RFC 6750
    c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{
        "error": gin.H{"code": "unauthorized", "message": msg},
    })
}
```

Note `c.AbortWithStatusJSON` — `Abort` stops the middleware chain so no handler runs after a `401`.

## Per-route scope authorization → 403

Authentication (who) is one gate; authorization (may they do this) is another. After the token is valid, check the
`scope` claim for routes that need one. Return **403** (not 401) when the token is valid but lacks the scope:

```go
func RequireScope(scope string) gin.HandlerFunc {
    return func(c *gin.Context) {
        claims, _ := c.Get("claims")
        mc, _ := claims.(jwt.MapClaims)
        if !hasScope(mc, scope) {
            c.AbortWithStatusJSON(http.StatusForbidden, gin.H{
                "error": gin.H{"code": "forbidden", "message": "missing scope: " + scope},
            })
            return
        }
        c.Next()
    }
}

// OAuth 2.0 "scope" is a space-delimited string (RFC 6749 §3.3).
func hasScope(claims jwt.MapClaims, want string) bool {
    s, _ := claims["scope"].(string)
    for _, got := range strings.Fields(s) {
        if got == want {
            return true
        }
    }
    return false
}
```

Apply it per route or per group: `api.POST("/tasks", auth.RequireScope("tasks:write"), app.createTask)`.

## Propagating identity to handlers/domain

If business logic needs the caller (audit fields, ownership checks), pull a typed value out of the claims in the
middleware and put it on the request `context` (use an unexported key type to avoid collisions), not Gin's string-keyed
bag, so the `store`/`domain` layers can read it without importing `gin`:

```go
type ctxKey int
const subjectKey ctxKey = iota

func WithSubject(ctx context.Context, sub string) context.Context { return context.WithValue(ctx, subjectKey, sub) }
func Subject(ctx context.Context) (string, bool) { s, ok := ctx.Value(subjectKey).(string); return s, ok }
```

In the middleware: `c.Request = c.Request.WithContext(WithSubject(c.Request.Context(), sub))`.

## Security checklist

- [ ] Algorithms are **allow-listed** to the asymmetric ones you expect; `none` and unexpected HMAC are rejected.
- [ ] `exp` is required and checked; `iss` and `aud` are verified — a token for another audience is rejected.
- [ ] JWKS is fetched over HTTPS, cached, and **rotated** automatically (keyfunc handles refresh); a missing `kid` fails
      closed.
- [ ] `401` for missing/invalid token (with `WWW-Authenticate`); `403` for valid-but-unauthorized.
- [ ] Enforcement is **config-gated** (`AUTH_REQUIRED`) but the scaffolding is always wired, so turning it on is a flag
      flip, and tests can run with the gate off (`App.Auth = nil`).
- [ ] Tokens/claims are never logged; the raw `Authorization` header never appears in logs or error bodies.
- [ ] Meta endpoints (`/healthz`, `/readyz`, `/openapi.json`) stay **open** — outside the authed group.
