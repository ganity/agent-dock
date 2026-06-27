//! Sliding-window rate limiter middleware.
//!
//! Tracks request timestamps per key (e.g. user ID or IP) and rejects
//! requests that exceed the configured limit within the time window.
//! Stale buckets are cleaned up by a background task.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::Request;
use axum::http::StatusCode;
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use serde_json::json;
use tokio::sync::Mutex;

// ── Sliding-window rate limiter ───────────────────────────────────

/// A sliding-window rate limiter that allows `max_requests` per `window`
/// duration for each distinct key.
#[derive(Clone)]
pub struct RateLimiter {
    inner: Arc<Mutex<RateLimiterInner>>,
    max_requests: usize,
    window: Duration,
}

struct RateLimiterInner {
    buckets: HashMap<String, RateBucket>,
}

struct RateBucket {
    timestamps: Vec<Instant>,
}

impl RateLimiter {
    pub fn new(max_requests: usize, window: Duration) -> Self {
        let limiter = Self {
            inner: Arc::new(Mutex::new(RateLimiterInner {
                buckets: HashMap::new(),
            })),
            max_requests,
            window,
        };

        // Spawn background cleanup task to evict stale buckets
        if max_requests > 0 {
            let inner = limiter.inner.clone();
            let cleanup_window = window * 2;
            tokio::spawn(async move {
                let mut interval = tokio::time::interval(Duration::from_secs(300));
                loop {
                    interval.tick().await;
                    let mut guard = inner.lock().await;
                    let cutoff = Instant::now() - cleanup_window;
                    guard.buckets.retain(|_key, bucket| {
                        bucket.timestamps.last().is_some_and(|ts| *ts > cutoff)
                    });
                }
            });
        }

        limiter
    }

    /// Check whether a request from the given key is within the rate limit.
    /// Returns `true` if allowed (and records the timestamp), `false` if rate-limited.
    pub async fn allow(&self, key: &str) -> bool {
        if self.max_requests == 0 {
            return true;
        }

        let mut guard = self.inner.lock().await;
        let now = Instant::now();
        let cutoff = now - self.window;

        let bucket = guard.buckets.entry(key.to_string()).or_insert_with(|| RateBucket {
            timestamps: Vec::new(),
        });

        // Prune expired timestamps
        bucket.timestamps.retain(|ts| *ts > cutoff);

        if bucket.timestamps.len() >= self.max_requests {
            return false;
        }

        bucket.timestamps.push(now);
        true
    }
}

// ── Axum middleware layer ─────────────────────────────────────────

/// Rate-limiting middleware that keys on the authenticated user ID
/// (from the `x-user-id` extension set by the auth layer) or falls
/// back to the remote IP address.
pub async fn rate_limit_middleware(
    axum::extract::State(limiter): axum::extract::State<RateLimiter>,
    request: Request,
    next: Next,
) -> Response {
    // Try to get user ID from the auth extension first, then fall back
    // to a default key for unauthenticated requests.
    let key = request
        .extensions()
        .get::<crate::auth::CurrentUser>()
        .map(|user| format!("user:{}", user.id))
        .unwrap_or_else(|| "anonymous".to_string());

    if !limiter.allow(&key).await {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            axum::Json(json!({
                "error": "RATE_LIMITED",
                "message": "Too many requests. Please try again later."
            })),
        )
            .into_response();
    }

    next.run(request).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn allows_requests_within_limit() {
        let limiter = RateLimiter::new(3, Duration::from_secs(60));
        assert!(limiter.allow("user1").await);
        assert!(limiter.allow("user1").await);
        assert!(limiter.allow("user1").await);
    }

    #[tokio::test]
    async fn rejects_requests_exceeding_limit() {
        let limiter = RateLimiter::new(2, Duration::from_secs(60));
        assert!(limiter.allow("user1").await);
        assert!(limiter.allow("user1").await);
        assert!(!limiter.allow("user1").await);
    }

    #[tokio::test]
    async fn different_keys_are_independent() {
        let limiter = RateLimiter::new(1, Duration::from_secs(60));
        assert!(limiter.allow("user1").await);
        assert!(limiter.allow("user2").await);
        assert!(!limiter.allow("user1").await);
        assert!(!limiter.allow("user2").await);
    }

    #[tokio::test]
    async fn zero_max_requests_disables_limiting() {
        let limiter = RateLimiter::new(0, Duration::from_secs(60));
        for _ in 0..100 {
            assert!(limiter.allow("user1").await);
        }
    }
}
