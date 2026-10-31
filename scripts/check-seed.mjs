// Signs in as you@pawmates.test and prints what each screen will show.
// Local only; run after `npm run seed:local`.
import { execSync } from "node:child_process";
import { createClient } from "@supabase/supabase-js";

const env = Object.fromEntries(
  execSync("npx supabase status -o env", { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] })
    .split(/\r?\n/).map((l) => l.match(/^([A-Z_]+)="?([^"]*)"?$/)).filter(Boolean).map((m) => [m[1], m[2]]),
);
if (!/^http:\/\/(127\.0\.0\.1|localhost)/.test(env.API_URL ?? "")) throw new Error("Local Supabase only");

const supabase = createClient(env.API_URL, env.PUBLISHABLE_KEY, { auth: { persistSession: false } });
await supabase.auth.signInWithPassword({ email: "you@pawmates.test", password: "Woof1234" });
const { data: me } = await supabase.from("pets").select("id").limit(1).single();

const nearby = await supabase.rpc("nearby_pets", { radius_km: 10, my_pet_id: me.id });
console.log("Discover (10 km):", nearby.data?.map((p) => `${p.name} ${p.compatibility}% ~${p.approx_distance_km} km`).join(" | "));
const inbox = await supabase.rpc("get_my_conversations");
console.log("Chat inbox:", inbox.data?.map((c) => `${c.last_message_body} (${c.unread_count} unread)`).join(" | "));
const conns = await supabase.from("connections").select("status, requester_id");
console.log("Connections:", conns.data?.map((c) => c.status).join(", "));
const reviews = await supabase.rpc("my_pending_reviews");
console.log("Reviews to write:", reviews.data?.map((r) => `${r.pet_name} (${r.title})`).join(", "));
const events = await supabase.from("events").select("title, starts_at, status");
console.log("Playdates:", events.data?.map((e) => `${e.title} ${e.starts_at.slice(0, 16)}`).join(" | "));
const queue = await supabase.from("verifications").select("status").eq("status", "pending");
console.log("Admin queue:", queue.data?.length, "pending");
const admin = await supabase.rpc("am_i_admin");
console.log("Admin:", admin.data);
