# OAuth 2.0 / OIDC authentication

Most APIs are **OAuth 2.0 resource servers**: they don't issue tokens or run a login flow; they _validate_ a bearer JWT
that some identity provider (Auth0, Okta, Keycloak, Entra ID, Cognito, …) already issued, against that provider's public
keys (JWKS). This reference covers the resource-server pattern as the production default, FastAPI's OAuth2 security
utilities (for documentation, flows, and scopes), a toggleable gate, and testing — all fully typed.

## The resource-server model

```
client ── Authorization: Bearer <JWT> ──> your API
                                            │ 1. extract the bearer token
                                            │ 2. fetch issuer JWKS (cached), pick key by `kid`
                                            │ 3. verify signature + exp/nbf + iss + aud
                                            │ 4. (optional) check scopes/roles in claims
                                            ▼
                                          handler
```

You validate; you never hold the signing secret (asymmetric RS256/ES256 — you only need the public key). The JWKS is
fetched from the issuer's well-known endpoint and cached.

## The authenticator

Keep verification in a plain class so it's unit-testable and the FastAPI dependency stays a thin shim. `PyJWKClient`
(from `pyjwt[crypto]`) fetches and caches the JWKS and selects the right key by the token's `kid`.

```python
# api/auth_core.py
from typing import Any

import jwt
from jwt import PyJWKClient
from jwt.exceptions import PyJWKClientError, PyJWTError

_ALGORITHMS = ["RS256", "RS384", "RS512", "ES256", "ES384"]


class UnauthorizedError(Exception):
    """Maps to 401 in an exception handler."""


class Authenticator:
    def __init__(
        self,
        *,
        required: bool,
        jwks_url: str = "",
        issuer: str = "",
        audience: str = "",
    ) -> None:
        self.required = required
        self._issuer = issuer
        self._audience = audience
        self._jwks: PyJWKClient | None = None
        if required:
            if not jwks_url:
                raise RuntimeError("AUTH_REQUIRED=true but AUTH_JWKS_URL is empty")
            self._jwks = PyJWKClient(jwks_url)  # caches keys internally

    def verify(self, authorization: str | None) -> dict[str, Any]:
        """Return validated claims, or raise UnauthorizedError. Pass-through when auth is off."""
        if not self.required:
            return {}
        token = _bearer(authorization)
        if token is None:
            raise UnauthorizedError("missing bearer token")
        assert self._jwks is not None
        try:
            signing_key = self._jwks.get_signing_key_from_jwt(token).key
            claims: dict[str, Any] = jwt.decode(
                token,
                signing_key,
                algorithms=_ALGORITHMS,
                issuer=self._issuer or None,
                audience=self._audience or None,
                options={"verify_aud": bool(self._audience), "require": ["exp", "iat"]},
            )
            return claims
        except (PyJWTError, PyJWKClientError) as exc:
            raise UnauthorizedError("invalid bearer token") from exc


def _bearer(header: str | None) -> str | None:
    if not header:
        return None
    scheme, _, token = header.partition(" ")
    return token if scheme.lower() == "bearer" and token else None
```

Pin `algorithms` to an allow-list of asymmetric algorithms — never accept `alg` from the token, and never include
`none`. Verify `iss` and `aud` whenever the contract specifies them; rejecting a token minted for a different audience
is a core resource-server duty. Require `exp` so a token without an expiry can't live forever.

## The FastAPI dependency and the gate

Wrap the authenticator in a dependency and apply it at the **router** level so it covers every business endpoint without
threading it through each signature. Make the dependency a plain `def` (not `async def`): the JWKS lookup and JWT verify
are CPU/sync work, so FastAPI runs them in the threadpool and never blocks the event loop.

```python
# api/auth.py
from typing import Any

from fastapi import Header, Request


def require_auth(request: Request, authorization: str | None = Header(default=None)) -> dict[str, Any]:
    authenticator: Authenticator = request.app.state.authenticator
    return authenticator.verify(authorization)   # raises UnauthorizedError -> 401 handler
```

```python
# main.py — apply to business routers, leave the open probes open
gated = [Depends(require_auth)]
app.include_router(tasks.router, dependencies=gated)
app.include_router(commands.router, dependencies=gated)
app.include_router(health.router, dependencies=gated)   # /healthz: richer report, behind the gate
# /readyz, /livez, /openapi.json are registered WITHOUT the gate — always reachable
```

Map the error in the handler bundle (see `errors.md`):

```python
@app.exception_handler(UnauthorizedError)
async def _on_unauthorized(_: Request, exc: UnauthorizedError) -> JSONResponse:
    return error_response(401, "unauthorized", str(exc))
```

### The `AUTH_REQUIRED` toggle

Scaffold auth from day one but gate it on config so local development and the contract harness run open, while
production turns it on. The `Authenticator` is a pass-through when `required=False`, so the dependency stays wired in
both modes — no conditional route registration, no drift between the two paths.

```python
# config.py fields (pydantic-settings)
auth_required: bool = False
auth_jwks_url: str = ""
auth_issuer: str = ""
auth_audience: str = ""
```

Build it once in the factory and stash on `app.state`:

```python
app.state.authenticator = Authenticator(
    required=cfg.auth_required,
    jwks_url=cfg.auth_jwks_url,
    issuer=cfg.auth_issuer,
    audience=cfg.auth_audience,
)
```

## FastAPI's OAuth2 security utilities (docs, flows, scopes)

The dependency above does the real validation. FastAPI's `fastapi.security` classes add two things on top: they
**document** the scheme in the emitted OpenAPI (so `/docs` shows an Authorize button and the spec advertises the flow),
and they extract the token for you. Use the class that matches your flow:

- `OAuth2AuthorizationCodeBearer(authorizationUrl=…, tokenUrl=…, scopes={…})` — the standard for a real OIDC provider;
  documents the auth-code flow and the available scopes.
- `HTTPBearer()` — minimal "just a bearer token" scheme when you only validate, not document a flow.
- `OAuth2PasswordBearer(tokenUrl=…)` — only for first-party password grant (rare; mostly tutorials/legacy).

```python
from fastapi.security import OAuth2AuthorizationCodeBearer

oauth2 = OAuth2AuthorizationCodeBearer(
    authorizationUrl="https://issuer.example.com/authorize",
    tokenUrl="https://issuer.example.com/oauth/token",
    scopes={"tasks:read": "Read tasks", "tasks:write": "Create and modify tasks"},
    auto_error=False,   # let your envelope handler own the 401, not FastAPI's default
)
```

If your contract instead documents a plain `http`/`bearer`/`JWT` scheme (common for pure resource servers), declare it
in the canonical spec and validate with the authenticator above — you don't need the flow class. Match whatever the
**contract** declares so the emitted schema stays identical.

## Scopes and authorization

Authentication (who) is not authorization (allowed to do what). Enforce scopes/roles from the verified claims with
`Security(...)` + `SecurityScopes`, which also annotates each operation's required scopes in OpenAPI:

```python
from fastapi import Security
from fastapi.security import SecurityScopes


def require_scopes(scopes: SecurityScopes, request: Request, token: str = Depends(oauth2)) -> dict[str, Any]:
    claims = request.app.state.authenticator.verify(f"Bearer {token}")
    granted = set(str(claims.get("scope", "")).split())
    missing = set(scopes.scopes) - granted
    if missing:
        raise UnauthorizedError(f"missing scope(s): {', '.join(sorted(missing))}")  # 403 if you distinguish
    return claims


@router.post("/tasks")
async def create_task(
    body: CreateTaskRequest,
    store: Store,
    _claims: Annotated[dict[str, Any], Security(require_scopes, scopes=["tasks:write"])],
) -> dict[str, Any]: ...
```

Use 401 for "no/invalid token" and 403 for "valid token, insufficient scope" if your contract distinguishes them.

## Testing auth

Don't call the real IdP. Test the gate by injecting a key resolver or overriding the authenticator dependency:

- **Toggle test:** build the app with `auth_required=False` → endpoints return 200 without a header; build with
  `auth_required=True` and no/invalid token → 401; with a locally-signed valid token → 200.
- **Local tokens:** generate an RSA keypair in the test, sign a JWT with the right `iss`/`aud`/`exp`, and point the
  authenticator at a fixture JWKS (or `app.dependency_overrides[require_auth] = lambda: {"sub": "test"}` for handler
  tests that don't exercise verification).
- **Open probes stay open:** assert `/readyz`, `/livez`, `/openapi.json` return 200 even with `auth_required=True` and
  no token; assert `/healthz` returns 401 in that same configuration (it is gated, not open).

```python
async def test_protected_endpoint_rejects_missing_token() -> None:
    app = create_app(settings=Settings(auth_required=True, auth_jwks_url="https://issuer/jwks"))
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.get("/tasks")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "unauthorized"
```
