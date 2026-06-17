# OAuth 2.0 / OIDC — Resource-Server Auth

The API is an OAuth 2.0 **resource server**: it does not issue tokens, log users in, or run an authorization server. It
**trusts an external OIDC provider** and verifies the bearer JWTs that provider issues. v1 ships the full scaffolding —
a guard, the JWKS verification, the security scheme in the contract — but keeps it inert behind `AUTH_REQUIRED` (default
`false`) so the conformance harness runs unauthenticated. Flipping one env var enforces it; no code change.

## The model in one paragraph

A client obtains an access token from the OIDC provider (Auth0, Keycloak, Okta, Entra, Cognito, …) via some OAuth 2.0
flow — that part is outside this service. The client then calls the API with `Authorization: Bearer <jwt>`. The API
fetches the provider's public signing keys from its **JWKS** endpoint (cached, rotated automatically), verifies the
token's signature, expiry, issuer, and audience, and either lets the request through or returns 401. Token **issuance**
is out of scope; token **validation** is the whole job.

## Use `jose`, not a homegrown verifier

`jose` is the maintained, standards-correct JWT/JWKS library. `createRemoteJWKSet` fetches and caches the provider's
keys and handles key rotation; `jwtVerify` checks signature + claims. Never hand-roll JWT parsing or pin a single public
key — JWKS rotation will break the pinned approach and signature checks are easy to get subtly wrong.

## The guard

A global `CanActivate` guard. The shape of the logic: open meta paths always pass; when auth is off, everything passes;
when auth is on, a valid bearer token is required.

```ts
import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";

const OPEN_PATHS = new Set(["/healthz", "/readyz", "/openapi.json"]);

function bearerToken(header: string | undefined): string | null {
    if (header === undefined) return null;
    const prefix = "bearer ";
    if (
        header.length <= prefix.length ||
        header.slice(0, prefix.length).toLowerCase() !== prefix
    ) {
        return null;
    }
    return header.slice(prefix.length).trim();
}

@Injectable()
export class AuthGuard implements CanActivate {
    private readonly jwks: JWTVerifyGetKey | null;

    constructor(@Inject(APP_CONFIG) private readonly config: AppConfig) {
        this.jwks =
            config.authRequired && config.oidcJwksUri !== null
                ? createRemoteJWKSet(new URL(config.oidcJwksUri))
                : null;
    }

    async canActivate(context: ExecutionContext): Promise<boolean> {
        if (!this.config.authRequired) return true;

        const request = context.switchToHttp().getRequest<FastifyRequest>();
        const path = request.url.split("?")[0] ?? request.url;
        if (OPEN_PATHS.has(path)) return true;

        if (this.jwks === null) {
            throw new UnauthorizedException(
                "auth required but no JWKS configured",
            );
        }
        const token = bearerToken(request.headers.authorization);
        if (token === null)
            throw new UnauthorizedException("missing bearer token");

        try {
            await jwtVerify(token, this.jwks, {
                ...(this.config.oidcIssuer !== null
                    ? { issuer: this.config.oidcIssuer }
                    : {}),
                ...(this.config.oidcAudience !== null
                    ? { audience: this.config.oidcAudience }
                    : {}),
            });
        } catch {
            throw new UnauthorizedException("invalid bearer token");
        }
        return true;
    }
}
```

Register it globally:

```ts
{ provide: APP_GUARD, useClass: AuthGuard }
```

What each part defends:

- **`AUTH_REQUIRED` short-circuit.** Off by default so the harness and local dev need no token. The guard, the JWKS
  client, and the contract's security scheme all exist already — only the env flips.
- **JWKS built once in the constructor.** `createRemoteJWKSet` caches keys and refreshes on rotation; building it
  per-request would defeat the cache. It is `null` when auth is off so boot doesn't require a reachable provider.
- **`issuer` and `audience` checks.** Verifying the signature is not enough — a valid token from a _different_ audience
  or issuer must be rejected, or you accept tokens minted for another service. Pass them whenever configured.
- **Meta paths open.** `/healthz`, `/readyz`, `/openapi.json` must answer without a token (probes, doc tooling). Match
  on the path with the query string stripped.
- **`UnauthorizedException` → 401.** The global filter renders it through the envelope (`codeForStatus(401)`); a bad or
  missing token never leaks why beyond a generic message.

## The contract's security scheme

The OpenAPI document declares the scheme and applies it conditionally, documenting the resource-server behavior even
though enforcement is gated:

```yaml
components:
    securitySchemes:
        oidcBearer:
            type: http
            scheme: bearer
            bearerFormat: JWT
            description: OIDC-issued JWT, validated against the issuer's JWKS. Enforced only when AUTH_REQUIRED=true.
security:
    - oidcBearer: []
    - {} # the empty requirement allows unauthenticated access when the gate is off
```

The `- {}` alternative is what lets the same document describe both modes: with the gate off, no credentials are
required; with it on, `oidcBearer` is.

## Scope / claim checks (when you need authorization, not just authentication)

`jwtVerify` returns the decoded payload; enforce scopes or roles from there. Keep it declarative with a metadata
decorator + the guard reading `Reflector`, rather than scattering claim checks through services:

```ts
const { payload } = await jwtVerify(token, this.jwks, {
    /* issuer, audience */
});
const scopes =
    typeof payload.scope === "string" ? payload.scope.split(" ") : [];
const required =
    this.reflector.get<string[]>(SCOPES_KEY, context.getHandler()) ?? [];
if (!required.every((s) => scopes.includes(s))) {
    throw new ForbiddenException("insufficient scope"); // → 403
}
```

Attach the requirement at the route: `@Scopes("tasks:write")`. Keep **authentication** (who are you — the guard) and
**authorization** (may you do this — scope checks) distinct.

## Testing auth without a real provider

Don't call a live IdP in tests. Generate a local keypair, expose its JWKS from a tiny in-test server (or stub the
`jwks` getter), sign tokens with `jose`'s `SignJWT`, and toggle `AUTH_REQUIRED`:

```ts
const { publicKey, privateKey } = await generateKeyPair("RS256");
const token = await new SignJWT({ scope: "tasks:write" })
    .setProtectedHeader({ alg: "RS256" })
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setExpirationTime("5m")
    .sign(privateKey);
```

Assert the 401/200 toggle: with `AUTH_REQUIRED=true`, no token → 401, valid token → 200, and `/healthz` → 200 with no
token. See `references/testing.md`.

## Don't

- **Don't accept `alg: none` or symmetric keys from the token header.** `jwtVerify` against a JWKS already prevents this;
  don't add a fallback that does.
- **Don't log the token** (redact the `authorization` header in pino — see `references/bootstrap-and-config.md`).
- **Don't build an authorization server.** Issuance, refresh, consent screens, and user management belong to the OIDC
  provider; this service only validates.
