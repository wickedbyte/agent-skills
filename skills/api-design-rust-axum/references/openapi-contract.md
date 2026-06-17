# Serving & Contract-Testing the OpenAPI Document

If you are handed an OpenAPI contract, the document is the source of truth — your job is to make the running service
provably conform to it, and to serve a copy clients can fetch. There are two strategies; pick one deliberately.

## Strategy A — serve the canonical doc, assert route coverage (recommended when a hand-tuned spec exists)

When a carefully written OpenAPI 3.1 file already exists (frozen contract, shared across implementations, tuned by
hand), **do not regenerate it** from code annotations — generators drift from a hand-tuned spec in dozens of small
ways (examples, descriptions, `nullable` encoding, ordering). Instead, embed and serve the canonical file verbatim,
and write a test that the router implements **every** documented operation.

```rust
// src/openapi.rs — embed the canonical doc at compile time.
pub const OPENAPI_JSON: &str = include_str!("../openapi.json");
```

```rust
// Serve it (always open — see routing-and-rpc.md):
async fn openapi_doc() -> impl IntoResponse {
    ([(header::CONTENT_TYPE, "application/json")], crate::openapi::OPENAPI_JSON)
}
```

Keep the served JSON in sync with the canonical YAML via a build/CI step, and guard drift. Two `make` targets
(shown as the commands they run): a `sync` that converts YAML→JSON, and a `check` that fails if the committed JSON
drifted from canonical:

```bash
# openapi-sync: convert canonical YAML → the embedded JSON
python3 -c 'import yaml,json; json.dump(yaml.safe_load(open("../openapi.yaml")), open("openapi.json","w"), indent=2, sort_keys=False)'

# openapi-check (runs after sync): fail if the committed JSON drifted
git diff --exit-code -- openapi.json || { echo "openapi.json drifted — run openapi-sync && commit"; exit 1; }
```

### The route-coverage contract test

Axum can't enumerate its own routes, so probe each documented `(method, path)`: a registered route reaches a handler
(any status); an unregistered one yields a **bare** 404 (Axum's fallback, empty body) or a 405. Substitute sample
ids into path params; colon-command paths collapse onto the dispatcher route automatically.

```rust
#[sqlx::test]
async fn router_implements_every_documented_operation(pool: PgPool) {
    let app = router(AppState::new(Store::new(pool), Clock::System));
    let mut missing = Vec::new();
    for (method, path) in documented_operations() {            // parsed from OPENAPI_JSON["paths"]
        let uri = path.replace("{taskId}", "task_x").replace("{projectId}", "project_x");
        if !is_registered(&app, &method, &uri).await { missing.push(format!("{method} {path}")); }
    }
    assert!(missing.is_empty(), "router missing documented operations: {missing:?}");
}

async fn is_registered(app: &Router, method: &str, uri: &str) -> bool {
    let req = Request::builder().method(method).uri(uri).body(Body::empty()).unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    match res.status() {
        StatusCode::METHOD_NOT_ALLOWED => false,
        StatusCode::NOT_FOUND => {
            // Our handler 404s carry the error envelope; Axum's fallback 404 is empty.
            !res.into_body().collect().await.unwrap().to_bytes().is_empty()
        }
        _ => true,   // reached a handler
    }
}
```

Also assert the served bytes are exactly the canonical doc and that `openapi == "3.1.0"` etc., so "what we serve" and
"what we test against" can never diverge.

## Strategy B — derive the doc from code with `utoipa`

When **you own the contract** and want it generated from the handlers (no separate hand-maintained file), annotate
DTOs and handlers with `utoipa` and assemble an `ApiDoc`; `utoipa-axum` can register routes and collect their schemas
together. Serve the generated JSON (and optionally Swagger UI via `utoipa-swagger-ui`).

The risk is the inverse of Strategy A: the generated doc silently drifts from what you intend. Mitigate by
**snapshotting** the generated document and diffing it in CI (e.g. with `insta`), so any unintended change to the
public contract shows up as a failing test that must be reviewed and accepted.

```rust
#[test]
fn openapi_matches_snapshot() {
    let doc = ApiDoc::openapi().to_pretty_json().unwrap();
    insta::assert_snapshot!(doc);   // review & `cargo insta accept` intentional contract changes
}
```

**Choosing:** an externally-frozen or multi-implementation contract → Strategy A (serve canonical + coverage test).
A service whose contract you define and evolve in lockstep with the code → Strategy B (derive + snapshot). Either
way, a test must fail when the served contract and the implementation disagree.

## Schema-shape proxy tests

Independently of which strategy you choose, assert response **bodies** match the schema cheaply by deserializing into
a strict mirror struct (`deny_unknown_fields`, every required field non-optional). If it deserializes, every required
field is present and no extras leaked:

```rust
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
#[allow(dead_code)]
struct TaskShape { id: String, title: String, state: String, created_at: String, /* … */ }

fn assert_task_shape(task: &serde_json::Value) {
    serde_json::from_value::<TaskShape>(task.clone()).expect("task matches the canonical schema");
}
```

## Full conformance: Schemathesis

The coverage/shape tests are static. To fuzz the **running** service against the spec — generating requests from the
schemas and checking responses conform — run [Schemathesis](https://schemathesis.readthedocs.io/) against the
container in CI:

```bash
st run ./openapi.yaml --url http://localhost:8080 --checks all
```

This catches contract violations the typed tests miss (edge-case inputs, status/`Content-Type` mismatches, response
schema drift). Treat a clean Schemathesis run against the deployed container as the definition of "contract-correct",
on top of a green unit/integration suite. See `testing.md` for where this sits in the pyramid.
