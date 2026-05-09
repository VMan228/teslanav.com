import { NextRequest, NextResponse } from "next/server";
import { getPostHogClient } from "@/lib/posthog-server";
import { redis, CACHE_KEYS, CACHE_TTL, RATE_LIMITS } from "@/lib/redis";
import type { WazeAlert } from "@/types/waze";

const OWN_URL = "https://api.openwebninja.com/waze/alerts-and-jams";
const SIDECAR_URL = process.env.WAZE_SIDECAR_URL; // e.g. http://waze-sidecar:8000

// Generate a cache key with tolerance for similar bounds (~1km precision)
function getCacheKey(left: string, right: string, bottom: string, top: string): string {
  const roundTo = (n: string) => parseFloat(n).toFixed(2);
  return `${CACHE_KEYS.WAZE_ALERTS}${roundTo(left)},${roundTo(right)},${roundTo(bottom)},${roundTo(top)}`;
}

// Check and increment global rate limit
async function checkRateLimit(): Promise<{ allowed: boolean; remaining: number }> {
  const key = CACHE_KEYS.WAZE_RATE_LIMIT;

  try {
    const count = await redis.incr(key);
    if (count === 1) {
      await redis.expire(key, CACHE_TTL.RATE_LIMIT_WINDOW);
    }
    const remaining = Math.max(0, RATE_LIMITS.WAZE_REQUESTS_PER_MINUTE - count);
    return { allowed: count <= RATE_LIMITS.WAZE_REQUESTS_PER_MINUTE, remaining };
  } catch (error) {
    console.error("Redis rate limit check failed:", error);
    return { allowed: true, remaining: RATE_LIMITS.WAZE_REQUESTS_PER_MINUTE };
  }
}

// Transform OpenWeb Ninja alert shape → WazeAlert
function transformAlert(a: Record<string, unknown>): WazeAlert {
  return {
    uuid: a.alert_id as string,
    type: a.type as WazeAlert["type"],
    subtype: a.subtype as string | undefined,
    street: a.street as string | undefined,
    city: a.city as string | undefined,
    country: a.country as string | undefined,
    location: {
      x: a.longitude as number,
      y: a.latitude as number,
    },
    reportDescription: a.description as string | undefined,
    reliability: a.alert_reliability as number,
    nThumbsUp: a.num_thumbs_up as number | undefined,
    pubMillis: new Date(a.publish_datetime_utc as string).getTime(),
    reportBy: a.reported_by as string | undefined,
    provider: a.provider as string | undefined,
  };
}

async function fetchFromOWN(
  left: string, right: string, bottom: string, top: string
): Promise<WazeAlert[]> {
  const apiKey = process.env.WAZE_API_KEY;
  if (!apiKey) throw new Error("Neither WAZE_SIDECAR_URL nor WAZE_API_KEY is configured");

  const response = await fetch(
    `${OWN_URL}?bottom_left=${bottom},${left}&top_right=${top},${right}`,
    { headers: { "x-api-key": apiKey } }
  );

  if (!response.ok) throw new Error(`OpenWeb Ninja API returned ${response.status}`);

  const json = await response.json();
  const rawAlerts: Record<string, unknown>[] = json?.data?.alerts ?? [];
  return rawAlerts.map(transformAlert);
}

export async function GET(request: NextRequest) {
  const searchParams = request.nextUrl.searchParams;

  const left = searchParams.get("left");
  const right = searchParams.get("right");
  const bottom = searchParams.get("bottom");
  const top = searchParams.get("top");

  if (!left || !right || !bottom || !top) {
    return NextResponse.json(
      { error: "Missing required bounds parameters" },
      { status: 400 }
    );
  }

  const cacheKey = getCacheKey(left, right, bottom, top);

  // Try to get from Redis cache first
  try {
    const cached = await redis.get<{ alerts: WazeAlert[] }>(cacheKey);
    if (cached) {
      console.log(`[Waze] Cache HIT - ${cached.alerts?.length ?? 0} alerts`);
      return NextResponse.json(cached, {
        headers: {
          "Cache-Control": "public, s-maxage=60, stale-while-revalidate=120",
          "X-Cache": "HIT",
        },
      });
    }
  } catch (error) {
    console.error("Redis cache read failed:", error);
  }

  // Check global rate limit before making external request
  const { allowed, remaining } = await checkRateLimit();

  if (!allowed) {
    const posthog = getPostHogClient();
    posthog.capture({
      distinctId: "server",
      event: "waze_global_rate_limited",
      properties: { bounds: { left, right, bottom, top } },
    });
    await posthog.shutdown();

    return NextResponse.json(
      { error: "Rate limited", alerts: [] },
      {
        status: 429,
        headers: {
          "Retry-After": "60",
          "Cache-Control": "no-store",
          "X-RateLimit-Remaining": "0",
        },
      }
    );
  }

  try {
    let alerts: WazeAlert[];
    let source: string;

    // Try sidecar first (Docker deployment); fall back to OWN API on any failure
    if (SIDECAR_URL) {
      try {
        const response = await fetch(
          `${SIDECAR_URL}/waze?left=${left}&right=${right}&bottom=${bottom}&top=${top}`,
          { signal: AbortSignal.timeout(30_000) }
        );
        if (!response.ok) throw new Error(`Waze sidecar returned ${response.status}`);
        const json = await response.json();
        alerts = json.alerts ?? [];
        source = "sidecar";
      } catch (sidecarError) {
        console.warn("[Waze] Sidecar unavailable, falling back to OWN API:", sidecarError);
        alerts = await fetchFromOWN(left, right, bottom, top);
        source = "OWN (sidecar fallback)";
      }
    } else {
      alerts = await fetchFromOWN(left, right, bottom, top);
      source = "OWN";
    }
    console.log(`[Waze] Cache MISS - Fetched ${alerts.length} alerts from ${source}`);

    const data = { alerts };

    // Store in Redis cache
    try {
      await redis.set(cacheKey, data, { ex: CACHE_TTL.WAZE_ALERTS });
    } catch (error) {
      console.error("Redis cache write failed:", error);
    }

    return NextResponse.json(data, {
      headers: {
        "Cache-Control": "public, s-maxage=60, stale-while-revalidate=120",
        "X-Cache": "MISS",
        "X-RateLimit-Remaining": remaining.toString(),
      },
    });
  } catch (error) {
    console.error("Waze API error:", error);

    const posthog = getPostHogClient();
    posthog.capture({
      distinctId: "server",
      event: "waze_api_error",
      properties: {
        error_message: error instanceof Error ? error.message : "Unknown error",
        bounds: { left, right, bottom, top },
      },
    });
    await posthog.shutdown();

    // Try to return stale cached data as fallback
    try {
      const stale = await redis.get<{ alerts: WazeAlert[] }>(cacheKey);
      if (stale) {
        return NextResponse.json(stale, {
          headers: { "Cache-Control": "public, s-maxage=30", "X-Cache": "STALE" },
        });
      }
    } catch {
      // ignore
    }

    return NextResponse.json(
      { error: "Failed to fetch Waze data", alerts: [] },
      { status: 500 }
    );
  }
}