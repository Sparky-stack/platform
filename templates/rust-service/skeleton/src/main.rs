//! Golden-path Rust service (koorikla/platform templates/rust-service): JSON API, health and version endpoints,
//! structured logs, graceful shutdown. Replace the handlers with your own; keep /healthz (the platform's probes and
//! smoke tests use it).

use std::{env, net::SocketAddr};

use axum::{Json, Router, extract::State, routing::get};
use serde::Serialize;
use tokio::signal;

#[derive(Clone, Debug)]
struct Config {
    greeting: String,
    hostname: String,
    version: String,
}

impl Config {
    fn from_env() -> Self {
        Self {
            greeting: env::var("GREETING").unwrap_or_else(|_| "hello".into()),
            hostname: env::var("HOSTNAME").unwrap_or_default(),
            version: option_env!("APP_VERSION").unwrap_or("dev").into(),
        }
    }
}

#[derive(Serialize, Debug, PartialEq, serde::Deserialize)]
struct Greeting {
    message: String,
    hostname: String,
    version: String,
}

async fn root(State(cfg): State<Config>) -> Json<Greeting> {
    Json(Greeting {
        message: cfg.greeting,
        hostname: cfg.hostname,
        version: cfg.version,
    })
}

async fn healthz() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "status": "ok" }))
}

async fn version(State(cfg): State<Config>) -> Json<serde_json::Value> {
    Json(serde_json::json!({ "version": cfg.version }))
}

fn router(cfg: Config) -> Router {
    Router::new()
        .route("/", get(root))
        .route("/healthz", get(healthz))
        .route("/version", get(version))
        .with_state(cfg)
}

async fn shutdown_signal() {
    let ctrl_c = async { signal::ctrl_c().await.expect("install Ctrl+C handler") };
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("install SIGTERM handler")
            .recv()
            .await;
    };
    tokio::select! { () = ctrl_c => {}, () = terminate => {} }
    tracing::info!("shutting down");
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();
    let port: u16 = env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8080);
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!(%addr, "listening");
    axum::serve(listener, router(Config::from_env()))
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        http::{Request, StatusCode},
    };
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    fn cfg() -> Config {
        Config {
            greeting: "tere".into(),
            hostname: "pod-1".into(),
            version: "abc1234".into(),
        }
    }

    async fn get_json(uri: &str) -> (StatusCode, serde_json::Value) {
        let res = router(cfg())
            .oneshot(Request::get(uri).body(Body::empty()).unwrap())
            .await
            .unwrap();
        let status = res.status();
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null),
        )
    }

    #[tokio::test]
    async fn root_returns_greeting() {
        let (status, body) = get_json("/").await;
        assert_eq!(status, StatusCode::OK);
        let got: Greeting = serde_json::from_value(body).unwrap();
        assert_eq!(
            got,
            Greeting {
                message: "tere".into(),
                hostname: "pod-1".into(),
                version: "abc1234".into()
            }
        );
    }

    #[tokio::test]
    async fn healthz_is_ok() {
        assert_eq!(
            get_json("/healthz").await,
            (StatusCode::OK, serde_json::json!({ "status": "ok" }))
        );
    }

    #[tokio::test]
    async fn version_is_reported() {
        assert_eq!(
            get_json("/version").await.1,
            serde_json::json!({ "version": "abc1234" })
        );
    }

    #[tokio::test]
    async fn unknown_route_is_404() {
        assert_eq!(get_json("/nope").await.0, StatusCode::NOT_FOUND);
    }
}
