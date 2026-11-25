import { createClient } from "npm:@supabase/supabase-js@2.119.2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type JsonRecord = Record<string, unknown>;

function jsonResponse(status: number, body: JsonRecord): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function revokedAdminMetadata(metadata: Record<string, unknown>) {
  return { ...metadata, admin: false };
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return jsonResponse(405, { error: "Method not allowed." });
  }

  const authorization = request.headers.get("Authorization");
  const bearer = authorization?.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!bearer) {
    return jsonResponse(401, { error: "Sign in is required." });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey =
    Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ??
    Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    console.error("Admin access function is missing server configuration.");
    return jsonResponse(500, { error: "Admin access is not configured." });
  }

  try {
    const userClient = createClient(supabaseUrl, anonKey, {
      auth: {
        autoRefreshToken: false,
        detectSessionInUrl: false,
        persistSession: false,
      },
      global: { headers: { Authorization: `Bearer ${bearer}` } },
    });
    const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        autoRefreshToken: false,
        detectSessionInUrl: false,
        persistSession: false,
      },
    });

    const { data: authData, error: authError } =
      await userClient.auth.getUser(bearer);
    const caller = authData.user;
    if (authError || !caller) {
      return jsonResponse(401, { error: "The session is invalid or expired." });
    }
    if (caller.app_metadata.super_admin !== true) {
      return jsonResponse(403, { error: "Super-admin access is required." });
    }

    const { data: callerProfile, error: callerProfileError } = await userClient
      .from("profiles")
      .select("role,account_status")
      .eq("id", caller.id)
      .maybeSingle();
    if (callerProfileError) {
      console.error("Super-admin profile lookup failed.");
      return jsonResponse(500, { error: "Admin authorization failed." });
    }
    if (
      callerProfile?.role !== "super_admin" ||
      callerProfile.account_status !== "active"
    ) {
      return jsonResponse(403, { error: "Super-admin access is required." });
    }

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return jsonResponse(400, { error: "A valid JSON body is required." });
    }
    if (
      typeof body !== "object" ||
      body === null ||
      Array.isArray(body) ||
      !("targetUserId" in body) ||
      !("enabled" in body)
    ) {
      return jsonResponse(400, { error: "Invalid request." });
    }
    const targetUserId = (body as JsonRecord).targetUserId;
    const enabled = (body as JsonRecord).enabled;
    if (
      typeof targetUserId !== "string" ||
      !uuidPattern.test(targetUserId) ||
      typeof enabled !== "boolean" ||
      targetUserId === caller.id
    ) {
      return jsonResponse(400, { error: "Invalid account or access choice." });
    }

    const { data: targetProfile, error: profileError } = await serviceClient
      .from("profiles")
      .select("id,role,role_before_admin,account_status")
      .eq("id", targetUserId)
      .maybeSingle();
    if (profileError) {
      console.error("Target profile lookup failed.");
      return jsonResponse(500, { error: "The target account could not be loaded." });
    }
    if (!targetProfile) {
      return jsonResponse(404, { error: "The target account was not found." });
    }
    if (targetProfile.role === "super_admin") {
      return jsonResponse(409, {
        error: "Super-admin accounts cannot be managed here.",
      });
    }
    if (enabled && targetProfile.account_status !== "active") {
      return jsonResponse(409, {
        error: "Administrator access cannot be granted to a disabled account.",
      });
    }
    if (
      !["tenant", "landlord", "provider", "admin"].includes(
        targetProfile.role,
      )
    ) {
      return jsonResponse(409, { error: "The target role is not supported." });
    }

    const { data: targetAuthData, error: targetAuthError } =
      await serviceClient.auth.admin.getUserById(targetUserId);
    if (targetAuthError) {
      console.error("Target Auth lookup failed.");
      return jsonResponse(502, { error: "The target Auth account could not be loaded." });
    }
    if (!targetAuthData.user) {
      return jsonResponse(404, { error: "The target account was not found." });
    }
    const currentMetadata =
      (targetAuthData.user.app_metadata as Record<string, unknown> | null) ??
      {};

    if (enabled) {
      let roleChanged = false;
      if (targetProfile.role !== "admin") {
        const { data: updatedProfile, error: updateError } = await userClient
          .from("profiles")
          .update({
            role: "admin",
            role_before_admin: targetProfile.role,
          })
          .eq("id", targetUserId)
          .eq("role", targetProfile.role)
          .select("id")
          .maybeSingle();
        if (updateError || !updatedProfile) {
          return jsonResponse(409, {
            error: "The target account changed; refresh and try again.",
          });
        }
        roleChanged = true;
      }

      const { error: claimError } =
        await serviceClient.auth.admin.updateUserById(targetUserId, {
          app_metadata: { ...currentMetadata, admin: true },
        });
      if (claimError) {
        if (roleChanged) {
          const { data: rollbackData, error: rollbackError } = await userClient
            .from("profiles")
            .update({
              role: targetProfile.role,
              role_before_admin: targetProfile.role_before_admin,
            })
            .eq("id", targetUserId)
            .eq("role", "admin")
            .select("id")
            .maybeSingle();
          if (rollbackError || !rollbackData) {
            console.error("Admin grant rollback failed.");
            return jsonResponse(500, {
              error:
                "The claim update failed and the profile rollback also failed; manual repair is required.",
            });
          }
        }
        console.error("Admin grant claim update failed.");
        return jsonResponse(502, {
          error: "Administrator access could not be granted.",
        });
      }
    } else {
      const { error: claimError } =
        await serviceClient.auth.admin.updateUserById(targetUserId, {
          app_metadata: revokedAdminMetadata(currentMetadata),
        });
      if (claimError) {
        console.error("Admin revoke claim update failed.");
        return jsonResponse(502, {
          error: "Administrator access could not be revoked.",
        });
      }

      if (targetProfile.role === "admin") {
        const restoredRole = ["tenant", "landlord", "provider"].includes(
          targetProfile.role_before_admin,
        )
          ? targetProfile.role_before_admin
          : "tenant";
        const { data: updatedProfile, error: updateError } = await userClient
          .from("profiles")
          .update({ role: restoredRole, role_before_admin: null })
          .eq("id", targetUserId)
          .eq("role", "admin")
          .select("id")
          .maybeSingle();
        if (updateError || !updatedProfile) {
          console.error("Admin revoke profile update failed.");
          return jsonResponse(500, {
            error:
              "The admin claim was removed, but the profile needs manual repair.",
          });
        }
      }
    }

    return jsonResponse(200, {
      enabled,
      targetUserId,
    });
  } catch (error) {
    console.error(
      "Admin access request failed.",
      error instanceof Error ? error.message : "Unknown server error.",
    );
    return jsonResponse(500, { error: "The admin access request failed." });
  }
});
